import 'python_json_worker.dart';

/// A separate parser process. It imports only our AST module, never user code.
class BlueprintService {
  final _worker = PythonJsonWorker(
    module: 'pyvis_runtime.blueprint',
    label: '代码图',
    decodeLargeResponsesOffThread: true,
  );

  Future<Map<String, dynamic>> parse(String source, {String mode = 'full'}) =>
      _worker.request(
        {'source': source, 'mode': mode},
        Duration(seconds: mode == 'nodes' ? 30 : 6),
      );

  Future<Map<String, dynamic>> lineView(
          String source, String scope, int line) =>
      _worker.request(
          {'source': source, 'mode': 'line', 'scope': scope, 'line': line},
          const Duration(seconds: 6));

  void dispose() => _worker.dispose();
}
