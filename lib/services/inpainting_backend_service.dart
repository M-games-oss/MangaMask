import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

/// Powers the "AI Remove Brush": paint over something you want gone (a
/// stray line, a signature, part of a panel border) and the backend
/// (LaMa inpainting) fills the hole using the surrounding art instead of
/// leaving a transparent/blank patch. Falls back to a soft transparent
/// erase if the backend isn't reachable, so the tool still works offline -
/// see [InpaintResult.usedFallback].
class InpaintingBackendService {
  InpaintingBackendService({required this.baseUrl});
  final String baseUrl;

  Future<InpaintResult> inpaint({
    required img.Image image,
    required Uint8List maskBrushedArea, // 255 = area to remove & fill
  }) async {
    try {
      final imgPng = img.encodePng(image);
      final maskImage = img.Image(width: image.width, height: image.height);
      for (var y = 0; y < image.height; y++) {
        for (var x = 0; x < image.width; x++) {
          final v = maskBrushedArea[y * image.width + x];
          maskImage.setPixelRgba(x, y, v, v, v, 255);
        }
      }
      final maskPng = img.encodePng(maskImage);

      final resp = await http
          .post(
            Uri.parse('$baseUrl/inpaint'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'image_png_base64': base64Encode(imgPng),
              'mask_png_base64': base64Encode(maskPng),
            }),
          )
          .timeout(const Duration(seconds: 25));

      if (resp.statusCode != 200) {
        return InpaintResult(image: null, usedFallback: true);
      }
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      final resultPng = base64Decode(body['result_png_base64'] as String);
      return InpaintResult(image: img.decodePng(resultPng), usedFallback: false);
    } catch (_) {
      return InpaintResult(image: null, usedFallback: true);
    }
  }
}

class InpaintResult {
  InpaintResult({required this.image, required this.usedFallback});
  final img.Image? image;
  final bool usedFallback;
}
