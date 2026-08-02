import 'dart:ui';

/// The identify colour a pendant blinks so the row on screen can be matched to
/// the object in the room. The palette is the three LED primaries plus their
/// pairwise mixes: the pendant's LED is three PWM channels (red, green, blue in
/// `firmware/omi/src/led.c`), so a colour outside these six cannot be shown on
/// the hardware and would leave the row lying about what the user will see.
enum PendantIdentity {
  red(0, 'Red', Color(0xFFE53935)),
  green(1, 'Green', Color(0xFF43A047)),
  blue(2, 'Blue', Color(0xFF1E88E5)),
  yellow(3, 'Yellow', Color(0xFFF9A825)),
  cyan(4, 'Cyan', Color(0xFF00ACC1)),
  magenta(5, 'Magenta', Color(0xFF8E24AA));

  const PendantIdentity(this.code, this.label, this.color);

  /// Value written to the firmware identify characteristic (19b10018). Kept
  /// equal to the enum position so firmware and app agree without a table.
  final int code;
  final String label;
  final Color color;

  /// Derived from the device id rather than from pairing order, so a pendant
  /// keeps its colour when the others are forgotten, re-paired, or paired on a
  /// second phone. Dart's `String.hashCode` is seeded per process and would
  /// hand the same pendant a different colour on every launch, so this uses
  /// FNV-1a over the id's code units instead.
  static PendantIdentity forDeviceId(String deviceId) {
    var hash = 0x811c9dc5;
    for (final unit in deviceId.toLowerCase().codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
    }
    return values[hash % values.length];
  }

  static PendantIdentity? fromCode(int code) {
    for (final identity in values) {
      if (identity.code == code) return identity;
    }
    return null;
  }
}
