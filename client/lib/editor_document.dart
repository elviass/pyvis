import 'package:re_editor/re_editor.dart';
import 'python_source_file.dart';

/// Each file owns its source, selection, folding and undo history.
class EditorDocument {
  final String path;
  final CodeLineEditingController controller;
  String savedText;
  SourceFormat format, savedFormat;
  double verticalOffset = 0, horizontalOffset = 0;
  EditorDocument(this.path, String text,
      {this.format = defaultSourceFormat, int indentSize = 4})
      : controller = CodeLineEditingController.fromText(
            text, CodeLineOptions(indentSize: indentSize)),
        savedText = text,
        savedFormat = format;
  EditorDocument.existing(
      this.path, this.controller, this.savedText, this.format)
      : savedFormat = format;
  bool get dirty => controller.text != savedText || format != savedFormat;
  bool readOnly = false;
  void dispose() => disposeDocumentController(controller);
}

final _disposedControllers = Expando<bool>();
void disposeDocumentController(CodeLineEditingController controller) {
  if (_disposedControllers[controller] == true) return;
  _disposedControllers[controller] = true;
  controller.dispose();
}
