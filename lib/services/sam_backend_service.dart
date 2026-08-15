import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

/// Talks to the FastAPI backend in /backend (Segment Anything / MobileSAM).
/// This is what gives real "tap the iris and only the iris gets selected"
/// behavior, because SAM is class-agnostic: it segments whatever object or
/// sub-part contains the point you clicked, at whatever granularity that
/// region naturally has - which is a far better fit for manga anatomy than
/// a fixed list of body-part classes would be.
///
/// Configure [baseUrl] to point at your deployed backend (see backend/README).
class SamBackendService {
  SamBackendService({required this.baseUrl});

  final String baseUrl;

  Future<bool> healthCheck() async {
    try {
      final resp = await http
          .get(Uri.parse('$baseUrl/health'))
          .timeout(const Duration(seconds: 4));
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Point-prompt segmentation. Returns a 0/255 mask the same size as the
  /// input image, or null on failure (caller should fall back to
  /// FloodFillService.selectContiguous so the app still works offline).
  Future<Uint8List?> segmentAtPoint({
    required img.Image image,
    required int x,
    required int y,
    bool positive = true,
  }) async {
    try {
      final pngBytes = img.encodePng(image);
      final resp = await http
          .post(
            Uri.parse('$baseUrl/segment_point'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'image_png_base64': base64Encode(pngBytes),
              'x': x,
              'y': y,
              'label': positive ? 1 : 0,
            }),
          )
          .timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) return null;
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      final maskB64 = body['mask_png_base64'] as String;
      final maskImg = img.decodePng(base64Decode(maskB64))!;
      return _grayscaleToMask(maskImg);
    } catch (_) {
      return null;
    }
  }

  /// Box-prompt segmentation (drag a rectangle around e.g. a whole arm).
  Future<Uint8List?> segmentInBox({
    required img.Image image,
    required int x0,
    required int y0,
    required int x1,
    required int y1,
  }) async {
    try {
      final pngBytes = img.encodePng(image);
      final resp = await http
          .post(
            Uri.parse('$baseUrl/segment_box'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'image_png_base64': base64Encode(pngBytes),
              'box': [x0, y0, x1, y1],
            }),
          )
          .timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) return null;
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      final maskB64 = body['mask_png_base64'] as String;
      final maskImg = img.decodePng(base64Decode(maskB64))!;
      return _grayscaleToMask(maskImg);
    } catch (_) {
      return null;
    }
  }

  Uint8List _grayscaleToMask(img.Image maskImg) {
    final out = Uint8List(maskImg.width * maskImg.height);
    for (var i = 0; i < out.length; i++) {
      final p = maskImg.getPixel(i % maskImg.width, i ~/ maskImg.width);
      out[i] = p.r > 127 ? 255 : 0;
    }
    return out;
  }
}
