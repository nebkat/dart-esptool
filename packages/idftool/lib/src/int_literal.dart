/// Parse an integer the way Python's `int(s, 0)` does, which is what the
/// ESP-IDF partition tooling accepts everywhere a number appears (CSV fields,
/// partition labels, slice bounds).
///
/// Accepted: surrounding whitespace, an optional sign, a `0x`/`0o`/`0b` radix
/// prefix (any case), and single underscores between digits. A decimal number
/// with a leading zero (`010`) is rejected, exactly like Python, because it is
/// ambiguous between octal and decimal. Returns `null` when [text] is not a
/// valid literal.
int? tryParseIntLiteral(String text) {
  var s = text.trim();
  var negative = false;
  if (s.startsWith('-') || s.startsWith('+')) {
    negative = s[0] == '-';
    s = s.substring(1);
  }

  var radix = 10;
  if (s.length >= 2 && s[0] == '0') {
    switch (s[1]) {
      case 'x' || 'X':
        radix = 16;
      case 'o' || 'O':
        radix = 8;
      case 'b' || 'B':
        radix = 2;
    }
    if (radix != 10) {
      s = s.substring(2);
      // Python allows one underscore directly after the prefix (`0x_ff`).
      if (s.startsWith('_')) s = s.substring(1);
    }
  }

  if (s.isEmpty || s.startsWith('_') || s.endsWith('_') || s.contains('__')) {
    return null;
  }
  final digits = s.replaceAll('_', '');
  if (!_digitsFor(radix).hasMatch(digits)) return null;
  if (radix == 10 && digits.length > 1 && digits[0] == '0' && digits.codeUnits.any((c) => c != 0x30)) {
    return null; // Leading zeros are only allowed on a literal zero.
  }

  final value = int.parse(digits, radix: radix);
  return negative ? -value : value;
}

RegExp _digitsFor(int radix) => switch (radix) {
      2 => _binary,
      8 => _octal,
      16 => _hex,
      _ => _decimal,
    };

final _binary = RegExp(r'^[01]+$');
final _octal = RegExp(r'^[0-7]+$');
final _decimal = RegExp(r'^[0-9]+$');
final _hex = RegExp(r'^[0-9a-fA-F]+$');

/// Format [value] as `0x…`, keeping the sign in front of the prefix like
/// Python's `f'{v:#x}'` (which the original tool's error messages use).
String hex(int value) => value < 0 ? '-0x${(-value).toRadixString(16)}' : '0x${value.toRadixString(16)}';
