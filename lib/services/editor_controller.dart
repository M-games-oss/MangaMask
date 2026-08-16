import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:image/image.dart' as img;

import '../models/layer_model.dart';
import '../models/tool_type.dart';
import 'flood_fill_service.dart';
import 'edge_detection_service.dart';
import 'edit_history_service.dart';
import 'sam_backend_service.dart';
import 'inpainting_backend_service.dart';

/// Tracks where an AI Remove brush stroke currently is in its lifecycle:
///   none       - no stroke in flight, nothing pending
///   processing - stroke just ended, waiting on the inpaint backend
///   reviewing  - backend responded, showing Apply/Cancel to the user
enum RemovalPreviewPhase { none, processing, reviewing }

/// Tracks the SAM brush select lifecycle:
///   none       - nothing selected, no points collected
///   collecting - user is actively brushing include/exclude points
///   processing - stroke paused/ended, waiting on the debounced backend call
///   reviewing  - backend responded with candidate mask(s); user can pick a
///                candidate, add more strokes to refine, cancel, or apply
enum SamSelectPhase { none, collecting, processing, reviewing }

class EditorController extends ChangeNotifier {
  EditorController();

  final List<ManagedLayer> layers = [];
  int activeLayerIndex = -1;
  ToolType tool = ToolType.smartSelect;

  double brushSize = 28;
  int floodFillTolerance = 24;
  bool useAiBackend = false; // toggled on once user configures a backend URL
  String samBackendUrl = 'http://127.0.0.1:8000';
  String inpaintBackendUrl = 'http://127.0.0.1:8000';

  late final SamBackendService _sam = SamBackendService(baseUrl: samBackendUrl);
  late final InpaintingBackendService _inpaint =
      InpaintingBackendService(baseUrl: inpaintBackendUrl);
  final EditHistoryService history = EditHistoryService();

  Float32List? _edgeMapCache;
  String? _edgeMapForLayerId;

  ManagedLayer? get activeLayer =>
      activeLayerIndex >= 0 && activeLayerIndex < layers.length
          ? layers[activeLayerIndex]
          : null;

  int _idCounter = 0;
  String _newId() => 'layer_${_idCounter++}_${DateTime.now().microsecondsSinceEpoch}';

  void loadBaseImage(img.Image image) {
    layers.clear();
    history.clear();
    _clearSamSelection();
    layers.add(ManagedLayer(id: _newId(), name: 'Base Artwork', pixels: image));
    activeLayerIndex = 0;
    notifyListeners();
  }

  void setTool(ToolType t) {
    // Switching tools mid-selection would otherwise leave a dangling debounce
    // timer / stale points around from whatever the SAM brush was doing.
    if (t != ToolType.aiClickSelect) _clearSamSelection();
    tool = t;
    notifyListeners();
  }

  void selectLayer(int index) {
    activeLayerIndex = index;
    notifyListeners();
  }

  // ---------------- Layer management ----------------

  void duplicateActiveLayer() {
    final active = activeLayer;
    if (active == null) return;
    final copy = active.duplicate(_newId());
    layers.insert(activeLayerIndex + 1, copy);
    activeLayerIndex += 1;
    notifyListeners();
  }

  void deleteActiveLayer() {
    if (layers.length <= 1) return;
    layers.removeAt(activeLayerIndex);
    activeLayerIndex = min(activeLayerIndex, layers.length - 1);
    notifyListeners();
  }

  void reorderLayer(int from, int to) {
    final layer = layers.removeAt(from);
    layers.insert(to, layer);
    activeLayerIndex = layers.indexOf(layer);
    notifyListeners();
  }

  void toggleVisibility(int index) {
    layers[index].visible = !layers[index].visible;
    notifyListeners();
  }

  void setOpacity(int index, double opacity) {
    layers[index].opacity = opacity.clamp(0.0, 1.0);
    notifyListeners();
  }

  void renameLayer(int index, String name) {
    layers[index].name = name;
    notifyListeners();
  }

  // ---------------- Selection -> new layer (the core "cutting" action) ----

