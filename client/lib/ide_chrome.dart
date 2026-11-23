import 'dart:io';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'pyvis_theme.dart';

const ideSurface = PyvisColors.background;
const ideChrome = PyvisColors.surface;
const ideText = Color(0xffc8cbd2);
const ideMuted = Color(0xff9a9faa);

Widget ideIcon(String name, {double size = 16}) =>
    SvgPicture.asset('assets/ide/$name.svg', width: size, height: size);

class IdeButton extends StatelessWidget {
  final String icon, tooltip;
  final VoidCallback? onTap;
  final double extent, size;
  final bool selected;
  const IdeButton(
      {super.key,
      required this.icon,
      required this.tooltip,
      this.onTap,
      this.extent = 30,
      this.size = 16,
      this.selected = false});
  @override
  Widget build(BuildContext context) => SizedBox(
        width: extent,
        height: extent,
        child: IconButton(
          tooltip: tooltip,
          onPressed: onTap,
          isSelected: selected,
          padding: EdgeInsets.zero,
          style: ButtonStyle(
            minimumSize: const WidgetStatePropertyAll(Size.zero),
            shape: WidgetStatePropertyAll(
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(5))),
            backgroundColor: WidgetStateProperty.resolveWith((states) =>
                states.contains(WidgetState.selected)
                    ? PyvisColors.selection
                    : Colors.transparent),
            overlayColor: WidgetStateProperty.resolveWith((states) =>
                states.contains(WidgetState.focused)
                    ? PyvisColors.selection
                    : PyvisColors.hover),
            side: WidgetStateProperty.resolveWith((states) => BorderSide(
                color: states.contains(WidgetState.focused)
                    ? PyvisColors.accent
                    : Colors.transparent)),
          ),
          icon: Opacity(
              opacity: onTap == null ? .4 : 1,
              child: ideIcon(icon, size: size)),
        ),
      );
}

/// Desktop menus use 28px rows instead of Material's 48px touch targets.
class IdeMenuItem<T> extends PopupMenuItem<T> {
  const IdeMenuItem(
      {super.key,
      super.value,
      super.onTap,
      super.enabled,
      super.height = 28,
      super.padding = const EdgeInsets.symmetric(horizontal: 12),
      super.textStyle,
      super.labelTextStyle,
      super.mouseCursor,
      required super.child});
  @override
  PopupMenuItemState<T, IdeMenuItem<T>> createState() => _IdeMenuItemState<T>();
}

class _IdeMenuItemState<T> extends PopupMenuItemState<T, IdeMenuItem<T>> {
  @override
  Widget build(BuildContext context) => Theme(
      data: Theme.of(context).copyWith(
          hoverColor: PyvisColors.selection, focusColor: PyvisColors.selection),
      child: Material(
          type: MaterialType.transparency,
          borderRadius: BorderRadius.circular(4),
          clipBehavior: Clip.antiAlias,
          child: super.build(context)));
}

class IdeModeTabs<T> extends StatelessWidget {
  final Map<T, String> items;
  final T selected;
  final ValueChanged<T> onSelected;
  const IdeModeTabs(
      {super.key,
      required this.items,
      required this.selected,
      required this.onSelected});
  @override
  Widget build(BuildContext context) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        for (final item in items.entries)
          Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: TextButton(
                onPressed: () => onSelected(item.key),
                style: TextButton.styleFrom(
                  foregroundColor: selected == item.key
                      ? PyvisColors.text
                      : PyvisColors.muted,
                  backgroundColor: selected == item.key
                      ? PyvisColors.hover
                      : Colors.transparent,
                  minimumSize: const Size(0, 28),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  side: BorderSide(
                      color: selected == item.key
                          ? PyvisColors.border
                          : Colors.transparent),
                ),
                child: Text(item.value),
              )),
      ]);
}

/// Shared columns keep labels and shortcuts aligned across desktop menus.
class IdeMenuLabel extends StatelessWidget {
  final String label;
  final String? shortcut, icon;
  const IdeMenuLabel(this.label, {super.key, this.shortcut, this.icon});
  @override
  Widget build(BuildContext context) => Row(children: [
        SizedBox(
            width: 16, height: 16, child: icon == null ? null : ideIcon(icon!)),
        const SizedBox(width: 8),
        Expanded(
            child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis)),
        if (!Platform.isAndroid &&
            shortcut != null &&
            shortcut!.isNotEmpty) ...[
          const SizedBox(width: 28),
          Text(shortcut!,
              style: TextStyle(
                  fontSize: 12,
                  color: DefaultTextStyle.of(context)
                      .style
                      .color
                      ?.withValues(alpha: .65))),
        ],
      ]);
}
