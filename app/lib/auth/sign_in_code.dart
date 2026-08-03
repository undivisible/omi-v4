/// The sign-in code as the Worker understands it.
///
/// The Worker normalises before it hashes, so a code pasted with its
/// surrounding punctuation, in the wrong case, or split by a stray space is
/// perfectly redeemable. The app used to reject those itself and report "that
/// code does not look right" for a code that would have worked, which reads as
/// the bot having sent a bad one. Normalise here to the same rule instead.
library;

/// Unambiguous alphabet, matching `LINK_CODE_ALPHABET` in the Worker: no O or
/// 0, no I, l or 1.
const signInCodeAlphabet = '23456789ABCDEFGHJKMNPQRSTUVWXYZ';

const signInCodeLength = 7;

/// An example that is actually redeemable-looking, for hint text. The old
/// `ab12cd3` used four characters the alphabet does not contain, so anyone
/// following it typed a code that could never exist.
const signInCodeExample = 'K7RM4QP';

/// Returns the canonical form of [value], or null when it cannot be one of
/// ours. Whitespace and the separators people paste around codes are dropped
/// before the check, exactly as the Worker does.
String? normalizeSignInCode(String value) {
  final buffer = StringBuffer();
  for (final rune in value.trim().toUpperCase().runes) {
    final character = String.fromCharCode(rune);
    if (character.trim().isEmpty ||
        character == '.' ||
        character == '_' ||
        character == '-') {
      continue;
    }
    buffer.write(character);
  }
  final normalized = buffer.toString();
  if (normalized.length != signInCodeLength) return null;
  for (final character in normalized.split('')) {
    if (!signInCodeAlphabet.contains(character)) return null;
  }
  return normalized;
}
