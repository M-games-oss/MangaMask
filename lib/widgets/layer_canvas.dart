import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/tool_type.dart';
import '../services/editor_controller.dart';
import '../services/edge_detection_service.dart';

class LayerCanvas extends StatefulWidget {
  const LayerCanvas({super.key});

  @override
  State<LayerCanvas> createState() => _LayerCanvasState();
}

class _LayerCanvasState extends State<LayerCanvas> {
  final TransformationController _transform = TransformationController();
  List<Offset> _lassoPoints = [];
  bool _busy = false;

  // Last *image-space* point touched by the active brush stroke (brush
  // erase / restore / AI remove). Used to interpolate a line of dabs
  // between pointer-move events instead of stamping a single dot per
  // event, which is what produced gappy/spotty strokes on fast drags.
  Offset? _lastBrushImagePoint;

  // Number of pointers (fingers) currently down on the canvas. Tracked so a
  // second finger touching mid-stroke can hand control over to
  // InteractiveViewer for pan/zoom instead of continuing to paint with
  // whatever tool is active — see the Listener wrapping InteractiveViewer
  // below. Without this, only the dedicated Pan tool could pan/zoom; now
  // two-finger pan/zoom works no matter which tool is selected, the same
  // way it does in most drawing apps.
  int _activePointers = 0;

  // Screen-space position of the finger currently dragging, used purely to
  // decide whether the SAM review controls (Cancel/Refine/Apply) should
  // duck out of the way — see _SamReviewControls's proximity check.
  Offset? _dragGlobalPosition;
  final GlobalKey _reviewControlsKey = GlobalKey();

  /// Converts a display-space (on-screen) point into the active layer's own
  /// pixel space. Must subtract [layerOffset] because the compositor draws
  /// each layer shifted by its offset (see _CompositePainter's dstRect) —
  /// without correcting for that here, any tool used on a layer that has
  /// been repositioned with Move Layer (which is exactly what freshly-cut
  /// pieces get, since that's the point of Move Layer) would read/write the
  /// wrong pixels: taps and brush strokes would land offset from wherever
  /// the user is actually touching, including the Restore Brush, which is
  /// why "restore doesn't work on cut layers" once they'd been nudged into
  /// place.
  Offset _toImageSpace(
    Offset localPos,
    double displayWidth,
    double displayHeight,
    int imgW,
    int imgH,
    Offset layerOffset,
  ) {
    final sx = imgW / displayWidth;
    final sy = imgH / displayHeight;
    return Offset(localPos.dx * sx - layerOffset.dx, localPos.dy * sy - layerOffset.dy);
  }

