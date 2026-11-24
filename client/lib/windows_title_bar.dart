import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

class WindowsTitleBar extends StatefulWidget {
  const WindowsTitleBar({
    super.key,
    required this.workspaceTitle,
    required this.menus,
  });

  final String workspaceTitle;
  final Map<String, List<Widget>> menus;

  @override
  State<WindowsTitleBar> createState() => _WindowsTitleBarState();
}

class _WindowsTitleBarState extends State<WindowsTitleBar> {
  static const _channel = MethodChannel('pyvis/window');
  // Match the native hit-test dimensions in win32_window.cpp.
  static const _height = 36.0;
  static const _buttonWidth = 46.0;
  static const _menuButtonWidth = 36.0;
  static const _menuItemWidth = 48.0;
  static const _wideMenuWidth = 500.0;
  final _firstMenu = MenuController();
  final _firstMenuKey = GlobalKey();
  bool _menuExpanded = false;
  bool _maximized = false;
  bool _maximizeHovered = false;

  @override
  void initState() {
    super.initState();
    _channel.setMethodCallHandler((call) async {
      if (!mounted || call.arguments is! bool) return;
      final value = call.arguments as bool;
      switch (call.method) {
        case 'maximized':
          setState(() => _maximized = value);
        case 'maximizeHovered':
          setState(() => _maximizeHovered = value);
      }
    });
  }

  @override
  void dispose() {
    _channel.setMethodCallHandler(null);
    super.dispose();
  }

  Widget _button(IconData icon, String label, String command,
      {bool close = false, bool hovered = false}) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      width: _buttonWidth,
      height: _height,
      child: IconButton(
        tooltip: label,
        iconSize: 17,
        style: IconButton.styleFrom(
          hoverColor: close ? colors.errorContainer : colors.surfaceContainer,
          backgroundColor: hovered ? colors.surfaceContainer : null,
          shape: const RoundedRectangleBorder(),
          padding: EdgeInsets.zero,
        ),
        onPressed: () => _channel.invokeMethod<void>(command),
        icon: Icon(icon),
      ),
    );
  }

  Widget _menuButton(VoidCallback press, {bool expanded = false}) => SizedBox(
        width: _menuButtonWidth,
        height: _height,
        child: IconButton(
          tooltip: expanded ? '收起主菜单' : '展开主菜单',
          iconSize: 19,
          onPressed: press,
          icon: Icon(expanded ? Icons.menu_open : Icons.menu),
        ),
      );

  void _toggleMenu() {
    setState(() => _menuExpanded = !_menuExpanded);
    _channel.invokeMethod<void>('menuExpanded', _menuExpanded);
    if (_menuExpanded) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _menuExpanded && _firstMenuKey.currentContext != null) {
          _firstMenu.open();
        }
      });
    }
  }

  Widget _menuBar() => MenuBar(
        style: const MenuStyle(
          elevation: WidgetStatePropertyAll(0),
          backgroundColor: WidgetStatePropertyAll(Colors.transparent),
          padding: WidgetStatePropertyAll(EdgeInsets.zero),
        ),
        children: [
          for (final entry in widget.menus.entries)
            SubmenuButton(
              key: entry.key == widget.menus.keys.first ? _firstMenuKey : null,
              controller:
                  entry.key == widget.menus.keys.first ? _firstMenu : null,
              style: ButtonStyle(
                padding: const WidgetStatePropertyAll(EdgeInsets.zero),
                minimumSize: const WidgetStatePropertyAll(Size.zero),
                fixedSize: const WidgetStatePropertyAll(
                  Size(_menuItemWidth, _height),
                ),
                textStyle: WidgetStatePropertyAll(
                  Theme.of(context).textTheme.labelMedium,
                ),
              ),
              menuChildren: entry.value,
              child: Text(entry.key),
            ),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surface,
      child: SizedBox(
        height: _height,
        child: LayoutBuilder(builder: (context, constraints) {
          final wide = constraints.maxWidth >= _wideMenuWidth;
          return Row(children: [
            if (constraints.maxWidth >= 240)
              SizedBox(
                width: _menuButtonWidth,
                child: Center(
                  child: Image.asset('assets/ide/pyvis.png',
                      width: 18, height: 18),
                ),
              ),
            if (wide)
              _menuButton(_toggleMenu, expanded: _menuExpanded)
            else
              MenuAnchor(
                menuChildren: [
                  for (final entry in widget.menus.entries)
                    SubmenuButton(
                      menuChildren: entry.value,
                      child: Text(entry.key),
                    ),
                ],
                builder: (context, controller, child) => _menuButton(
                  () => controller.isOpen
                      ? controller.close()
                      : controller.open(),
                  expanded: controller.isOpen,
                ),
              ),
            if (wide && _menuExpanded) _menuBar(),
            Expanded(
              child: wide && _menuExpanded
                  ? const SizedBox.shrink()
                  : Text(
                      widget.workspaceTitle,
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
            ),
            _button(Icons.remove, '最小化', 'minimize'),
            _button(
              _maximized ? Icons.filter_none : Icons.crop_square,
              _maximized ? '还原' : '最大化',
              'toggleMaximize',
              hovered: _maximizeHovered,
            ),
            _button(Icons.close, '关闭窗口', 'close', close: true),
          ]);
        }),
      ),
    );
  }
}
