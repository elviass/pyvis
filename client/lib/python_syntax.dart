import 'package:material_ui/material_ui.dart';
import 'package:re_highlight/styles/atom-one-dark.dart';

/// The editor and overview use one palette, including multiline syntax tokens.
final pythonTokenTheme = <String, TextStyle>{
  ...atomOneDarkTheme,
  'keyword': const TextStyle(color: Color(0xffcf8e6d)),
  'built_in': const TextStyle(color: Color(0xff8888c6)),
  'comment':
      const TextStyle(color: Color(0xff7a7e85), fontStyle: FontStyle.italic),
  'string': const TextStyle(color: Color(0xff6aab73)),
  'number': const TextStyle(color: Color(0xff2aacb8)),
  'title': const TextStyle(color: Color(0xffffc66d)),
};
const editorMiniMapWidth = 136.0;