  /// Converts a 0/255 mask into a translucent orange RGBA image so it can be
  /// drawn as a highlight overlay while a brush stroke or SAM candidate mask
  /// is being previewed.
  Future<ui.Image> _maskToHighlightImage(Uint8List mask, int w, int h) {
    final rgba = Uint8List(w * h * 4);
    for (var i = 0; i < mask.length; i++) {
      if (mask[i] != 0) {
        rgba[i * 4] = 255;
        rgba[i * 4 + 1] = 160;
        rgba[i * 4 + 2] = 0;
        rgba[i * 4 + 3] = 140; // translucent orange
      }
    }
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(rgba, w, h, ui.PixelFormat.rgba8888, completer.complete);
    return completer.future;
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<EditorController>();
    final active = controller.activeLayer;
    if (active == null) {
      return const Center(child: Text('Load an image to start cutting'));
    }

    return LayoutBuilder(builder: (context, constraints) {
      // Fit the image within whatever box we're given, preserving aspect
      // ratio on BOTH axes (not just width) — fixes the squish that
      // happened when a parent gave tight constraints on both dimensions.
      final maxW = constraints.maxWidth.isFinite ? constraints.maxWidth : active.width.toDouble();
      final maxH = constraints.maxHeight.isFinite ? constraints.maxHeight : active.height.toDouble();
      final imageAspect = active.width / active.height;
      final boxAspect = maxW / maxH;

      double displayW, displayH;
      if (imageAspect > boxAspect) {
        // Image is relatively wider than the available box -> fit to width.
        displayW = maxW;
        displayH = maxW / imageAspect;
      } else {
        // Image is relatively taller -> fit to height.
        displayH = maxH;
        displayW = maxH * imageAspect;
      }

      // Which mask (if any) should be shown as a highlight overlay right now.
      Uint8List? overlayMask;
      if (controller.removalPhase != RemovalPreviewPhase.none) {
        overlayMask = controller.pendingRemoveMask;
      } else if (controller.tool == ToolType.aiRemoveBrush) {
        overlayMask = controller.liveStrokeMask;
      } else if (controller.samSelectPhase != SamSelectPhase.none) {
        overlayMask = controller.pendingSamMask;
      }

      // Only claim the drag gesture for tools that actually use it. Leaving
      // these null for the Pan tool lets InteractiveViewer's own pan/zoom
      // handle the gesture instead of a GestureDetector sitting on top of it
      // swallowing every single-finger drag — that swallow is why Pan never
      // did anything before.
      final bool dragHandled = controller.tool != ToolType.pan;

      return Center(
        // Center gives its child loose constraints, so the SizedBox below
        // keeps its aspect-correct requested size instead of being forced
        // to fill a tight parent box (which is what was causing the squish).
        child: Stack(
          alignment: Alignment.bottomCenter,
          children: [
            Listener(
              // Counts fingers down on the canvas so a second finger can
              // hand off to InteractiveViewer's pan/zoom no matter which
              // tool is active, instead of that only working with the Pan
              // tool selected. onPointerDown/Up/Cancel fire before the
              // gesture arena below resolves who "wins" the touch, so
              // panEnabled is already correct by the time it matters.
              // Also tracks raw finger position (not routed through our own
              // GestureDetector, since Pan-tool drags and two-finger
              // pan/zoom never reach that) purely so the SAM review panel
              // can duck out from under a finger that's holding/dragging
              // near it — see _ProximityFade.
              onPointerDown: (_) => setState(() => _activePointers++),
              onPointerMove: (e) => setState(() => _dragGlobalPosition = e.position),
              onPointerUp: (_) => setState(() {
                _activePointers = max(0, _activePointers - 1);
                _dragGlobalPosition = null;
              }),
              onPointerCancel: (_) => setState(() {
                _activePointers = max(0, _activePointers - 1);
                _dragGlobalPosition = null;
              }),
              child: InteractiveViewer(
                transformationController: _transform,
                maxScale: 8,
                minScale: 0.5,
                panEnabled: controller.tool == ToolType.pan || _activePointers > 1,
                scaleEnabled: true,
                child: GestureDetector(
                  onTapUp: (details) => _handleTap(context, controller, details, displayW, displayH),
                  onPanStart: dragHandled
                      ? (details) => _handlePanStart(controller, details, displayW, displayH)
                      : null,
                  onPanUpdate: dragHandled
                      ? (details) => _handlePanUpdate(controller, details, displayW, displayH)
                      : null,
                  onPanEnd: dragHandled ? (details) => _handlePanEnd(context, controller) : null,
                  child: SizedBox(
                    width: displayW,
                    height: displayH,
                    child: Stack(
                      children: [
                        FutureBuilder<List<ui.Image>>(
                          future: Future.wait(controller.layers.map((l) => l.uiImage())),
                          builder: (context, snapshot) {
                            if (!snapshot.hasData) {
                              return const Center(child: CircularProgressIndicator());
                            }
                            return FutureBuilder<ui.Image?>(
                              future: overlayMask == null
                                  ? Future.value(null)
                                  : _maskToHighlightImage(overlayMask, active.width, active.height),
                              builder: (context, overlaySnapshot) {
                                return CustomPaint(
                                  painter: _CompositePainter(
                                    images: snapshot.data!,
                                    layers: controller.layers,
                                    lassoPoints: _lassoPoints,
                                    highlightOverlay: overlaySnapshot.data,
                                  ),
                                  size: Size(displayW, displayH),
                                );
                              },
                            );
                          },
                        ),
                        // Live SAM-brush stroke preview lives in its own tiny
                        // repaint layer, driven by a ValueNotifier instead of
                        // controller.notifyListeners(). This is what stops
                        // brushing from re-triggering the FutureBuilder chain
                        // above (and the full layer image lookup it does) on
                        // every single sampled point.
                        if (controller.tool == ToolType.aiClickSelect)
                          IgnorePointer(
                            child: ValueListenableBuilder<List<Offset>>(
                              valueListenable: controller.samStrokeNotifier,
                              builder: (context, points, _) {
                                return CustomPaint(
                                  painter: _SamStrokePainter(
                                    points: points,
                                    imageSize: Size(active.width.toDouble(), active.height.toDouble()),
                                    displaySize: Size(displayW, displayH),
                                    strokeWidthImagePx: controller.brushSize,
                                    exclude: controller.samBrushExclude,
                                  ),
                                  size: Size(displayW, displayH),
                                );
                              },
                            ),
                          ),
                        // Brush/eraser/restore/clone size preview: a hollow
                        // circle that tracks the finger while painting, and
                        // pulses at the canvas center for a moment when the
                        // size slider is dragged (see previewBrushSizeBriefly).
                        IgnorePointer(
                          child: ValueListenableBuilder<Offset?>(
                            valueListenable: controller.brushCursorNotifier,
                            builder: (context, point, _) {
                              if (point == null) return const SizedBox.shrink();
                              return CustomPaint(
                                painter: _BrushCursorPainter(
                                  point: point,
                                  imageSize: Size(active.width.toDouble(), active.height.toDouble()),
                                  displaySize: Size(displayW, displayH),
                                  diameterImagePx: controller.brushSize,
                                ),
                                size: Size(displayW, displayH),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (controller.removalPhase == RemovalPreviewPhase.processing ||
                controller.samSelectPhase == SamSelectPhase.processing)
              const Padding(
                padding: EdgeInsets.only(bottom: 24),
                child: Card(
                  child: Padding(
                    padding: EdgeInsets.all(12),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                        SizedBox(width: 12),
                        Text('Processing...'),
                      ],
                    ),
                  ),
                ),
              ),
            if (controller.removalPhase == RemovalPreviewPhase.reviewing)
              Padding(
                padding: const EdgeInsets.only(bottom: 24),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ElevatedButton.icon(
                      onPressed: controller.cancelPendingRemoval,
                      icon: const Icon(Icons.close),
                      label: const Text('Cancel'),
                    ),
                    const SizedBox(width: 12),
                    ElevatedButton.icon(
                      onPressed: controller.applyPendingRemoval,
                      icon: const Icon(Icons.check),
                      label: const Text('Apply'),
                    ),
                  ],
                ),
              ),
            if (controller.samSelectPhase == SamSelectPhase.reviewing)
              _ProximityFade(
                targetKey: _reviewControlsKey,
                dragGlobalPosition: _dragGlobalPosition,
                child: _SamReviewControls(
                  key: _reviewControlsKey,
                  controller: controller,
                  busy: _busy,
                  onApply: () => _applySamSelection(context, controller),
                ),
              ),
          ],
        ),
      );
    });
  }

  Future<void> _handleTap(
    BuildContext context,
    EditorController controller,
    TapUpDetails details,
    double displayW,
    double displayH,
  ) async {
    final active = controller.activeLayer;
    if (active == null) return;
    final pt = _toImageSpace(details.localPosition, displayW, displayH, active.width, active.height, active.offset);
    final x = pt.dx.round().clamp(0, active.width - 1).toInt();
    final y = pt.dy.round().clamp(0, active.height - 1).toInt();

    if (controller.tool == ToolType.smartSelect) {
      final name = await _promptPartName(context);
      if (name == null) return;
      await controller.smartSelectAndCut(x, y, partName: name);
    } else if (controller.tool == ToolType.polygonLasso) {
      setState(() => _lassoPoints = [..._lassoPoints, pt]);
    } else if (controller.tool == ToolType.fillBucket) {
      controller.fillAt(x, y);
    } else if (controller.tool == ToolType.eyedropper) {
      final picked = controller.pickColorAt(x, y);
      if (picked == null && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Nothing to sample there (transparent)')),
        );
      }
    } else if (controller.tool == ToolType.cloneStamp && controller.cloneSettingSource) {
      controller.setCloneSource(pt);
    }
    // aiClickSelect no longer reacts to a plain tap — it's a drag/brush tool
    // now (see _handlePanStart/_handlePanUpdate/_handlePanEnd), because a
    // single point is often not enough for SAM to separate touching parts.
  }

  Future<String?> _promptPartName(BuildContext context) async {
    final ctrl = TextEditingController(text: 'Cut Part');
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Name this layer'),
        content: TextField(controller: ctrl, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim().isEmpty ? 'Cut Part' : ctrl.text.trim()),
            child: const Text('Cut'),
          ),
        ],
      ),
    );
  }

  Future<void> _applySamSelection(BuildContext context, EditorController controller) async {
    final name = await _promptPartName(context);
    if (name == null) return; // user cancelled — keep reviewing, nothing lost
    controller.applySamSelection(name);
  }

  void _handlePanStart(EditorController controller, DragStartDetails details, double displayW, double displayH) {
    final active = controller.activeLayer;
    if (active == null) return;
    if (_activePointers > 1) return; // second finger down — let it pan/zoom instead

    if (controller.tool == ToolType.brushErase ||
        controller.tool == ToolType.restoreBrush ||
        controller.tool == ToolType.aiRemoveBrush) {
      controller.beginStroke();
      final pt = _toImageSpace(details.localPosition, displayW, displayH, active.width, active.height, active.offset);
      controller.brushAt(pt);
      _lastBrushImagePoint = pt;
    } else if (controller.tool == ToolType.aiClickSelect) {
      controller.beginSamBrushStroke();
      final pt = _toImageSpace(details.localPosition, displayW, displayH, active.width, active.height, active.offset);
      controller.addSamBrushPoint(pt);
    } else if (controller.tool == ToolType.magneticLasso) {
      _lassoPoints = [details.localPosition];
      _snappedImagePoints.clear();
    } else if (controller.tool == ToolType.cloneStamp && !controller.cloneSettingSource) {
      final pt = _toImageSpace(details.localPosition, displayW, displayH, active.width, active.height, active.offset);
      controller.beginCloneStroke(pt);
      controller.cloneStampAt(pt);
    }
  }

  Future<void> _handlePanUpdate(
      EditorController controller, DragUpdateDetails details, double displayW, double displayH) async {
    final active = controller.activeLayer;
    if (active == null) return;
    if (_activePointers > 1) return; // second finger down — bail out of drawing

    if (controller.tool == ToolType.brushErase ||
        controller.tool == ToolType.restoreBrush ||
        controller.tool == ToolType.aiRemoveBrush) {
      final pt = _toImageSpace(details.localPosition, displayW, displayH, active.width, active.height, active.offset);
      _strokeBrushTo(controller, pt);
    } else if (controller.tool == ToolType.aiClickSelect) {
      final pt = _toImageSpace(details.localPosition, displayW, displayH, active.width, active.height, active.offset);
      controller.addSamBrushPoint(pt);
    } else if (controller.tool == ToolType.magneticLasso) {
      final edgeMap = await controller.edgeMapForActiveLayer();
      final pt = _toImageSpace(details.localPosition, displayW, displayH, active.width, active.height, active.offset);
      final snapped = EdgeDetectionService.snapToEdge(
        edgeMap, active.width, active.height, Point(pt.dx.round(), pt.dy.round()));
      setState(() => _lassoPoints = [..._lassoPoints, details.localPosition]);
      // store the snapped image-space point for the final cut in _handlePanEnd
      _snappedImagePoints.add(Offset(snapped.x.toDouble(), snapped.y.toDouble()));
    } else if (controller.tool == ToolType.cloneStamp && !controller.cloneSettingSource) {
      final pt = _toImageSpace(details.localPosition, displayW, displayH, active.width, active.height, active.offset);
      controller.cloneStampAt(pt);
    }
  }

  /// Stamps a line of dabs from the last brushed point to [pt] instead of a
  /// single dab at [pt]. Without this, a fast drag produces far fewer
  /// pointer-move events than pixels crossed, leaving visible gaps between
  /// stamps — this is what made every brush tool look spotty.
  void _strokeBrushTo(EditorController controller, Offset pt) {
    final last = _lastBrushImagePoint;
    if (last == null) {
      controller.brushAt(pt);
    } else {
      final dist = (pt - last).distance;
      // Step roughly every pixel of travel; cap so a huge jump (e.g. after
      // the pointer briefly left the widget) can't spin up thousands of
      // stamps in one frame.
      final steps = dist.ceil().clamp(1, 250);
      for (var i = 1; i <= steps; i++) {
        controller.brushAt(Offset.lerp(last, pt, i / steps)!);
      }
    }
    _lastBrushImagePoint = pt;
  }

  final List<Offset> _snappedImagePoints = [];

  Future<void> _handlePanEnd(BuildContext context, EditorController controller) async {
    final active = controller.activeLayer;
    if (active == null) return;

    if (controller.tool == ToolType.aiRemoveBrush) {
      // Don't apply anything yet — just kick off the preview flow. The
      // Processing/Apply/Cancel UI is driven by controller.removalPhase.
      _lastBrushImagePoint = null;
      await controller.previewAiRemoveStroke();
    } else if (controller.tool == ToolType.brushErase || controller.tool == ToolType.restoreBrush) {
      _lastBrushImagePoint = null;
      controller.endStroke();
    } else if (controller.tool == ToolType.aiClickSelect) {
      controller.endSamBrushStrokeAndScheduleFetch();
    } else if (controller.tool == ToolType.cloneStamp) {
      controller.endCloneStroke();
    } else if (controller.tool == ToolType.magneticLasso && _snappedImagePoints.length > 2) {
      final mask = _polygonToMask(_snappedImagePoints, active.width, active.height);
      controller.manualMaskAndCut(mask, 'Lasso Cut');
      setState(() {
        _lassoPoints = [];
        _snappedImagePoints.clear();
      });
    }
  }

  Uint8List _polygonToMask(List<Offset> points, int w, int h) {
    final mask = Uint8List(w * h);
    // Simple scanline point-in-polygon fill.
    var minY = h, maxY = 0;
    for (final p in points) {
      minY = min(minY, p.dy.round());
      maxY = max(maxY, p.dy.round());
    }
    minY = minY.clamp(0, h - 1).toInt();
    maxY = maxY.clamp(0, h - 1).toInt();

    for (var y = minY; y <= maxY; y++) {
      final xs = <double>[];
      for (var i = 0; i < points.length; i++) {
        final a = points[i];
        final b = points[(i + 1) % points.length];
        if ((a.dy <= y && b.dy > y) || (b.dy <= y && a.dy > y)) {
          final t = (y - a.dy) / (b.dy - a.dy);
          xs.add(a.dx + t * (b.dx - a.dx));
        }
      }
      xs.sort();
      for (var i = 0; i + 1 < xs.length; i += 2) {
        final x0 = xs[i].round().clamp(0, w - 1).toInt();
        final x1 = xs[i + 1].round().clamp(0, w - 1).toInt();
        for (var x = x0; x <= x1; x++) {
          mask[y * w + x] = 255;
        }
      }
    }
    return mask;
  }

  void finishPolygonLasso(BuildContext context) async {
    final controller = context.read<EditorController>();
    final active = controller.activeLayer;
    if (active == null || _lassoPoints.length < 3) return;
    final name = await _promptPartName(context);
    if (name == null) return;
    final mask = _polygonToMask(_lassoPoints, active.width, active.height);
    controller.manualMaskAndCut(mask, name);
    setState(() => _lassoPoints = []);
  }

  void clearLasso() => setState(() => _lassoPoints = []);
}

/// Floating controls shown once a SAM brush selection has a candidate mask
/// to review: pick between alternatives (if more than one came back), keep
/// refining with more strokes, cancel, or apply (which prompts for a name).
/// Fades and disables-hit-testing on [child] while a finger is
/// holding/dragging within [proximityRadius] of its on-screen bounds, then
/// restores it once the finger lifts. Deliberately keyed off
/// [dragGlobalPosition] (only non-null while a pointer is actually down and
/// moving) rather than any tap — a quick tap on one of the buttons should
/// never make them vanish out from under the tap.
class _ProximityFade extends StatelessWidget {
  const _ProximityFade({
    required this.targetKey,
    required this.dragGlobalPosition,
    required this.child,
  });

