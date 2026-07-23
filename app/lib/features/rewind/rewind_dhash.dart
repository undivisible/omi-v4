import 'dart:typed_data';

/// The preview the difference hash is computed over: nine columns by eight
/// rows of luminance. The native side downscales the screen to roughly eighty
/// pixels wide and hands back these 72 bytes, so the similarity check never
/// touches a full-resolution frame and never decodes an encoded one.
const kRewindPreviewWidth = 9;
const kRewindPreviewHeight = 8;
const kRewindPreviewLength = kRewindPreviewWidth * kRewindPreviewHeight;

/// A 64-bit difference hash: one bit per horizontally adjacent pair, set when
/// the left sample is brighter than the right. Robust to the small luminance
/// drift of a cursor blink or an antialiased character, sensitive to a scroll
/// or a new window.
final class RewindPreviewHash {
  const RewindPreviewHash(this.bits);

  final int bits;

  static const empty = RewindPreviewHash(0);

  /// Builds a hash from a [kRewindPreviewLength]-byte luminance preview.
  /// Returns null for any other length rather than guessing at the layout.
  static RewindPreviewHash? fromLuma(Uint8List luma) {
    if (luma.length != kRewindPreviewLength) return null;
    var bits = 0;
    var bit = 0;
    for (var row = 0; row < kRewindPreviewHeight; row++) {
      final offset = row * kRewindPreviewWidth;
      for (var column = 0; column < kRewindPreviewWidth - 1; column++) {
        if (luma[offset + column] > luma[offset + column + 1]) {
          bits |= 1 << bit;
        }
        bit++;
      }
    }
    return RewindPreviewHash(bits);
  }

  static RewindPreviewHash? tryParse(String? hex) {
    if (hex == null || hex.isEmpty) return null;
    final bits = int.tryParse(hex, radix: 16);
    return bits == null ? null : RewindPreviewHash(bits);
  }

  /// Number of differing bits. Zero means the two previews are identical.
  int distanceTo(RewindPreviewHash other) {
    var difference = bits ^ other.bits;
    var count = 0;
    while (difference != 0) {
      difference &= difference - 1;
      count++;
    }
    return count;
  }

  String toHex() => bits.toUnsigned(64).toRadixString(16).padLeft(16, '0');

  @override
  bool operator ==(Object other) =>
      other is RewindPreviewHash && other.bits == bits;

  @override
  int get hashCode => bits.hashCode;

  @override
  String toString() => 'RewindPreviewHash(${toHex()})';
}
