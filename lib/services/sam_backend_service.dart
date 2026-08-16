import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

/// One include/exclude point to send to the backend, e.g. sampled along a
/// brush stroke. [positive] true = "this is part of the thing I want",
/// false = "this is NOT part of it" (used to correct SAM when it bleeds
/// into an overlapping limb/torso/background).
class SamPointPrompt {
  SamPointPrompt(this.x, this.y, this.positive);
  final int x;
  final int y;
  final bool positive;

  Map<String, dynamic> toJson() => {
        'x': x,
        'y': y,
        'label': positive ? 1 : 0,
      };
}

/// One of SAM's mask proposals. The backend returns up to 3 of these
/// (best-scoring first) instead of silently picking one — flat manga
/// backgrounds regularly cause the "highest confidence" mask to be the
/// whole background or whole figure, so the caller needs a real
/// alternative to fall back to instead of a single bad guess.
class SamMaskCandidate {
  SamMaskCandidate({required this.mask, required this.score});
  final Uint8List mask;
  final double score;
}

/// Talks to the FastAPI backend in /backend (Segment Anything / MobileSAM).
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

  /// Single-point prompt. Kept for callers that only have one point; prefer
  /// [segmentAtPoints] when you can supply more context (it's what the SAM
  /// brush tool uses).
  Future<List<SamMaskCandidate>?> segmentAtPoint({
    required img.Image image,
    required int x,
    required int y,
    bool positive = true,
  }) {
    return segmentAtPoints(
      image: image,
      points: [SamPointPrompt(x, y, positive)],
    );
  }

  /// Box-prompt segmentation (drag a rectangle around e.g. a whole arm).
  Future<List<SamMaskCandidate>?> segmentInBox({
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
      return _parseCandidates(resp);
    } catch (_) {
      return null;
    }
  }

  /// Multi-point prompt: a mix of include/exclude points, typically sampled
  /// along a brush stroke (and an "exclude" stroke drawn over whatever SAM
  /// keeps bleeding into, like an overlapping arm). This is what lets the
  /// user correct a bad guess instead of getting one shot from a single tap.
  Future<List<SamMaskCandidate>?> segmentAtPoints({
    required img.Image image,
    required List<SamPointPrompt> points,
  }) async {
    if (points.isEmpty) return null;
    try {
      final pngBytes = img.encodePng(image);
      final resp = await http
          .post(
            Uri.parse('$baseUrl/segment_points'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'image_png_base64': base64Encode(pngBytes),
              'points': points.map((p) => p.toJson()).toList(),
            }),
          )
          .timeout(const Duration(seconds: 20));
      return _parseCandidates(resp);
    } catch (_) {
      return null;
    }
  }

  List<SamMaskCandidate>? _parseCandidates(http.Response resp) {
    if (resp.statusCode != 200) return null;
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    final rawCandidates = body['candidates'] as List<dynamic>?;
    if (rawCandidates == null || rawCandidates.isEmpty) return null;

    final out = <SamMaskCandidate>[];
    for (final c in rawCandidates) {
      final maskB64 = c['mask_png_base64'] as String;
      final score = (c['score'] as num).toDouble();
      final maskImg = img.decodePng(base64Decode(maskB64));
      if (maskImg == null) continue;
      out.add(SamMaskCandidate(mask: _grayscaleToMask(maskImg), score: score));
    }
    return out.isEmpty ? null : out;
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