  final GlobalKey targetKey;
  final Offset? dragGlobalPosition;
  final Widget child;
  static const double proximityRadius = 90;

  bool get _shouldHide {
    final pos = dragGlobalPosition;
    if (pos == null) return false;
    final box = targetKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return false;
    final topLeft = box.localToGlobal(Offset.zero);
    final rect = topLeft & box.size;
    final expanded = rect.inflate(proximityRadius);
    return expanded.contains(pos);
  }

  @override
  Widget build(BuildContext context) {
    final hide = _shouldHide;
    return IgnorePointer(
      ignoring: hide,
      child: AnimatedOpacity(
        opacity: hide ? 0.0 : 1.0,
        duration: const Duration(milliseconds: 150),
        child: child,
      ),
    );
  }
}

/// Hollow circle showing the current brush/eraser/restore/clone diameter,
/// either following the finger mid-stroke or pulsing at the canvas center
/// when the size slider is adjusted (see EditorController.brushCursorNotifier
/// and previewBrushSizeBriefly).
class _BrushCursorPainter extends CustomPainter {
  _BrushCursorPainter({
    required this.point,
    required this.imageSize,
    required this.displaySize,
    required this.diameterImagePx,
  });
  final Offset point; // image-space
  final Size imageSize;
  final Size displaySize;
  final double diameterImagePx;