  /// Runs on-device flood fill from a tap point and immediately cuts the
  /// selected region into a brand-new layer, punching a transparent hole in
  /// the source layer where it was taken from.
  Future<void> smartSelectAndCut(int x, int y, {required String partName}) async {
    final active = activeLayer;
    if (active == null || active.locked) return;
    // Guard against re-cutting an already-cut (transparent) spot — clicking
    // the same location again would otherwise flood-fill the punched-out
    // hole and produce a phantom empty layer.
    if (active.pixels.getPixel(x, y).a == 0) return;

    final mask = FloodFillService.selectContiguous(
      image: active.pixels,
      startX: x,
      startY: y,
      tolerance: floodFillTolerance,
    );
    _cutMaskToNewLayer(mask, partName);
  }

  /// Cuts an arbitrary manual mask (from polygon/magnetic lasso) into a new
  /// layer, same code path as the AI selections.
  void manualMaskAndCut(Uint8List mask, String partName) {
    _cutMaskToNewLayer(mask, partName);
  }

  void _cutMaskToNewLayer(Uint8List mask, String partName) {
    final active = activeLayer;
    if (active == null) return;
    history.recordBeforeEdit(active.id, active.pixels);

    final w = active.width, h = active.height;
    final newLayerPixels = img.Image(width: w, height: h, numChannels: 4);
    final sourcePixels = img.Image.from(active.pixels);

    for (var yy = 0; yy < h; yy++) {
      for (var xx = 0; xx < w; xx++) {
        if (mask[yy * w + xx] != 0) {
          final p = sourcePixels.getPixel(xx, yy);
          newLayerPixels.setPixelRgba(xx, yy, p.r, p.g, p.b, p.a);
          // Punch transparent hole in the source layer.
          sourcePixels.setPixelRgba(xx, yy, 0, 0, 0, 0);
        }
      }
    }

    active.replacePixels(sourcePixels);
    final newLayer = ManagedLayer(id: _newId(), name: partName, pixels: newLayerPixels);
    layers.insert(activeLayerIndex + 1, newLayer);
    activeLayerIndex += 1;
    notifyListeners();
  }

  // ---------------- SAM brush select (tap-and-drag, debounced, reviewed) --
  //
  // Replaces the old "tap once, take SAM's top-scoring mask, cut it
  // immediately" flow. That flow had two real problems: (1) a single point
  // is often not enough information for SAM to separate two touching,
  // similarly-shaded regions (an arm resting over a torso), and (2) taking
  // the single highest-scoring mask with no review step meant a bad guess
  // (sometimes "the whole background") went straight into a destructive
  // cut. This flow instead: collects include/exclude points as the user
  // brushes, waits for a pause (debounced — no live per-frame backend
  // calls), shows the resulting candidate mask(s) for review, lets the user
  // brush more to refine, and only cuts when they explicitly apply.

  static const Duration samDebounce = Duration(milliseconds: 400);

  /// Whether the next brush stroke adds include or exclude points. Flipped
  /// by a toolbar toggle. Exclude points are how you tell SAM "not this
  /// part" — e.g. brush the overlapping arm as exclude after SAM includes
  /// it with the torso.
  bool samBrushExclude = false;

  SamSelectPhase samSelectPhase = SamSelectPhase.none;
  final List<SamPointPrompt> _samPoints = [];

  /// Live brush-stroke points (image-space) while the user is dragging.
  /// Exposed as a ValueNotifier rather than routed through
  /// notifyListeners() so the canvas can repaint just the stroke-preview
  /// layer on every sampled point without rebuilding the whole widget tree
  /// — including the layered-image FutureBuilder chain — which is what was
  /// making brushing feel laggy.
  final ValueNotifier<List<Offset>> samStrokeNotifier = ValueNotifier<List<Offset>>([]);

  /// Minimum image-space distance between sampled points. Scales with brush
  /// size so a bigger brush (coarser, faster strokes) doesn't oversample.
  double get samBrushSampleSpacing => max(4.0, brushSize / 3);

  List<SamMaskCandidate>? _samCandidates;
  int _samCandidateIndex = 0;
  Timer? _samDebounceTimer;
  Offset? _lastSamSamplePoint;

