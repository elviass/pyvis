import 'dart:io';

import 'python_json_worker.dart';

/// Local CPython analysis; source is parsed and compiled, never executed.
class PythonAnalysisService {
  final _worker = PythonJsonWorker(
    module: 'pyvis_runtime.code_intelligence',
    label: '代码检查',
    environment: {
      if (Platform.isMacOS &&
          Platform.resolvedExecutable.contains('.app/Contents/MacOS/'))
        'PYVIS_EDITOR_TOOLS':
            '${File(Platform.resolvedExecutable).parent.parent.path}/Helpers',
    },
  );

  Future<void> warmUp() => _worker.warmUp();

  Future<Map<String, dynamic>> analyze(String source, String filename,
          [String? project,
          Map<String, String>? buffers,
          List<String>? dictionary]) =>
      request({
        'source': source,
        'filename': filename,
        'project': project,
        'buffers': buffers,
        'dictionary': dictionary ?? [],
      });

  Future<Map<String, dynamic>> format(String source, String filename,
          {bool imports = false, String? selection}) =>
      request({
        'action': 'format',
        'source': source,
        'filename': filename,
        'imports': imports,
        'selection': selection
      });

  Future<Map<String, dynamic>> symbol(String action, String source,
          String filename, int line, int column, String? project,
          {String? candidate}) =>
      request({
        'action': action,
        'candidate': candidate,
        'source': source,
        'filename': filename,
        'line': line,
        'column': column,
        'project': project
      });

  Future<Map<String, dynamic>> complete(String source, String filename,
          int line, int column, String? project) =>
      request({
        'action': 'complete',
        'source': source,
        'filename': filename,
        'line': line,
        'column': column,
        'project': project
      });

  Future<Map<String, dynamic>> check(
          Map<String, String> sources, String entry, String project,
          {Map<String, String> sourceErrors = const {}}) =>
      request({
        'action': 'check',
        'sources': sources,
        if (sourceErrors.isNotEmpty) 'source_errors': sourceErrors,
        'entry': entry,
        'project': project
      });

  Future<Map<String, dynamic>> request(Map<String, dynamic> payload) async {
    final response = await _worker.request(payload, const Duration(seconds: 8));
    if (response['error'] != null) throw StateError('${response['error']}');
    return response;
  }

  void dispose() => _worker.dispose();
}
