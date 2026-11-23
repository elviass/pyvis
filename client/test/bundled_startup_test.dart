import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show FlutterError;
import 'package:flutter_test/flutter_test.dart';
import 'package:pyvis_editor/runtime_adapter.dart';
import 'package:pyvis_editor/python_analysis_service.dart';

class BundledFixture extends CachingAssetBundle {
  final Map<String, Uint8List> files;
  BundledFixture(this.files);
  @override
  Future<ByteData> load(String key) async {
    if (key == 'AssetManifest.bin') {
      return const StandardMessageCodec().encodeMessage({
        for (final k in [
          ...files.keys,
          '../examples/.DS_Store',
          '../runtime/pyvis_runtime/.DS_Store'
        ])
          k: [
            {'asset': k}
          ]
      })!;
    }
    if (key.endsWith('.DS_Store')) throw FlutterError('empty metadata asset');
    final value = files[key];
    if (value == null) throw FlutterError('missing $key');
    return ByteData.sublistView(value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'packaged startup ignores Finder metadata, preserves learner files, and starts real completion',
      () async {
    final folder =
        await Directory.systemTemp.createTemp('pyvis-bundle-startup-');
    final learner = File('${folder.path}/examples/main.py');
    await learner.parent.create(recursive: true);
    await learner.writeAsString('print("learner")\n');
    final bytes = <String, Uint8List>{};
    for (final entity in Directory('../runtime/pyvis_runtime').listSync()) {
      if (entity is File && entity.path.endsWith('.py')) {
        bytes['../runtime/pyvis_runtime/${entity.uri.pathSegments.last}'] =
            await entity.readAsBytes();
      }
    }
    for (final file in Directory('../runtime/pyvis_runtime/vendor')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.whl'))) {
      bytes['../runtime/pyvis_runtime/vendor/${file.uri.pathSegments.last}'] =
          await file.readAsBytes();
    }
    bytes['../examples/main.py'] =
        Uint8List.fromList('print("seed")\n'.codeUnits);
    await RuntimeAdapter.prepareBundledRuntime(
        bundle: BundledFixture(bytes), workspace: folder);
    expect(await learner.readAsString(), 'print("learner")\n');
    expect(RuntimeAdapter.runtimePath, '${folder.path}/runtime');
    expect(File('${folder.path}/examples/.DS_Store').existsSync(), isFalse);
    final analysis = PythonAnalysisService();
    try {
      final result = await analysis.complete('Grades={"A":90}\nfor',
          '${folder.path}/examples/main.py', 2, 3, '${folder.path}/examples');
      expect(
          (result['context']['symbols'] as List)
              .any((s) => s['name'] == 'Grades' && s['detail'] == 'dict'),
          isTrue);
      expect((result['completions'] as List).any((s) => s['name'] == 'for'),
          isTrue);
    } finally {
      analysis.dispose();
      await folder.delete(recursive: true);
    }
  });
}
