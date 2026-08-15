import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/painting.dart';
import 'package:image/image.dart' as img;

/// A single editable layer (a cut-out body part, a duplicate, the base
/// artwork, etc). Pixel data lives in [pixels] (package:image, RGBA) so we
/// can do per-pixel flood fill / brush editing. [original] is an immutable
/// backup of the pixels this layer started with, used by the Restore Brush.
class ManagedLayer {
  ManagedLayer({
    required this.id,
    required this.name,
    required img.Image pixels,
    img.Image? original,
    this.visible = true,
    this.opacity = 1.0,
    this.offset = Offset.zero,
    this.locked = false,
  })  : _pixels = pixels,
        _original = original ?? img.Image.from(pixels);

  final String id;
  String name;
  bool visible;
  double opacity;
  Offset offset;
  bool locked;

  img.Image _pixels;
  final img.Image _original;

  ui.Image? _cachedUiImage;
  bool _dirty = true;

  img.Image get pixels => _pixels;
  img.Image get original => _original;
  int get width => _pixels.width;
  int get height => _pixels.height;

  void markDirty() => _dirty = true;

  void replacePixels(img.Image next) {
    _pixels = next;
    _dirty = true;
  }

  /// Lazily rebuilds and caches the ui.Image used for painting. Call
  /// [markDirty] after any pixel mutation, then await this before repaint.
  Future<ui.Image> uiImage() async {
    if (!_dirty && _cachedUiImage != null) return _cachedUiImage!;
    final bytes = _pixels.getBytes(order: img.ChannelOrder.rgba);
    final descriptor = ui.ImageDescriptor.raw(
      await ui.ImmutableBuffer.fromUint8List(Uint8List.fromList(bytes)),
      width: _pixels.width,
      height: _pixels.height,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    final codec = await descriptor.instantiateCodec();
    final frame = await codec.getNextFrame();
    _cachedUiImage = frame.image;
    _dirty = false;
    return _cachedUiImage!;
  }

  ManagedLayer duplicate(String newId, {String? newName}) {
    return ManagedLayer(
      id: newId,
      name: newName ?? '$name copy',
      pixels: img.Image.from(_pixels),
      original: img.Image.from(_original),
      visible: visible,
      opacity: opacity,
      offset: offset,
      locked: false,
    );
  }

  /// Snapshot for undo/redo (cheap-ish; fine for typical manga panel sizes).
  img.Image snapshotPixels() => img.Image.from(_pixels);
}
