import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

class WindowsTitleBar extends StatefulWidget {
  const WindowsTitleBar({super.key});

  @override
  State<WindowsTitleBar> createState() => _WindowsTitleBarState();
}

class _WindowsTitleBarState extends State<WindowsTitleBar> {
  static const _channel = MethodChannel('pyvis/window');
  // Match the native hit-test dimensions in win32_window.cpp.
  static const _height = 36.0;
  static const _buttonWidth = 46.0;
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

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surface,
      child: SizedBox(
        height: _height,
        child: Row(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    Image.asset('assets/ide/pyvis.png', width: 18, height: 18),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        'Pyvis',
                        overflow: TextOverflow.clip,
                        maxLines: 1,
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                    ),
                  ],
                ),
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
          ],
        ),
      ),
    );
  }
}
