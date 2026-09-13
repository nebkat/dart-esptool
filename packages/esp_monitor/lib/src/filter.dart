/// Which lines to show.
library;

import 'line.dart';

/// A filter over [MonitorLine]s. Every condition must hold.
class MonitorFilter {
  const MonitorFilter({
    this.maxLevel = LogLevel.verbose,
    this.hiddenTags = const {},
    this.query = '',
    this.regex = false,
    this.caseSensitive = false,
    this.logOnly = false,
  });

  /// The least severe level shown: [LogLevel.warning] shows errors and
  /// warnings. Lines that aren't log lines have no level and pass.
  final LogLevel maxLevel;

  /// Tags whose log lines are hidden.
  final Set<String> hiddenTags;

  /// Text the line must contain (or, with [regex], match).
  final String query;
  final bool regex;
  final bool caseSensitive;

  /// Hide everything that isn't a log line — `printf` output, boot banners
  /// and panics.
  final bool logOnly;

  static const none = MonitorFilter();

  bool get isEmpty => maxLevel == LogLevel.verbose && hiddenTags.isEmpty && query.isEmpty && !logOnly;

  /// The compiled query, or `null` when there is none. Throws
  /// [FormatException] for an invalid regular expression.
  RegExp? compile() {
    if (query.isEmpty) return null;
    return RegExp(regex ? query : RegExp.escape(query), caseSensitive: caseSensitive);
  }

  /// A [bool Function] for this filter, with the query compiled once.
  /// Throws [FormatException] for an invalid regular expression.
  bool Function(MonitorLine) matcher() {
    final pattern = compile();
    return (line) {
      if (logOnly && line.kind != LineKind.log) return false;
      final level = line.level;
      if (level != null && level.index > maxLevel.index) return false;
      final tag = line.tag;
      if (tag != null && hiddenTags.contains(tag)) return false;
      if (pattern != null && !pattern.hasMatch(line.text)) return false;
      return true;
    };
  }

  MonitorFilter copyWith({LogLevel? maxLevel, Set<String>? hiddenTags, String? query, bool? regex, bool? caseSensitive, bool? logOnly}) => MonitorFilter(
        maxLevel: maxLevel ?? this.maxLevel,
        hiddenTags: hiddenTags ?? this.hiddenTags,
        query: query ?? this.query,
        regex: regex ?? this.regex,
        caseSensitive: caseSensitive ?? this.caseSensitive,
        logOnly: logOnly ?? this.logOnly,
      );
}
