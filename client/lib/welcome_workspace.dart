import 'dart:io';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'ide_chrome.dart';
import 'pyvis_theme.dart';

class WelcomeProjects extends StatefulWidget {
  final List<String> projects;
  final VoidCallback pick, create;
  final ValueChanged<String> open;
  const WelcomeProjects(
      {super.key,
      required this.projects,
      required this.pick,
      required this.create,
      required this.open});
  @override
  State<WelcomeProjects> createState() => _WelcomeProjectsState();
}

class _WelcomeProjectsState extends State<WelcomeProjects> {
  String query = '';
  @override
  Widget build(BuildContext context) {
    final paths = widget.projects
        .where((path) => path.toLowerCase().contains(query.toLowerCase()));
    return Material(
        color: PyvisColors.background,
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Padding(
              padding: EdgeInsets.all(14),
              child:
                  Text('项目和文件', style: TextStyle(fontWeight: FontWeight.w600))),
          const Divider(height: 1),
          Padding(
              padding: const EdgeInsets.fromLTRB(18, 10, 18, 14),
              child: Column(children: [
                for (final item in [
                  ('folder', '打开项目…', widget.pick),
                  ('add', '新建脚本…', widget.create)
                ])
                  Padding(
                      padding: const EdgeInsets.only(bottom: 7),
                      child: Material(
                          color: PyvisColors.surface,
                          borderRadius: BorderRadius.circular(8),
                          child: InkWell(
                              borderRadius: BorderRadius.circular(8),
                              onTap: item.$3,
                              child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 14, vertical: 10),
                                  child: Row(children: [
                                    ideIcon(item.$1),
                                    const SizedBox(width: 12),
                                    Text(item.$2)
                                  ]))))),
              ])),
          const Divider(height: 1),
          TextField(
              onChanged: (v) => setState(() => query = v),
              decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search, size: 18),
                  hintText: '搜索项目',
                  border: InputBorder.none)),
          const Divider(height: 1),
          Expanded(
              child: ListView(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  children: [
                if (paths.isEmpty)
                  Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(query.isEmpty ? '最近打开的项目会显示在这里' : '没有匹配的项目',
                          style: const TextStyle(color: PyvisColors.muted))),
                for (final path in paths)
                  ListTile(
                      leading: ideIcon('folder', size: 20),
                      title: Text(p.basename(path),
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(path,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      onTap: () => widget.open(path))
              ]))
        ]));
  }
}

class WelcomeLaunch extends StatelessWidget {
  final VoidCallback createProject,
      create,
      open,
      example,
      learn,
      settings,
      keymap,
      about;
  const WelcomeLaunch(
      {super.key,
      required this.createProject,
      required this.create,
      required this.open,
      required this.example,
      required this.learn,
      required this.settings,
      required this.keymap,
      required this.about});
  @override
  Widget build(BuildContext context) => Material(
      color: PyvisColors.background,
      child: Column(children: [
        Expanded(
            child: DecoratedBox(
                decoration: const BoxDecoration(
                    gradient: RadialGradient(
                        center: Alignment(0, -1),
                        radius: 1.15,
                        colors: [Color(0xff254c37), PyvisColors.background],
                        stops: [0, .86])),
                child: LayoutBuilder(builder: (context, box) {
                  final columns = box.maxWidth >= 320 ? 3 : 2;
                  final width =
                      ((box.maxWidth - 40 - (columns - 1) * 12) / columns)
                          .clamp(64.0, 128.0);
                  final items = [
                    ('folder', '新建项目', createProject),
                    ('python', '新建脚本', create),
                    ('module', '打开示例', example),
                    ('open', '打开文件', open),
                    ('packages', '学习提问', learn),
                  ];
                  return Center(
                      child: SingleChildScrollView(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          child: Column(children: [
                            Image.asset('assets/ide/pyvis.png',
                                width: 52, height: 52),
                            const SizedBox(height: 20),
                            const Text('欢迎使用 Pyvis',
                                style: TextStyle(
                                    fontSize: 22, fontWeight: FontWeight.w500)),
                            const SizedBox(height: 36),
                            SizedBox(
                                width: columns * width + (columns - 1) * 12,
                                child: Wrap(
                                    spacing: 12,
                                    runSpacing: 12,
                                    children: [
                                      for (final item in items)
                                        SizedBox(
                                            width: width,
                                            height: 88,
                                            child: Material(
                                                color: PyvisColors.surface,
                                                borderRadius:
                                                    BorderRadius.circular(8),
                                                child: InkWell(
                                                    onTap: item.$3,
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            8),
                                                    child: Column(
                                                        mainAxisAlignment:
                                                            MainAxisAlignment
                                                                .center,
                                                        children: [
                                                          ideIcon(item.$1,
                                                              size: 23),
                                                          const SizedBox(
                                                              height: 10),
                                                          Text(item.$2)
                                                        ]))))
                                    ]))
                          ])));
                }))),
        Wrap(alignment: WrapAlignment.center, children: [
          TextButton.icon(
              onPressed: keymap,
              icon: Icon(
                  Platform.isAndroid
                      ? Icons.touch_app_outlined
                      : Icons.keyboard_outlined,
                  size: 16),
              label: Text(Platform.isAndroid ? '触控操作' : '键盘映射')),
          TextButton.icon(
              onPressed: about,
              icon: const Icon(Icons.info_outline, size: 16),
              label: const Text('关于 Pyvis'))
        ])
      ]));
}
