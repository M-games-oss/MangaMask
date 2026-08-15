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
    layers.add(ManagedLayer(id: _newId(), name: 'Base Artwork', pixels: image));
    activeLayerIndex = 0;
    notifyListeners();
  }

  void setTool(ToolType t) {
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
    final mask = FloodFillService.selectContiguous(
      image: active.pixels,
      startX: x,
      startY: y,
      tolerance: floodFillTolerance,
    );
    _cutMaskToNewLayer(mask, partName);
  }

  /// Same idea but the mask comes from the SAM backend, which understands
  /// object/part boundaries rather than only flat color regions - so it
  /// handles things like "the whole arm" even when it's drawn with shading
  /// bands of several different colors.
  Future<bool> aiSelectAndCut(int x, int y, {required String partName}) async {
    final active = activeLayer;
    if (active == null || active.locked) return false;
    final mask = await _sam.segmentAtPoint(image: active.pixels, x: x, y: y);
    if (mask == null) return false;
    _cutMaskToNewLayer(mask, partName);
    return true;
  }

  Future<bool> aiSelectBoxAndCut(
    int x0, int y0, int x1, int y1, {required String partName}) async {
    final active = activeLayer;
    if (active == null || active.locked) return false;
    final mask = await _sam.segmentInBox(
      image: active.pixels, x0: x0, y0: y0, x1: x1, y1: y1);
    if (mask == null) return false;
    _cutMaskToNewLayer(mask, partName);
    return true;
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

  // ---------------- Brush tools ----------------

  void beginStroke() {
    final active = activeLayer;
    if (active == null) return;
    history.recordBeforeEdit(active.id, active.pixels);
    _strokeMask = Uint8List(active.width * active.height);
  }

  Uint8List? _strokeMask;

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
  /// Sends the brushed mask to the inpainting backend and replaces those
  /// pixels with the AI-filled result. Falls back to a soft transparent
  /// erase (feathered) if no backend is reachable.
  Future<void> endAiRemoveStroke() async {
    final active = activeLayer;
    final mask = _strokeMask;
    if (active == null || mask == null) return;

    final result = await _inpaint.inpaint(image: active.pixels, maskBrushedArea: mask);
    if (result.image != null) {
      active.replacePixels(result.image!);
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
    _strokeMask = null;
    notifyListeners();
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
          final a = (src.a * layer.opacity).round().clamp(0, 255);
          if (a == 0) continue;
          if (a == 255) {
            out.setPixelRgba(tx, ty, src.r, src.g, src.b, 255);
          } else {
            final dst = out.getPixel(tx, ty);
            final outA = a + dst.a * (255 - a) ~/ 255;
            final blend = (int s, int d) =>
                outA == 0 ? 0 : ((s * a + d * dst.a * (255 - a) ~/ 255) ~/ outA);
            out.setPixelRgba(
              tx, ty, blend(src.r, dst.r), blend(src.g, dst.g), blend(src.b, dst.b), outA);
          }
        }
      }
    }
    return out;
  }

  /// Exports a single layer as its own transparent PNG (for sharing just
  /// "the eyes" or "the left arm" out of the app).
  img.Image exportLayer(int index) => img.Image.from(layers[index].pixels);
}
