import 'dart:math';
import 'dart:typed_data';
import 'package:image/image.dart' as img;

/// Sobel-based edge magnitude map. Manga line art produces very strong,
/// clean edges, which is exactly what makes edge-snapping ("magnetic lasso")
/// and an edge-overlay assist so effective on this kind of art, even with
/// zero machine learning involved.
class EdgeDetectionService {
  /// Returns a Float32 width*height edge-strength map, normalized 0..1.
  static Float32List sobelMagnitude(img.Image image) {
    final w = image.width, h = image.height;
    final gray = Float32List(w * h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final p = image.getPixel(x, y);
        gray[y * w + x] = 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
      }
    }

    final mag = Float32List(w * h);
    double maxMag = 1e-6;
    for (var y = 1; y < h - 1; y++) {
      for (var x = 1; x < w - 1; x++) {
        final gx = -gray[(y - 1) * w + (x - 1)] +
            gray[(y - 1) * w + (x + 1)] -
            2 * gray[y * w + (x - 1)] +
            2 * gray[y * w + (x + 1)] -
            gray[(y + 1) * w + (x - 1)] +
            gray[(y + 1) * w + (x + 1)];
        final gy = -gray[(y - 1) * w + (x - 1)] -
            2 * gray[(y - 1) * w + x] -
            gray[(y - 1) * w + (x + 1)] +
            gray[(y + 1) * w + (x - 1)] +
            2 * gray[(y + 1) * w + x] +
            gray[(y + 1) * w + (x + 1)];
        final m = sqrt(gx * gx + gy * gy);
        mag[y * w + x] = m;
        if (m > maxMag) maxMag = m;
      }
    }
    for (var i = 0; i < mag.length; i++) {
      mag[i] = mag[i] / maxMag;
    }
    return mag;
  }

  /// Snaps [point] to the strongest nearby edge within [radius] pixels.
  /// Used while the user free-draws with the Magnetic Lasso so the path
  /// clings to line-art contours instead of requiring pixel-perfect input.
  static Point<int> snapToEdge(
    Float32List edgeMap,
    int w,
    int h,
    Point<int> point, {
    int radius = 6,
  }) {
    var best = point;
    var bestScore = -1.0;
    final x0 = max(0, point.x - radius);
    final x1 = min(w - 1, point.x + radius);
    final y0 = max(0, point.y - radius);
    final y1 = min(h - 1, point.y + radius);
    for (var y = y0; y <= y1; y++) {
      for (var x = x0; x <= x1; x++) {
        final score = edgeMap[y * w + x];
        if (score > bestScore) {
          bestScore = score;
          best = Point(x, y);
        }
      }
    }
    return bestScore > 0.25 ? best : point;
  }
}
