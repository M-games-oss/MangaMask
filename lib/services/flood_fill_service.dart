import 'dart:typed_data';
import 'package:image/image.dart' as img;

/// On-device region selection. Manga art is almost always flat color/tone
/// cels bounded by black line-art, which makes contiguous flood fill a very
/// reliable "detector" for individual parts (an iris, a hair lock, a sleeve)
/// without needing any trained model at all.
class FloodFillService {
  /// Returns a 1-byte-per-pixel mask (255 = selected, 0 = not) starting at
  /// (startX, startY). [tolerance] 0-255 controls how far a pixel's color
  /// can be from the seed color and still be included. Line art (near-black,
  /// high contrast edges) naturally stops the fill.
  static Uint8List selectContiguous({
    required img.Image image,
    required int startX,
    required int startY,
    int tolerance = 24,
  }) {
    final w = image.width;
    final h = image.height;
    final mask = Uint8List(w * h);
    if (startX < 0 || startY < 0 || startX >= w || startY >= h) return mask;

    final seed = image.getPixel(startX, startY);

    // If the seed pixel has already been cut out (fully transparent), there
    // is nothing here to select. Without this guard, flood fill happily
    // treats the punched-out hole as a uniform "near-black" region and
    // re-selects the entire hole every time it's tapped again.
    if (seed.a == 0) return mask;

    final seedR = seed.r, seedG = seed.g, seedB = seed.b;

    bool close(img.Pixel p) {
      // Never merge into already-cut (transparent) pixels — they aren't
      // real artwork, just the hole left behind by a previous cut.
      if (p.a == 0) return false;
      final dr = (p.r - seedR).abs();
      final dg = (p.g - seedG).abs();
      final db = (p.b - seedB).abs();
      return dr <= tolerance && dg <= tolerance && db <= tolerance;
    }

    final visited = Uint8List(w * h);
    final stack = <int>[startY * w + startX];
    visited[startY * w + startX] = 1;

    while (stack.isNotEmpty) {
      final idx = stack.removeLast();
      final x = idx % w;
      final y = idx ~/ w;
      final p = image.getPixel(x, y);
      if (!close(p)) continue;
      mask[idx] = 255;

      // 4-connected neighbors
      if (x > 0 && visited[idx - 1] == 0) {
        visited[idx - 1] = 1;
        stack.add(idx - 1);
      }
      if (x < w - 1 && visited[idx + 1] == 0) {
        visited[idx + 1] = 1;
        stack.add(idx + 1);
      }
      if (y > 0 && visited[idx - w] == 0) {
        visited[idx - w] = 1;
        stack.add(idx - w);
      }
      if (y < h - 1 && visited[idx + w] == 0) {
        visited[idx + w] = 1;
        stack.add(idx + w);
      }
    }
    return mask;
  }

  /// Grows/shrinks a mask by [amount] pixels (simple box dilation/erosion).
  /// Useful for feathering a selection edge or tightening it against line art.
  static Uint8List dilate(Uint8List mask, int w, int h, int amount) {
    var current = mask;
    for (var step = 0; step < amount; step++) {
      final next = Uint8List(w * h);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final idx = y * w + x;
          if (current[idx] != 0) {
            next[idx] = 255;
            continue;
          }
          final hit = (x > 0 && current[idx - 1] != 0) ||
              (x < w - 1 && current[idx + 1] != 0) ||
              (y > 0 && current[idx - w] != 0) ||
              (y < h - 1 && current[idx + w] != 0);
          next[idx] = hit ? 255 : 0;
        }
      }
      current = next;
    }
    return current;
  }

  static Uint8List erode(Uint8List mask, int w, int h, int amount) {
    var current = mask;
    for (var step = 0; step < amount; step++) {
      final next = Uint8List(w * h);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final idx = y * w + x;
          if (current[idx] == 0) continue;
          final allIn = (x == 0 || current[idx - 1] != 0) &&
              (x == w - 1 || current[idx + 1] != 0) &&
              (y == 0 || current[idx - w] != 0) &&
              (y == h - 1 || current[idx + w] != 0);
          next[idx] = allIn ? 255 : 0;
        }
      }
      current = next;
    }
    return current;
  }
}