  // Carries iterative-refinement context from one backend call to the next
  // (within the same selection session, i.e. until _clearSamSelection()):
  //   _samPrevMaskInput   - the low-res logits of whichever candidate the
  //                         user currently has picked, sent back to SAM as
  //                         a hint so the next prediction *builds on* that
  //                         mask instead of guessing blind from points
  //                         alone again. This is the standard SAM
  //                         click-to-refine pattern.
  //   _samPrevFullResMask - the full-res mask of that same candidate, used
  //                         purely client-side to auto-pick whichever new
  //                         candidate is most similar (highest IoU) after a
  //                         refine, instead of blindly defaulting back to
  //                         "highest score", which is what kept flipping
  //                         the preview between e.g. "the shirt" and "the
  //                         whole body" every time a stroke was added.
  Uint8List? _samPrevMaskInput;
  Uint8List? _samPrevFullResMask;

  List<SamMaskCandidate>? get samCandidates => _samCandidates;
  int get samCandidateIndex => _samCandidateIndex;
  Uint8List? get pendingSamMask =>
      _samCandidates == null ? null : _samCandidates![_samCandidateIndex].mask;

  void beginSamBrushStroke() {
    final active = activeLayer;
    if (active == null || active.locked) return;
    _samDebounceTimer?.cancel();
    // Starting a fresh stroke while `reviewing` a previous result means the
    // user is refining it — keep the accumulated points/candidates so the
    // backend still sees the full prompt history. Starting one from `none`
    // means a brand new selection, so the points/candidates get cleared too.
    if (samSelectPhase == SamSelectPhase.none) {
      _samPoints.clear();
      _samCandidates = null;
      _samPrevMaskInput = null;
    }
    // The drawn brush-mark overlay, however, always resets at the start of
    // *every* stroke — including refine passes. It's a visual cue for
    // "what am I painting right now", not a record of the whole session
    // (that's what _samPoints is for). Without this, marks from every past
    // refine round stayed on screen and kept stacking on top of each other.
    samStrokeNotifier.value = [];
    _lastSamSamplePoint = null;
    samSelectPhase = SamSelectPhase.collecting;
  }

  /// Call with an image-space point while the user drags. Points are
  /// spatially throttled (not every pointer-move event) so a slow stroke
  /// doesn't spam hundreds of near-duplicate points into the prompt.
  /// Deliberately does NOT call notifyListeners() — only the lightweight
  /// stroke-preview notifier updates here, so a full canvas rebuild doesn't
  /// happen on every single sampled point during a drag.
  void addSamBrushPoint(Offset imagePoint) {
    if (samSelectPhase != SamSelectPhase.collecting) return;
    if (_lastSamSamplePoint != null &&
        (imagePoint - _lastSamSamplePoint!).distance < samBrushSampleSpacing) {
      return;
    }
    _lastSamSamplePoint = imagePoint;
    _samPoints.add(SamPointPrompt(
      imagePoint.dx.round(),
      imagePoint.dy.round(),
      !samBrushExclude,
    ));
    samStrokeNotifier.value = [...samStrokeNotifier.value, imagePoint];
  }

  /// Call when the user lifts their finger. Schedules the actual backend
  /// call after [samDebounce] of inactivity rather than firing immediately,
  /// so a quick series of corrective strokes only triggers one request.
  void endSamBrushStrokeAndScheduleFetch() {
    _lastSamSamplePoint = null;
    if (_samPoints.isEmpty) {
      samSelectPhase = SamSelectPhase.none;
      notifyListeners();
      return;
    }
    _samDebounceTimer?.cancel();
    _samDebounceTimer = Timer(samDebounce, _runSamPredict);
  }

