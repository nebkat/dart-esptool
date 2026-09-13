/// ANSI SGR (`ESC [ … m`) colour and style decoding.
///
/// ESP-IDF colours a log line by level with `ESC[0;31m` (error, red),
/// `ESC[0;33m` (warning, yellow) or `ESC[0;32m` (info, green) and ends it
/// with `ESC[0m`; applications may use any SGR code. Other escape sequences
/// (cursor movement, clearing the screen) are dropped.
library;

/// The style of a run of text.
///
/// Colours are palette indices: 0–7 the normal colours (black, red, green,
/// yellow, blue, magenta, cyan, white), 8–15 their bright variants, and
/// 16–255 the xterm 256-colour palette. A 24-bit colour is stored as
/// `0x1000000 | rgb`.
class AnsiStyle {
  const AnsiStyle({this.foreground, this.background, this.bold = false, this.italic = false, this.underline = false, this.reverse = false});

  static const plain = AnsiStyle();

  final int? foreground;
  final int? background;
  final bool bold;
  final bool italic;
  final bool underline;
  final bool reverse;

  static const int rgbFlag = 0x1000000;

  bool get isPlain => this == plain;

  AnsiStyle _copy({Object? foreground = _keep, Object? background = _keep, bool? bold, bool? italic, bool? underline, bool? reverse}) => AnsiStyle(
        foreground: identical(foreground, _keep) ? this.foreground : foreground as int?,
        background: identical(background, _keep) ? this.background : background as int?,
        bold: bold ?? this.bold,
        italic: italic ?? this.italic,
        underline: underline ?? this.underline,
        reverse: reverse ?? this.reverse,
      );

  /// This style with the SGR [params] applied. An empty list means reset.
  AnsiStyle apply(List<int> params) {
    if (params.isEmpty) return plain;
    var style = this;
    for (var i = 0; i < params.length; i++) {
      final p = params[i];
      switch (p) {
        case 0:
          style = plain;
        case 1:
          style = style._copy(bold: true);
        case 3:
          style = style._copy(italic: true);
        case 4:
          style = style._copy(underline: true);
        case 7:
          style = style._copy(reverse: true);
        case 22:
          style = style._copy(bold: false);
        case 23:
          style = style._copy(italic: false);
        case 24:
          style = style._copy(underline: false);
        case 27:
          style = style._copy(reverse: false);
        case >= 30 && <= 37:
          style = style._copy(foreground: p - 30);
        case 39:
          style = style._copy(foreground: null);
        case >= 40 && <= 47:
          style = style._copy(background: p - 40);
        case 49:
          style = style._copy(background: null);
        case >= 90 && <= 97:
          style = style._copy(foreground: p - 90 + 8);
        case >= 100 && <= 107:
          style = style._copy(background: p - 100 + 8);
        case 38 || 48:
          // Extended colour: 5;n (palette) or 2;r;g;b (truecolour).
          int? colour;
          if (i + 2 < params.length && params[i + 1] == 5) {
            colour = params[i + 2] & 0xFF;
            i += 2;
          } else if (i + 4 < params.length && params[i + 1] == 2) {
            colour = rgbFlag | (params[i + 2] & 0xFF) << 16 | (params[i + 3] & 0xFF) << 8 | (params[i + 4] & 0xFF);
            i += 4;
          }
          if (colour != null) style = p == 38 ? style._copy(foreground: colour) : style._copy(background: colour);
      }
    }
    return style;
  }

  @override
  bool operator ==(Object other) =>
      other is AnsiStyle &&
      other.foreground == foreground &&
      other.background == background &&
      other.bold == bold &&
      other.italic == italic &&
      other.underline == underline &&
      other.reverse == reverse;

  @override
  int get hashCode => Object.hash(foreground, background, bold, italic, underline, reverse);
}

const _keep = Object();

/// A run of text in one style.
class AnsiSpan {
  const AnsiSpan(this.text, this.style);
  final String text;
  final AnsiStyle style;

  @override
  String toString() => style.isPlain ? text : '[$text]';
}

/// Splits lines into styled spans. Stateful: a style that isn't reset at the
/// end of a line carries on into the next, as it would on a terminal.
class AnsiDecoder {
  AnsiStyle style = AnsiStyle.plain;

  static final _sequence = RegExp(r'\x1b(?:\[([0-9;?]*)([@-~])|[@-Z\\-_]|$)');

  /// Decode one line (without its line ending).
  List<AnsiSpan> decode(String line) {
    if (!line.contains('\x1b')) return line.isEmpty ? const [] : [AnsiSpan(line, style)];
    final spans = <AnsiSpan>[];
    var at = 0;
    for (final match in _sequence.allMatches(line)) {
      if (match.start > at) spans.add(AnsiSpan(line.substring(at, match.start), style));
      at = match.end;
      if (match.group(2) == 'm') {
        final raw = match.group(1)!;
        style = style.apply(raw.isEmpty ? const [] : [for (final p in raw.split(';')) int.tryParse(p) ?? 0]);
      }
    }
    if (at < line.length) spans.add(AnsiSpan(line.substring(at), style));
    return spans;
  }

  void reset() => style = AnsiStyle.plain;
}
