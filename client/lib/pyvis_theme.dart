import 'package:material_ui/material_ui.dart';

/// Shared visual language for the editor, learning panels and floating surfaces.
abstract final class PyvisColors {
  static const background = Color(0xff191a1c);
  static const canvas = Color(0xff1e1f22);
  static const surface = Color(0xff27282c);
  static const raised = Color(0xff2b2d30);
  static const border = Color(0xff393b40);
  static const text = Color(0xffbfc0c5);
  static const muted = Color(0xff86888e);
  static const accent = Color(0xff548af7);
  static const selection = Color(0xff2e436e);
  static const hover = Color(0xff34353a);
}

/// Same type colors as assets/graph/model.js; execution wires stay white.
Color pyvisTypeColor(String? type) => switch (type) {
      'bool' => const Color(0xffc26370),
      'int' => const Color(0xff6fcbaf),
      'float' => const Color(0xffc1db7f),
      'str' || 'output' => const Color(0xffdf86c9),
      'complex' => const Color(0xffde9e76),
      'bytes' => const Color(0xff6199ad),
      'NoneType' => const Color(0xffb2a8a3),
      'dict' => const Color(0xff69a7e1),
      'list' => const Color(0xff8e9adf),
      'tuple' => const Color(0xffb19bda),
      'set' => const Color(0xffe5cc83),
      'function' => const Color(0xffaf82b5),
      _ => const Color(0xffa8adb4),
    };

ThemeData pyvisTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(6),
      side: const BorderSide(color: PyvisColors.border));
  final menuShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(8),
      side: const BorderSide(color: Color(0xff494b50)));
  return base.copyWith(
    scaffoldBackgroundColor: PyvisColors.background,
    visualDensity: VisualDensity.compact,
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    colorScheme: const ColorScheme.dark(
      primary: PyvisColors.accent,
      onPrimary: Colors.white,
      secondary: PyvisColors.accent,
      secondaryContainer: PyvisColors.selection,
      onSecondaryContainer: PyvisColors.text,
      surface: PyvisColors.surface,
      onSurface: PyvisColors.text,
      outline: PyvisColors.border,
      error: Color(0xffe49b97),
    ),
    dividerColor: PyvisColors.border,
    dividerTheme: const DividerThemeData(
        color: PyvisColors.border, thickness: 1, space: 1),
    disabledColor: const Color(0xff686e79),
    hoverColor: PyvisColors.hover,
    focusColor: PyvisColors.selection,
    textTheme: base.textTheme
        .copyWith(
          bodyLarge: const TextStyle(fontSize: 13),
          bodyMedium: const TextStyle(fontSize: 13),
          bodySmall: const TextStyle(fontSize: 12),
          titleMedium: const TextStyle(fontSize: 13),
          titleSmall:
              const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
          labelLarge: const TextStyle(fontSize: 13),
        )
        .apply(
          fontFamily: base.platform == TargetPlatform.macOS
              ? '.AppleSystemUIFont'
              : 'Segoe UI',
          bodyColor: PyvisColors.text,
          displayColor: PyvisColors.text,
        ),
    menuTheme: MenuThemeData(
        submenuIcon:
            const WidgetStatePropertyAll(Icon(Icons.chevron_right, size: 15)),
        style: MenuStyle(
          backgroundColor: const WidgetStatePropertyAll(PyvisColors.raised),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          padding: const WidgetStatePropertyAll(EdgeInsets.all(4)),
          shape: WidgetStatePropertyAll(menuShape),
          elevation: const WidgetStatePropertyAll(6),
          shadowColor: const WidgetStatePropertyAll(Color(0x66000000)),
        )),
    menuButtonTheme: MenuButtonThemeData(
        style: ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size(200, 28)),
      visualDensity: VisualDensity.standard,
      shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(4))),
      foregroundColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.disabled)
              ? const Color(0xff686e79)
              : PyvisColors.text),
      iconColor: const WidgetStatePropertyAll(PyvisColors.muted),
      iconSize: const WidgetStatePropertyAll(16),
      overlayColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.hovered) ||
                  states.contains(WidgetState.focused)
              ? PyvisColors.selection
              : Colors.transparent),
      padding:
          const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 10)),
      textStyle: const WidgetStatePropertyAll(
          TextStyle(fontSize: 13, fontWeight: FontWeight.w400)),
    )),
    iconTheme: const IconThemeData(size: 18, color: PyvisColors.muted),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 500),
      textStyle: const TextStyle(fontSize: 12, color: PyvisColors.text),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: ShapeDecoration(color: PyvisColors.raised, shape: shape),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: PyvisColors.raised,
      surfaceTintColor: Colors.transparent,
      elevation: 6,
      shadowColor: const Color(0x66000000),
      menuPadding: const EdgeInsets.all(4),
      position: PopupMenuPosition.under,
      shape: menuShape,
      labelTextStyle: WidgetStateProperty.resolveWith((states) => TextStyle(
          fontSize: 13,
          color: states.contains(WidgetState.disabled)
              ? const Color(0xff686e79)
              : PyvisColors.text)),
      textStyle: const TextStyle(fontSize: 13, color: PyvisColors.text),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: PyvisColors.raised,
      surfaceTintColor: Colors.transparent,
      shape: shape,
      titleTextStyle: const TextStyle(
          fontSize: 16, fontWeight: FontWeight.w600, color: PyvisColors.text),
      contentTextStyle:
          const TextStyle(fontSize: 13, height: 1.5, color: PyvisColors.text),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: PyvisColors.canvas,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      hintStyle: const TextStyle(fontSize: 13, color: PyvisColors.muted),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(4)),
      enabledBorder: const OutlineInputBorder(
          borderSide: BorderSide(color: PyvisColors.border)),
      focusedBorder: const OutlineInputBorder(
          borderSide: BorderSide(color: PyvisColors.accent, width: 1.5)),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: PyvisColors.surface,
      selectedColor: PyvisColors.selection,
      side: const BorderSide(color: PyvisColors.border),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
      labelStyle: const TextStyle(fontSize: 12, color: PyvisColors.text),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
      shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(5))),
      side: const WidgetStatePropertyAll(BorderSide(color: PyvisColors.border)),
      textStyle: const WidgetStatePropertyAll(TextStyle(fontSize: 12)),
    )),
    listTileTheme: const ListTileThemeData(
      dense: true,
      selectedColor: PyvisColors.text,
      selectedTileColor: PyvisColors.selection,
    ),
    textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
      textStyle: const TextStyle(fontSize: 13),
      minimumSize: const Size(0, 28),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
    )),
    outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
      foregroundColor: PyvisColors.text,
      backgroundColor: PyvisColors.surface,
      side: const BorderSide(color: PyvisColors.border),
      minimumSize: const Size(72, 28),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      textStyle: const TextStyle(fontSize: 13),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
    )),
    filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
      textStyle: const TextStyle(fontSize: 13),
      minimumSize: const Size(72, 28),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
    )),
    scrollbarTheme: ScrollbarThemeData(
      thickness: const WidgetStatePropertyAll(7),
      radius: const Radius.circular(4),
      thumbColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.hovered)
              ? PyvisColors.muted
              : const Color(0xff555b66)),
    ),
  );
}
