import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/tool_type.dart';
import '../services/editor_controller.dart';
import '../services/flood_fill_service.dart';
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
  double _lastScale = 1.0;

  Offset _toImageSpace(Offset localPos, double displayWidth, double displayHeight, int imgW, int imgH) {
    final sx = imgW / displayWidth;
    final sy = imgH / displayHeight;
    return Offset(localPos.dx * sx, localPos.dy * sy);
  }

  /// Converts a 0/255 mask into a translucent orange RGBA image so it can be
  /// drawn as a highlight overlay while the AI Remove brush is active or
  /// waiting on the backend.
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
      final Uint8List? overlayMask = controller.removalPhase != RemovalPreviewPhase.none
          ? controller.pendingRemoveMask
          : (controller.tool == ToolType.aiRemoveBrush ? controller.liveStrokeMask : null);

      return Center(
        // Center gives its child loose constraints, so the SizedBox below
        // keeps its aspect-correct requested size instead of being forced
        // to fill a tight parent box (which is what was causing the squish).
        child: Stack(
          alignment: Alignment.bottomCenter,
          children: [
            InteractiveViewer(
              transformationController: _transform,
              maxScale: 8,
              minScale: 0.5,
              panEnabled: controller.tool == ToolType.pan,
              scaleEnabled: true,
              child: GestureDetector(
                onTapUp: (details) => _handleTap(context, controller, details, displayW, displayH),
                onPanStart: (details) => _handlePanStart(controller, details, displayW, displayH),
                onPanUpdate: (details) => _handlePanUpdate(controller, details, displayW, displayH),
                onPanEnd: (details) => _handlePanEnd(controller),
                child: SizedBox(
                  width: displayW,
                  height: displayH,
                  child: FutureBuilder<List<ui.Image>>(
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
                ),
              ),
            ),
            if (controller.removalPhase == RemovalPreviewPhase.processing)
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
    final pt = _toImageSpace(details.localPosition, displayW, displayH, active.width, active.height);
    final x = pt.dx.round().clamp(0, active.width - 1).toInt();
    final y = pt.dy.round().clamp(0, active.height - 1).toInt();

    if (controller.tool == ToolType.smartSelect) {
      final name = await _promptPartName(context);
      if (name == null) return;
      await controller.smartSelectAndCut(x, y, partName: name);
    } else if (controller.tool == ToolType.aiClickSelect) {
      final name = await _promptPartName(context);
      if (name == null) return;
      setState(() => _busy = true);
      final ok = await controller.aiSelectAndCut(x, y, partName: name);
      setState(() => _busy = false);
      if (!ok && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('AI backend unreachable — falling back to Smart Select.'),
        ));
        await controller.smartSelectAndCut(x, y, partName: name);
      }
    } else if (controller.tool == ToolType.polygonLasso) {
      setState(() => _lassoPoints = [..._lassoPoints, pt]);
    }
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

  void _handlePanStart(EditorController controller, DragStartDetails details, double displayW, double displayH) {
    final active = controller.activeLayer;
    if (active == null) return;

    if (controller.tool == ToolType.brushErase ||
        controller.tool == ToolType.restoreBrush ||
        controller.tool == ToolType.aiRemoveBrush) {
      controller.beginStroke();
      final pt = _toImageSpace(details.localPosition, displayW, displayH, active.width, active.height);
      controller.brushAt(pt);
    } else if (controller.tool == ToolType.magneticLasso) {
      _lassoPoints = [details.localPosition];
      _snappedImagePoints.clear();
    }
  }

  Future<void> _handlePanUpdate(
      EditorController controller, DragUpdateDetails details, double displayW, double displayH) async {
    final active = controller.activeLayer;
    if (active == null) return;

    if (controller.tool == ToolType.brushErase ||
        controller.tool == ToolType.restoreBrush ||
        controller.tool == ToolType.aiRemoveBrush) {
      final pt = _toImageSpace(details.localPosition, displayW, displayH, active.width, active.height);
      controller.brushAt(pt);
    } else if (controller.tool == ToolType.magneticLasso) {
      final edgeMap = await controller.edgeMapForActiveLayer();
      final pt = _toImageSpace(details.localPosition, displayW, displayH, active.width, active.height);
      final snapped = EdgeDetectionService.snapToEdge(
        edgeMap, active.width, active.height, Point(pt.dx.round(), pt.dy.round()));
      setState(() => _lassoPoints = [..._lassoPoints, details.localPosition]);
      // store the snapped image-space point for the final cut in _handlePanEnd
      _snappedImagePoints.add(Offset(snapped.x.toDouble(), snapped.y.toDouble()));
    }
  }

  final List<Offset> _snappedImagePoints = [];

  Future<void> _handlePanEnd(EditorController controller) async {
    final active = controller.activeLayer;
    if (active == null) return;

    if (controller.tool == ToolType.aiRemoveBrush) {
      // Don't apply anything yet — just kick off the preview flow. The
      // Processing/Apply/Cancel UI is driven by controller.removalPhase.
      await controller.previewAiRemoveStroke();
    } else if (controller.tool == ToolType.brushErase || controller.tool == ToolType.restoreBrush) {
      controller.endStroke();
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