import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

typedef GraphCanvasBuilder = Widget Function(BuildContext context,
    Map<String, dynamic> scene, ValueChanged<Map> onEvent);

/// A single offline document avoids platform-specific file-origin restrictions.
class ComfyGraphAssets {
  static final Future<String> document = _load();
  static Future<String> _load() async {
    var html = await rootBundle.loadString('assets/graph/index.html');
    for (final name in ['vendor/litegraph.css', 'style.css']) {
      final css = await rootBundle.loadString('assets/graph/$name');
      html = html.replaceFirst(
          '<link rel="stylesheet" href="$name">', '<style>$css</style>');
    }
    for (final name in [
      'vendor/litegraph.umd.js',
      'model.js',
      'routing.js',
      'touch.js',
      'canvas.js'
    ]) {
      final js = await rootBundle.loadString('assets/graph/$name');
      html = html.replaceFirst('<script src="$name"></script>',
          '<script nonce="pyvis-local">${js.replaceAll('</script', r'<\/script')}</script>');
    }
    return html.replaceFirst("script-src 'self' 'unsafe-eval'",
        "script-src 'nonce-pyvis-local' 'unsafe-eval'");
  }
}

/// The actual ComfyUI LiteGraph renderer, loaded exclusively from bundled assets.
class ComfyGraphCanvas extends StatefulWidget {
  final Map<String, dynamic> scene;
  final ValueChanged<Map> onEvent;
  const ComfyGraphCanvas(
      {super.key, required this.scene, required this.onEvent});
  @override
  State<ComfyGraphCanvas> createState() => _ComfyGraphCanvasState();
}

class _ComfyGraphCanvasState extends State<ComfyGraphCanvas> {
  static int nextChannel = 0;
  late final MethodChannel nativeChannel;
  bool get nativeMac => defaultTargetPlatform == TargetPlatform.macOS;
  InAppWebViewController? controller;
  bool ready = false, sending = false, pending = false;
  Timer? loadTimeout;
  @override
  void initState() {
    super.initState();
    loadTimeout = Timer(const Duration(seconds: 12), () {
      if (mounted && !ready) {
        event({'action': 'error', 'message': '节点画布加载超时。'});
      }
    });
    nativeChannel = MethodChannel('dev.pyvis.comfy/${nextChannel++}');
    if (nativeMac) {
      nativeChannel.setMethodCallHandler((call) async {
        if (mounted && call.method == 'event' && call.arguments is Map) {
          event(Map<String, dynamic>.from(call.arguments as Map));
        }
      });
    }
  }

  void event(Map<String, dynamic> value) {
    if (value['action'] == 'ready') {
      if (!ready) {
        ready = true;
        loadTimeout?.cancel();
        widget.onEvent({'action': 'loading'});
        send();
      }
    } else {
      if (value['action'] == 'error' && !ready) loadTimeout?.cancel();
      widget.onEvent(value);
    }
  }

  @override
  void dispose() {
    loadTimeout?.cancel();
    if (nativeMac) nativeChannel.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ComfyGraphCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scene != widget.scene) send();
  }

  Future<void> send() async {
    pending = true;
    if (!ready || sending || !nativeMac && controller == null) return;
    sending = true;
    try {
      while (mounted && pending && ready) {
        pending = false;
        // JSON encoding also protects source strings from becoming JavaScript.
        final data = jsonEncode(widget.scene);
        if (nativeMac) {
          await nativeChannel.invokeMethod<void>('render', data);
        } else {
          await controller!
              .evaluateJavascript(source: 'window.PyvisCanvas.receive($data);');
        }
      }
    } catch (error) {
      if (mounted) widget.onEvent({'action': 'error', 'message': '$error'});
    } finally {
      sending = false;
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<String>(
      future: ComfyGraphAssets.document,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const Center(child: Text('离线画布资源加载失败。请重新打开程序。'));
        }
        if (!snapshot.hasData) {
          return const ColoredBox(color: Color(0xff202020));
        }
        if (nativeMac) {
          return LayoutBuilder(
              builder: (context, constraints) => AppKitView(
                  viewType: 'dev.pyvis.comfy',
                  creationParams: {
                    'channel': nativeChannel.name,
                    'html': snapshot.data!,
                    'width': constraints.maxWidth,
                    'height': constraints.maxHeight
                  },
                  creationParamsCodec: const StandardMessageCodec()));
        }
        return InAppWebView(
            key: const ValueKey('comfy-native-webview'),
            initialData: InAppWebViewInitialData(data: snapshot.data!),
            initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                transparentBackground: false,
                blockNetworkLoads: true,
                supportZoom: false,
                disableContextMenu: true,
                isInspectable: kDebugMode),
            onWebViewCreated: (value) {
              controller = value;
              value.addJavaScriptHandler(
                  handlerName: 'graph',
                  callback: (arguments) {
                    if (!mounted ||
                        arguments.isEmpty ||
                        arguments.first is! Map) {
                      return null;
                    }
                    event(Map<String, dynamic>.from(arguments.first as Map));
                    return null;
                  });
            },
            onLoadStop: (value, url) async {
              // The native bridge may become ready after the scripts' initial ready event.
              if (!mounted) return;
              final loaded = await value.evaluateJavascript(
                  source: 'Boolean(window.PyvisCanvas)');
              if (!mounted) return;
              if (loaded == true) {
                event({'action': 'ready'});
              } else if (!ready) {
                event({'action': 'error', 'message': '节点画布脚本未加载。'});
              }
            },
            onWebContentProcessDidTerminate: (_) {
              if (mounted) {
                event({'action': 'error', 'message': '节点画布进程已退出。'});
              }
            },
            onReceivedError: (value, request, error) {
              if (mounted && request.isForMainFrame == true) {
                event({'action': 'error', 'message': error.description});
              }
            });
      });
}