  Future<void> _runSamPredict() async {
    final active = activeLayer;
    if (active == null || _samPoints.isEmpty) return;

    samSelectPhase = SamSelectPhase.processing;
    notifyListeners();

    final candidates = await _sam.segmentAtPoints(
      image: active.pixels,
      points: List.of(_samPoints),
      previousMaskInput: _samPrevMaskInput,
    );

    if (candidates == null || candidates.isEmpty) {
      // Backend unreachable or returned nothing — drop back to collecting
      // so the user's points/strokes aren't silently lost, and they can
      // retry (e.g. after fixing the backend URL) or cancel.
      samSelectPhase = SamSelectPhase.collecting;
      notifyListeners();
      return;
    }

    _samCandidates = candidates;
    _samCandidateIndex = _bestMatchingCandidateIndex(candidates);
    _samPrevMaskInput = candidates[_samCandidateIndex].maskInput;
    _samPrevFullResMask = candidates[_samCandidateIndex].mask;
    samSelectPhase = SamSelectPhase.reviewing;
    notifyListeners();
  }

  /// Picks whichever new candidate best matches the mask the user had
  /// selected before this refine round (by IoU), falling back to the
  /// highest-scoring candidate on the very first prediction (no prior
  /// selection to compare against yet). Without this, every refine stroke
  /// reset the preview to SAM's raw top-scoring guess, which on flat manga
  /// shading is frequently "the whole figure" rather than the part being
  /// brushed — undoing whatever the user had just corrected for.
  int _bestMatchingCandidateIndex(List<SamMaskCandidate> candidates) {
    final prev = _samPrevFullResMask;
    if (prev == null) return 0;
    var bestIdx = 0;
    var bestIoU = -1.0;
    for (var i = 0; i < candidates.length; i++) {
      final iou = _maskIoU(prev, candidates[i].mask);
      if (iou > bestIoU) {
        bestIoU = iou;
        bestIdx = i;
      }
    }
    return bestIdx;
  }

  double _maskIoU(Uint8List a, Uint8List b) {
    var intersection = 0, union = 0;
    final len = min(a.length, b.length);
    for (var i = 0; i < len; i++) {
      final av = a[i] != 0, bv = b[i] != 0;
      if (av || bv) union++;
      if (av && bv) intersection++;
    }
    return union == 0 ? 0.0 : intersection / union;
  }

  /// Switches which of the returned candidate masks is currently previewed.
  void pickSamCandidate(int index) {
    if (_samCandidates == null || index < 0 || index >= _samCandidates!.length) return;
    _samCandidateIndex = index;
    // If the user manually overrides the auto-picked candidate, refinement
    // should build on *that* choice, not silently drift back to whatever
    // was auto-picked before.
    _samPrevMaskInput = _samCandidates![index].maskInput;
    _samPrevFullResMask = _samCandidates![index].mask;
    notifyListeners();
  }

  /// Goes back to brushing to refine the current selection (add more
  /// include points, or switch to exclude and paint over what shouldn't be
  /// there) without losing the points collected so far.
  void resumeSamBrushRefinement() {
    samSelectPhase = SamSelectPhase.collecting;
    notifyListeners();
  }

  /// Commits the currently-picked candidate mask as a new layer.
  void applySamSelection(String partName) {
    final mask = pendingSamMask;
    if (mask == null) return;
    _cutMaskToNewLayer(mask, partName);
    _clearSamSelection();
    notifyListeners();
  }

  void cancelSamSelection() {
    _clearSamSelection();
    notifyListeners();
  }

  void _clearSamSelection() {
    _samDebounceTimer?.cancel();
    _samDebounceTimer = null;
    _samPoints.clear();
    samStrokeNotifier.value = [];
    _samCandidates = null;
    _samCandidateIndex = 0;
    _samPrevMaskInput = null;
    _samPrevFullResMask = null;
    _lastSamSamplePoint = null;
    samSelectPhase = SamSelectPhase.none;
  }

  // ---------------- Brush tools ----------------

  Uint8List? _strokeMask;

  /// The in-progress brush mask, exposed read-only so the canvas can paint
  /// a live highlight overlay while the user is dragging.
  Uint8List? get liveStrokeMask => _strokeMask;

  // ---- AI Remove brush preview state ----
  RemovalPreviewPhase removalPhase = RemovalPreviewPhase.none;
  Uint8List? _pendingRemoveMask;
  Uint8List? get pendingRemoveMask => _pendingRemoveMask;
  img.Image? _pendingRemoveResult;
  img.Image? get pendingRemovePreviewImage => _pendingRemoveResult;
  img.Image? _preRemovalSnapshot;