  @override
  void paint(Canvas canvas, Size size) {
    if (imageSize.width <= 0 || imageSize.height <= 0) return;
    final sx = displaySize.width / imageSize.width;
    final sy = displaySize.height / imageSize.height;
    final center = Offset(point.dx * sx, point.dy * sy);
    final radius = diameterImagePx * sx / 2;

    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = Colors.black54
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(covariant _BrushCursorPainter oldDelegate) =>
      oldDelegate.point != point || oldDelegate.diameterImagePx != diameterImagePx;
}

class _SamReviewControls extends StatelessWidget {
  const _SamReviewControls({super.key, required this.controller, required this.busy, required this.onApply});
  final EditorController controller;
  final bool busy;
  final VoidCallback onApply;

  @override
  Widget build(BuildContext context) {
    final candidates = controller.samCandidates ?? const [];
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (candidates.length > 1)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < candidates.length; i++)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: ChoiceChip(
                        label: Text('Option ${i + 1} · ${(candidates[i].score * 100).round()}%'),
                        selected: controller.samCandidateIndex == i,
                        onSelected: (_) => controller.pickSamCandidate(i),
                      ),
                    ),
                ],
              ),
            ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ElevatedButton.icon(
                onPressed: controller.cancelSamSelection,
                icon: const Icon(Icons.close),
                label: const Text('Cancel'),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                onPressed: controller.resumeSamBrushRefinement,
                icon: const Icon(Icons.brush),
                label: const Text('Refine'),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                onPressed: onApply,
                icon: const Icon(Icons.check),
                label: const Text('Apply'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Draws the live SAM-brush stroke as a continuous line (rounded caps/joins,
/// scaled to the brush size) rather than a series of separate dots — a row
/// of unconnected circles is what made the tool look like it was "dropping
/// circles" instead of behaving like a brush.
class _SamStrokePainter extends CustomPainter {
  _SamStrokePainter({
    required this.points,
    required this.imageSize,
    required this.displaySize,
    required this.strokeWidthImagePx,
    required this.exclude,
  });
  final List<Offset> points; // image-space
  final Size imageSize;
  final Size displaySize;
  final double strokeWidthImagePx;
  final bool exclude;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty || imageSize.width <= 0 || imageSize.height <= 0) return;
    final sx = displaySize.width / imageSize.width;
    final sy = displaySize.height / imageSize.height;
    final color = (exclude ? Colors.redAccent : Colors.cyanAccent).withOpacity(0.45);

    if (points.length == 1) {
      canvas.drawCircle(
        Offset(points.first.dx * sx, points.first.dy * sy),
        strokeWidthImagePx * sx / 2,
        Paint()..color = color,
      );
      return;
    }

    final path = Path()..moveTo(points.first.dx * sx, points.first.dy * sy);
    for (final p in points.skip(1)) {
      path.lineTo(p.dx * sx, p.dy * sy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidthImagePx * sx
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(covariant _SamStrokePainter oldDelegate) =>
      oldDelegate.points != points ||
      oldDelegate.exclude != exclude ||
      oldDelegate.strokeWidthImagePx != strokeWidthImagePx;
}

class _CompositePainter extends CustomPainter {
  _CompositePainter({
    required this.images,
    required this.layers,
    required this.lassoPoints,
    this.highlightOverlay,
  });
  final List<ui.Image> images;
  final List layers;
  final List<Offset> lassoPoints;
  final ui.Image? highlightOverlay;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFFECECEC));
    // Checkerboard hint for transparency
    _drawCheckerboard(canvas, size);

    for (var i = 0; i < images.length; i++) {
      final layer = layers[i];
      if (!layer.visible) continue;
      final paint = Paint()..color = Color.fromRGBO(255, 255, 255, layer.opacity);
      final srcRect = Rect.fromLTWH(0, 0, images[i].width.toDouble(), images[i].height.toDouble());
      final dstRect = Rect.fromLTWH(
        layer.offset.dx * size.width / images[i].width,
        layer.offset.dy * size.height / images[i].height,
        size.width,
        size.height,
      );
      canvas.drawImageRect(images[i], srcRect, dstRect, paint);
    }

    if (highlightOverlay != null) {
      final srcRect = Rect.fromLTWH(
          0, 0, highlightOverlay!.width.toDouble(), highlightOverlay!.height.toDouble());
      canvas.drawImageRect(highlightOverlay!, srcRect, Offset.zero & size, Paint());
    }

    if (lassoPoints.length > 1) {
      final path = Path()..addPolygon(lassoPoints, false);
      canvas.drawPath(
        path,
        Paint()
          ..color = Colors.cyanAccent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
  }

  void _drawCheckerboard(Canvas canvas, Size size) {
    const cell = 12.0;
    final paint = Paint()..color = const Color(0xFFD8D8D8);
    for (double y = 0; y < size.height; y += cell) {
      for (double x = 0; x < size.width; x += cell) {
        final on = ((x / cell).floor() + (y / cell).floor()) % 2 == 0;
        if (on) canvas.drawRect(Rect.fromLTWH(x, y, cell, cell), paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _CompositePainter oldDelegate) => true;
}