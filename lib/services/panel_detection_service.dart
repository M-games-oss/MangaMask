import 'dart:typed_data';
import 'package:image/image.dart' as img;

class DetectedPanel {
  DetectedPanel(this.x, this.y, this.width, this.height, this.pixelCount);
  final int x, y, width, height, pixelCount;
}

/// Finds manga panel boundaries on a scanned page. Most pages have a
/// near-white gutter between panels and a strong black border around each
/// panel, so thresholding + connected-component labeling on the "non
/// background" mask reliably isolates each panel as its own blob. This is a
/// separate, complementary step to character cutting: crop a panel first,
/// then run smart-select / AI-select inside it.
class PanelDetectionService {
  static List<DetectedPanel> detectPanels(
    img.Image page, {
    int backgroundThreshold = 235, // luminance above this = background/gutter
    int minPanelPixels = 2000,
  }) {
    final w = page.width, h = page.height;
    final isContent = Uint8List(w * h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final p = page.getPixel(x, y);
        final lum = 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
        isContent[y * w + x] = lum < backgroundThreshold ? 1 : 0;
      }
    }

    final labels = Int32List(w * h); // 0 = unlabeled
    var nextLabel = 1;
    final panels = <DetectedPanel>[];
    final stack = <int>[];

    for (var start = 0; start < w * h; start++) {
      if (isContent[start] == 0 || labels[start] != 0) continue;
      final label = nextLabel++;
      stack.add(start);
      labels[start] = label;

      var minX = start % w, maxX = start % w;
      var minY = start ~/ w, maxY = start ~/ w;
      var count = 0;

      while (stack.isNotEmpty) {
        final idx = stack.removeLast();
        final x = idx % w;
        final y = idx ~/ w;
        count++;
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;

        void tryPush(int nx, int ny) {
          if (nx < 0 || ny < 0 || nx >= w || ny >= h) return;
          final nIdx = ny * w + nx;
          if (isContent[nIdx] != 0 && labels[nIdx] == 0) {
            labels[nIdx] = label;
            stack.add(nIdx);
          }
        }

        tryPush(x - 1, y);
        tryPush(x + 1, y);
        tryPush(x, y - 1);
        tryPush(x, y + 1);
      }

      if (count >= minPanelPixels) {
        panels.add(DetectedPanel(
          minX,
          minY,
          maxX - minX + 1,
          maxY - minY + 1,
          count,
        ));
      }
    }

    // Merge boxes that heavily overlap (speech bubbles/art can fragment a
    // panel into multiple blobs); simple greedy union by bounding-box IoU.
    return _mergeOverlapping(panels);
  }

  static List<DetectedPanel> _mergeOverlapping(List<DetectedPanel> panels) {
    final merged = <DetectedPanel>[];
    final used = List<bool>.filled(panels.length, false);
    for (var i = 0; i < panels.length; i++) {
      if (used[i]) continue;
      var x = panels[i].x, y = panels[i].y;
      var x2 = panels[i].x + panels[i].width;
      var y2 = panels[i].y + panels[i].height;
      var pixels = panels[i].pixelCount;
      used[i] = true;
      var mergedAny = true;
      while (mergedAny) {
        mergedAny = false;
        for (var j = 0; j < panels.length; j++) {
          if (used[j]) continue;
          final ox = max(x, panels[j].x);
          final oy = max(y, panels[j].y);
          final ox2 = min(x2, panels[j].x + panels[j].width);
          final oy2 = min(y2, panels[j].y + panels[j].height);
          if (ox < ox2 && oy < oy2) {
            x = min(x, panels[j].x);
            y = min(y, panels[j].y);
            x2 = max(x2, panels[j].x + panels[j].width);
            y2 = max(y2, panels[j].y + panels[j].height);
            pixels += panels[j].pixelCount;
            used[j] = true;
            mergedAny = true;
          }
        }
      }
      merged.add(DetectedPanel(x, y, x2 - x, y2 - y, pixels));
    }
    return merged;
  }

  static int min(int a, int b) => a < b ? a : b;
  static int max(int a, int b) => a > b ? a : b;
}