  void beginStroke() {
    final active = activeLayer;
    if (active == null) return;
    if (tool == ToolType.aiRemoveBrush) {
      // Don't touch undo history yet — nothing is actually committed to the
      // layer until the user taps Apply, so there's nothing to "undo" yet.
      _preRemovalSnapshot = img.Image.from(active.pixels);
    } else {
      history.recordBeforeEdit(active.id, active.pixels);
    }
    _strokeMask = Uint8List(active.width * active.height);
  }

  /// Stamps a single circular dab at [imagePoint]. Called repeatedly along
  /// an interpolated line by the canvas (not just once per pointer-move
  /// event) so fast strokes don't leave gaps between dabs.
  void brushAt(Offset imagePoint) {
    final active = activeLayer;
    if (active == null || active.locked) return;
    final r = brushSize / 2;
    final cx = imagePoint.dx.round();
    final cy = imagePoint.dy.round();
    final w = active.width, h = active.height;
    final rSq = r * r;

    final pixels = active.pixels;
    for (var dy = -r.ceil(); dy <= r.ceil(); dy++) {
      final yy = cy + dy;
      if (yy < 0 || yy >= h) continue;
      for (var dx = -r.ceil(); dx <= r.ceil(); dx++) {
        final xx = cx + dx;
        if (xx < 0 || xx >= w) continue;
        if (dx * dx + dy * dy > rSq) continue;

        switch (tool) {
          case ToolType.brushErase:
            final p = pixels.getPixel(xx, yy);
            pixels.setPixelRgba(xx, yy, p.r, p.g, p.b, 0);
            break;
          case ToolType.restoreBrush:
            final o = active.original.getPixel(xx, yy);
            pixels.setPixelRgba(xx, yy, o.r, o.g, o.b, o.a);
            break;
          case ToolType.aiRemoveBrush:
            // Only mark the mask here — actual pixels aren't touched until
            // the stroke ends and (later) the user taps Apply. The canvas
            // reads liveStrokeMask to show a highlight while this happens.
            _strokeMask?[yy * w + xx] = 255;
            break;
          default:
            break;
        }
      }
    }
    active.markDirty();
    notifyListeners();
  }

  /// Call when the user lifts their finger after an AI-remove brush stroke.
  /// Sends the brushed mask to the inpainting backend but does NOT modify
  /// the layer yet — the result is stashed as "pending" so the UI can show
  /// a review step. Call applyPendingRemoval() or cancelPendingRemoval() to
  /// resolve it.
  Future<void> previewAiRemoveStroke() async {
    final active = activeLayer;
    final mask = _strokeMask;
    if (active == null || mask == null) {
      _strokeMask = null;
      return;
    }

    _pendingRemoveMask = mask;
    removalPhase = RemovalPreviewPhase.processing;
    notifyListeners();

    final result = await _inpaint.inpaint(image: active.pixels, maskBrushedArea: mask);
    // null result.image means the backend was unreachable — applying will
    // fall back to a soft transparent erase, same as before.
    _pendingRemoveResult = result.image;
    removalPhase = RemovalPreviewPhase.reviewing;
    notifyListeners();
  }

  /// Commits the pending AI-remove result (or fallback erase) to the layer.
  void applyPendingRemoval() {
    final active = activeLayer;
    final mask = _pendingRemoveMask;
    if (active == null || mask == null) {
      _clearPendingRemoval();
      return;
    }

    if (_preRemovalSnapshot != null) {
      history.recordBeforeEdit(active.id, _preRemovalSnapshot!);
    }

    if (_pendingRemoveResult != null) {
      active.replacePixels(_pendingRemoveResult!);
    } else {
      // Fallback: feathered transparent erase over the brushed mask.
      final feathered = FloodFillService.dilate(mask, active.width, active.height, 0);
      final pixels = active.pixels;
      for (var i = 0; i < feathered.length; i++) {
        if (feathered[i] != 0) {
          final x = i % active.width, y = i ~/ active.width;
          final p = pixels.getPixel(x, y);
          pixels.setPixelRgba(x, y, p.r, p.g, p.b, 0);
        }
      }
      active.replacePixels(pixels);
    }

    _clearPendingRemoval();
    notifyListeners();
  }

