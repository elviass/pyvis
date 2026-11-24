import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:re_editor/re_editor.dart';

import 'python_analysis_service.dart';

typedef SourceFormat = ({TextLineBreak lineEnding, String encoding});

const defaultSourceFormat = (lineEnding: TextLineBreak.lf, encoding: 'utf-8');
const sourceEncodings = <String, String>{
  'utf-8': 'UTF-8',
  'utf-8-sig': 'UTF-8 BOM',
  'gbk': 'GBK',
  'gb18030': 'GB18030',
  'iso8859-1': 'ISO-8859-1',
};

String encodingLabel(String encoding) =>
    sourceEncodings[encoding] ?? encoding.toUpperCase();

final _lineBreak = RegExp(r'\r\n|\r|\n');
final _possibleCookie = RegExp(r'^[ \t\f]*#.*?coding[:=][ \t]*[-\w.]+');

class PythonSourceFile {
  final String text;
  final SourceFormat format;

  PythonSourceFile._(String raw, String encoding)
      : text = raw.replaceAll(_lineBreak, '\n'),
        format = (lineEnding: _detectLineEnding(raw), encoding: encoding);

  static TextLineBreak _detectLineEnding(String raw) {
    final counts = <TextLineBreak, int>{};
    for (final match in _lineBreak.allMatches(raw)) {
      final ending =
          TextLineBreak.values.firstWhere((v) => v.value == match[0]);
      counts.update(ending, (count) => count + 1, ifAbsent: () => 1);
    }
    return counts.entries
        .fold<MapEntry<TextLineBreak, int>>(const MapEntry(TextLineBreak.lf, 0),
            (best, entry) => entry.value > best.value ? entry : best)
        .key;
  }

  static bool _hasPossibleCookie(String text) {
    var start = 0, line = 0;
    for (final ending in _lineBreak.allMatches(text).take(2)) {
      if (_possibleCookie.hasMatch(text.substring(start, ending.start))) {
        return true;
      }
      start = ending.end;
      line++;
    }
    return line < 2 && _possibleCookie.hasMatch(text.substring(start));
  }

  static PythonSourceFile? tryUtf8(List<int> bytes) {
    try {
      final text = utf8.decode(bytes);
      if (_hasPossibleCookie(text)) return null;
      final bom = bytes.length >= 3 &&
          bytes[0] == 0xef &&
          bytes[1] == 0xbb &&
          bytes[2] == 0xbf;
      return PythonSourceFile._(text, bom ? 'utf-8-sig' : 'utf-8');
    } on FormatException {
      return null;
    }
  }

  static Future<PythonSourceFile> read(
      File file, PythonAnalysisService service) async {
    final bytes = await file.readAsBytes();
    final utf8File = tryUtf8(bytes);
    if (utf8File != null) return utf8File;
    final result = await service.request({
      'action': 'decode_source',
      'data': base64Encode(bytes),
    });
    return PythonSourceFile._(
        result['source'] as String, result['encoding'] as String);
  }

  static Future<String> convert(
      String source, String encoding, PythonAnalysisService service) async {
    if ((encoding == 'utf-8' || encoding == 'utf-8-sig') &&
        !_hasPossibleCookie(source)) {
      return source;
    }
    final result = await service.request({
      'action': 'convert_source',
      'source': source,
      'encoding': encoding,
    });
    return result['source'] as String;
  }

  static Future<void> write(File file, String text, SourceFormat format,
      PythonAnalysisService service) async {
    final source = text.replaceAll('\n', format.lineEnding.value);
    final encoding = format.encoding;
    final List<int> bytes;
    if ((encoding == 'utf-8' || encoding == 'utf-8-sig') &&
        !_hasPossibleCookie(source)) {
      final encoded = utf8.encode(source);
      bytes =
          encoding == 'utf-8-sig' ? [0xef, 0xbb, 0xbf, ...encoded] : encoded;
    } else {
      final result = await service.request({
        'action': 'encode_source',
        'source': source,
        'encoding': encoding,
      });
      bytes = base64Decode(result['data'] as String);
    }

    final target = await Link(file.path).exists()
        ? File(await file.resolveSymbolicLinks())
        : file.absolute;
    if (Platform.isMacOS) {
      try {
        await const MethodChannel('dev.pyvis/source_file').invokeMethod<void>(
            'write', {'path': target.path, 'data': Uint8List.fromList(bytes)});
        return;
      } on MissingPluginException {
        // Flutter unit tests have no native window or file channel.
      }
    }
    final oldStat = await target.stat();
    final staging = await target.parent.createTemp('.pyvis-save-');
    try {
      final draft = File(p.join(staging.path, 'source'));
      await draft.writeAsBytes(bytes, flush: true);
      if (!Platform.isWindows && oldStat.type == FileSystemEntityType.file) {
        final mode = oldStat.mode & 0x1ff;
        if (((await draft.stat()).mode & 0x1ff) != mode) {
          final result =
              await Process.run('chmod', [mode.toRadixString(8), draft.path]);
          if (result.exitCode != 0) {
            throw FileSystemException('无法保留文件权限', target.path);
          }
        }
      }
      await draft.rename(target.path);
    } finally {
      try {
        await staging.delete(recursive: true);
      } on FileSystemException {
        // A failed cleanup does not change whether the replacement succeeded.
      }
    }
  }
}
