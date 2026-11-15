import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Compression settings, editable in Settings while we tune them (gate 1).
class CompressionSettings {
  const CompressionSettings({
    this.longSide = 1600,
    this.longReceiptSide = 2400,
    this.quality = 60,
    this.greyscale = true,
  });

  /// Longest side in pixels for an ordinary receipt.
  final int longSide;

  /// Longest side for long, narrow receipts (more than 2.2× taller than wide).
  final int longReceiptSide;

  /// JPEG quality, 1–100.
  final int quality;
  final bool greyscale;
}

class CompressedReceipt {
  CompressedReceipt({
    required this.full,
    required this.thumb,
    required this.width,
    required this.height,
    required this.originalBytes,
  });

  final Uint8List full;
  final Uint8List thumb;
  final int width;
  final int height;
  final int originalBytes;

  String get summary {
    String kb(int b) => b >= 1024 * 1024
        ? '${(b / (1024 * 1024)).toStringAsFixed(1)} MB'
        : '${(b / 1024).round()} KB';
    return '${kb(full.length)} · $width×$height (scan was ${kb(originalBytes)})';
  }
}

/// Shrinks a scanned receipt; runs off the main thread so the screen stays smooth.
Future<CompressedReceipt> compressReceipt(String path, CompressionSettings s) {
  final longSide = s.longSide;
  final longReceiptSide = s.longReceiptSide;
  final quality = s.quality.clamp(1, 100);
  final greyscale = s.greyscale;
  return Isolate.run(() {
    final bytes = File(path).readAsBytesSync();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) throw Exception('Could not read the scanned image.');
    var image = img.bakeOrientation(decoded);

    final w = image.width, h = image.height;
    final tall = h > w ? h / w : w / h;
    final limit = tall > 2.2 ? longReceiptSide : longSide;
    if (w >= h && w > limit) {
      image = img.copyResize(image, width: limit, interpolation: img.Interpolation.average);
    } else if (h > w && h > limit) {
      image = img.copyResize(image, height: limit, interpolation: img.Interpolation.average);
    }

    if (greyscale) {
      image = img.grayscale(image);
      // A little extra contrast helps faded thermal paper.
      image = img.adjustColor(image, contrast: 1.15);
    }

    final full = img.encodeJpg(image, quality: quality);
    final thumbImage = img.copyResize(image, width: 320, interpolation: img.Interpolation.average);
    final thumb = img.encodeJpg(thumbImage, quality: 70);

    return CompressedReceipt(
      full: full,
      thumb: thumb,
      width: image.width,
      height: image.height,
      originalBytes: bytes.length,
    );
  });
}

/// `YYYYMMDD-short-description` (lowercase, hyphens, at most 5 words).
String receiptBaseName(DateTime? date, String description) {
  final d = date == null
      ? '00000000'
      : '${date.year.toString().padLeft(4, '0')}'
          '${date.month.toString().padLeft(2, '0')}'
          '${date.day.toString().padLeft(2, '0')}';
  final words = description
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .trim()
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .take(5)
      .toList();
  final slug = words.isEmpty ? 'receipt' : words.join('-');
  return '$d-$slug';
}