  /// Discards the pending AI-remove result without touching the layer.
  void cancelPendingRemoval() {
    _clearPendingRemoval();
    notifyListeners();
  }

  void _clearPendingRemoval() {
    _strokeMask = null;
    _pendingRemoveMask = null;
    _pendingRemoveResult = null;
    _preRemovalSnapshot = null;
    removalPhase = RemovalPreviewPhase.none;
  }

  void endStroke() {
    _strokeMask = null;
  }

  // ---------------- Edge map (for magnetic lasso / overlay) ----------------

  Future<Float32List> edgeMapForActiveLayer() async {
    final active = activeLayer;
    if (active == null) return Float32List(0);
    if (_edgeMapForLayerId == active.id && _edgeMapCache != null) {
      return _edgeMapCache!;
    }
    final map = EdgeDetectionService.sobelMagnitude(active.pixels);
    _edgeMapCache = map;
    _edgeMapForLayerId = active.id;
    return map;
  }

  // ---------------- Undo / Redo ----------------

  void undo() {
    final entry = history.popUndo();
    if (entry == null) return;
    final layer = layers.firstWhere((l) => l.id == entry.layerId, orElse: () => layers[activeLayerIndex]);
    history.pushRedo(layer.id, layer.pixels);
    layer.replacePixels(entry.pixelsBefore);
    notifyListeners();
  }

  void redo() {
    final entry = history.popRedo();
    if (entry == null) return;
    final layer = layers.firstWhere((l) => l.id == entry.layerId, orElse: () => layers[activeLayerIndex]);
    history.pushUndo(layer.id, layer.pixels);
    layer.replacePixels(entry.pixelsBefore);
    notifyListeners();
  }

  // ---------------- Export ----------------

  /// Flattens all visible layers (bottom to top) into one PNG.
  img.Image exportFlattened() {
    if (layers.isEmpty) return img.Image(width: 1, height: 1);
    final w = layers.first.width, h = layers.first.height;
    final out = img.Image(width: w, height: h, numChannels: 4);
    for (final layer in layers) {
      if (!layer.visible) continue;
      final ox = layer.offset.dx.round(), oy = layer.offset.dy.round();
      for (var y = 0; y < layer.height; y++) {
        final ty = y + oy;
        if (ty < 0 || ty >= h) continue;
        for (var x = 0; x < layer.width; x++) {
          final tx = x + ox;
          if (tx < 0 || tx >= w) continue;
          final src = layer.pixels.getPixel(x, y);
          final srcR = src.r.toInt(), srcG = src.g.toInt(), srcB = src.b.toInt(), srcA = src.a.toInt();
          final a = ((srcA * layer.opacity).round().clamp(0, 255)).toInt();
          if (a == 0) continue;
          if (a == 255) {
            out.setPixelRgba(tx, ty, srcR, srcG, srcB, 255);
          } else {
            final dst = out.getPixel(tx, ty);
            final dstR = dst.r.toInt(), dstG = dst.g.toInt(), dstB = dst.b.toInt(), dstA = dst.a.toInt();
            final outA = ((a + dstA * (255 - a) ~/ 255).clamp(0, 255)).toInt();
            int blend(int s, int d) =>
                outA == 0 ? 0 : ((s * a + d * dstA * (255 - a) ~/ 255) ~/ outA);
            out.setPixelRgba(
              tx, ty, blend(srcR, dstR), blend(srcG, dstG), blend(srcB, dstB), outA);
          }
        }
      }
    }
    return out;
  }

  /// Exports a single layer as its own transparent PNG (for sharing just
  /// "the eyes" or "the left arm" out of the app).
  img.Image exportLayer(int index) => img.Image.from(layers[index].pixels);

  @override
  void dispose() {
    _samDebounceTimer?.cancel();
    samStrokeNotifier.dispose();
    super.dispose();
  }
}