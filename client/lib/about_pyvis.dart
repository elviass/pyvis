import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'pyvis_theme.dart';

class PyvisAboutDialog extends StatefulWidget {
  final Future<({String version, String executable})?> python;
  const PyvisAboutDialog({super.key, required this.python});

  @override
  State<PyvisAboutDialog> createState() => _PyvisAboutDialogState();
}

class _PyvisAboutDialogState extends State<PyvisAboutDialog> {
  late final information = (
    rootBundle.loadString('pubspec.yaml').then((source) =>
        RegExp(r'^version:\s*(\S+)', multiLine: true)
            .firstMatch(source)
            ?.group(1)
            ?.split('+')),
    widget.python,
  ).wait;
  bool copied = false;

  @override
  Widget build(BuildContext context) => Dialog(
      backgroundColor: PyvisColors.raised,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: const BorderSide(color: PyvisColors.border)),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
          width: 470,
          child: SingleChildScrollView(
              child: FutureBuilder(
                  future: information,
                  builder: (context, snapshot) {
                    final version = snapshot.data?.$1;
                    final ready =
                        snapshot.connectionState == ConnectionState.done;
                    final release = version == null ? '—' : 'v${version.first}';
                    final buildNumber = version?.elementAtOrNull(1) ?? '—';
                    final python =
                        snapshot.data?.$2?.version ?? (ready ? '未检测到' : '检测中…');
                    final system =
                        Platform.isMacOS ? 'macOS' : Platform.operatingSystem;
                    final details =
                        '构建号  $buildNumber\nPython  $python\nDart  ${Platform.version.split(' ').first}\n系统  $system · ${Platform.operatingSystemVersion}';
                    return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Container(
                              decoration: const BoxDecoration(
                                  gradient: LinearGradient(
                                      begin: Alignment.topLeft,
                                      end: Alignment.bottomRight,
                                      colors: [
                                    Color(0xff211b32),
                                    Color(0xff332945),
                                    Color(0xff282137)
                                  ])),
                              padding: const EdgeInsets.all(24),
                              child: Row(children: [
                                Image.asset('assets/ide/pyvis.png',
                                    width: 52, height: 52),
                                const SizedBox(width: 16),
                                Expanded(
                                    child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                      Text('Pyvis $release',
                                          style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 25,
                                              fontWeight: FontWeight.w600)),
                                      const Text('见微 · Python 图形化学习编辑器',
                                          style: TextStyle(
                                              color: Color(0xffd7c9e9)))
                                    ]))
                              ])),
                          Padding(
                              padding: const EdgeInsets.all(24),
                              child: SelectableText(details,
                                  style: const TextStyle(
                                      height: 1.7, fontSize: 13))),
                          const Divider(height: 1),
                          Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 12),
                              child: Row(children: [
                                TextButton.icon(
                                    icon: const Icon(Icons.copy_outlined,
                                        size: 15),
                                    label: Text(copied ? '已复制' : '复制信息'),
                                    onPressed: !ready
                                        ? null
                                        : () async {
                                            await Clipboard.setData(ClipboardData(
                                                text:
                                                    'Pyvis $release\n$details'));
                                            if (mounted) {
                                              setState(() => copied = true);
                                            }
                                          }),
                                const Spacer(),
                                FilledButton(
                                    autofocus: true,
                                    onPressed: () =>
                                        Navigator.of(context).pop(),
                                    child: const Text('确定'))
                              ]))
                        ]);
                  }))));
}
