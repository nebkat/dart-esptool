import 'package:flutter/material.dart';

/// One corner radius for everything. Material 3 rounds buttons and chips
/// far more than text fields; this puts them all on the text field's 4 px
/// so the toolbars read as one family.
ThemeData appTheme(Brightness brightness) {
  const radius = 4.0;
  const shape = RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(radius)));
  final base = ThemeData(colorSchemeSeed: const Color(0xFF3A6EA5), brightness: brightness);
  return base.copyWith(
    // Web and desktop default to compact density, which makes buttons
    // shorter than text fields; standard puts both at 40 px (fields via the
    // dense decoration below).
    visualDensity: VisualDensity.standard,
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(shape: shape)),
    elevatedButtonTheme: ElevatedButtonThemeData(style: ElevatedButton.styleFrom(shape: shape)),
    outlinedButtonTheme: OutlinedButtonThemeData(style: OutlinedButton.styleFrom(shape: shape)),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(shape: shape)),
    segmentedButtonTheme: SegmentedButtonThemeData(style: SegmentedButton.styleFrom(shape: shape)),
    // Icon buttons keep a 48 px tap target by default, which is real layout
    // space when one sits inside a text field (the dropdown arrow).
    iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(shape: shape, tapTargetSize: MaterialTapTargetSize.shrinkWrap)),
    chipTheme: base.chipTheme.copyWith(shape: shape),
    cardTheme: base.cardTheme.copyWith(shape: shape),
    dialogTheme: base.dialogTheme.copyWith(shape: shape),
    menuTheme: MenuThemeData(style: MenuStyle(shape: WidgetStatePropertyAll(shape))),
    popupMenuTheme: base.popupMenuTheme.copyWith(shape: shape),
    inputDecorationTheme: const InputDecorationTheme(
      // 24 px of text plus 8 px each side: 40 px, the same as the buttons.
      isDense: true,
      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      // Affix icons default to a 48 px box, which would push a field above
      // the 40 px the buttons get.
      prefixIconConstraints: BoxConstraints(minWidth: 40, minHeight: 40),
      suffixIconConstraints: BoxConstraints(minWidth: 40, minHeight: 40),
      border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(radius))),
    ),
  );
}
