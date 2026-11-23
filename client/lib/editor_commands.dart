import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:re_editor/re_editor.dart';
import 'python_completion.dart';

enum EditorCommand {
  renameVariable,
  duplicate,
  format,
  imports,
  definition,
  documentation,
  parameters,
  intentions,
  nextIssue,
  previousIssue,
  startNewLine,
  completeStatement,
  goToLine,
}

class PyCharmKeymap extends CodeShortcutsActivatorsBuilder {
  final bool mac;
  const PyCharmKeymap(this.mac);
  @override
  List<ShortcutActivator>? build(CodeShortcutType type) {
    if (type == CodeShortcutType.lineDelete) {
      return [
        mac
            ? const SingleActivator(LogicalKeyboardKey.backspace, meta: true)
            : const SingleActivator(LogicalKeyboardKey.keyY, control: true)
      ];
    }
    if (mac && type == CodeShortcutType.lineDeleteBackward) return const [];
    if (type == CodeShortcutType.newLine) {
      return const [
        SingleActivator(LogicalKeyboardKey.enter),
        SingleActivator(LogicalKeyboardKey.numpadEnter)
      ];
    }
    if (type == CodeShortcutType.lineSelect) return const [];
    if (type == CodeShortcutType.redo) {
      return [
        SingleActivator(LogicalKeyboardKey.keyZ,
            meta: mac, control: !mac, shift: true)
      ];
    }
    if (type == CodeShortcutType.lineMoveUp ||
        type == CodeShortcutType.lineMoveDown) {
      return [
        SingleActivator(
            type == CodeShortcutType.lineMoveUp
                ? LogicalKeyboardKey.arrowUp
                : LogicalKeyboardKey.arrowDown,
            alt: true,
            shift: true)
      ];
    }
    return DefaultCodeShortcutsActivatorsBuilder(macOS: mac).build(type);
  }

  Map<ShortcutActivator, VoidCallback> bindings(
      Map<EditorCommand, VoidCallback> actions) {
    SingleActivator primary(LogicalKeyboardKey key,
            {bool shift = false, bool alt = false}) =>
        SingleActivator(key, meta: mac, control: !mac, shift: shift, alt: alt);
    final map = <ShortcutActivator, EditorCommand>{
      const SingleActivator(LogicalKeyboardKey.f6, shift: true):
          EditorCommand.renameVariable,
      primary(LogicalKeyboardKey.keyD): EditorCommand.duplicate,
      primary(LogicalKeyboardKey.keyL, alt: true): EditorCommand.format,
      primary(LogicalKeyboardKey.keyO, alt: true): EditorCommand.imports,
      primary(LogicalKeyboardKey.keyB): EditorCommand.definition,
      mac
              ? const SingleActivator(LogicalKeyboardKey.f1)
              : const SingleActivator(LogicalKeyboardKey.keyQ, control: true):
          EditorCommand.documentation,
      primary(LogicalKeyboardKey.keyP): EditorCommand.parameters,
      const SingleActivator(LogicalKeyboardKey.enter, alt: true):
          EditorCommand.intentions,
      const SingleActivator(LogicalKeyboardKey.f2): EditorCommand.nextIssue,
      const SingleActivator(LogicalKeyboardKey.f2, shift: true):
          EditorCommand.previousIssue,
      const SingleActivator(LogicalKeyboardKey.enter, shift: true):
          EditorCommand.startNewLine,
      primary(LogicalKeyboardKey.enter, shift: true):
          EditorCommand.completeStatement,
      mac
              ? primary(LogicalKeyboardKey.keyL)
              : const SingleActivator(LogicalKeyboardKey.keyG, control: true):
          EditorCommand.goToLine,
    };
    return {
      for (final entry in map.entries)
        if (actions[entry.value] != null) entry.key: actions[entry.value]!
    };
  }

  String label(EditorCommand command) =>
      {
        EditorCommand.renameVariable: mac ? '⇧F6' : 'Shift+F6',
        EditorCommand.duplicate: mac ? '⌘D' : 'Ctrl+D',
        EditorCommand.format: mac ? '⌥⌘L' : 'Ctrl+Alt+L',
        EditorCommand.imports: mac ? '⌥⌘O' : 'Ctrl+Alt+O',
        EditorCommand.definition: mac ? '⌘B' : 'Ctrl+B',
        EditorCommand.documentation: mac ? 'F1' : 'Ctrl+Q',
        EditorCommand.parameters: mac ? '⌘P' : 'Ctrl+P',
        EditorCommand.intentions: mac ? '⌥↵' : 'Alt+Enter',
        EditorCommand.nextIssue: 'F2',
        EditorCommand.previousIssue: mac ? '⇧F2' : 'Shift+F2',
        EditorCommand.goToLine: mac ? '⌘L' : 'Ctrl+G',
      }[command] ??
      '';
}

void duplicateCode(CodeLineEditingController editor) {
  if (editor.isComposing) return;
  final s = editor.selection;
  if (!s.isCollapsed) {
    final text = editor.selectedText;
    editor.replaceSelection(text + text);
  } else {
    final line = editor.codeLines[s.extentIndex].text;
    editor.replaceSelection(
        '$line\n',
        CodeLineSelection(
            baseIndex: s.extentIndex,
            baseOffset: 0,
            extentIndex: s.extentIndex,
            extentOffset: 0));
    editor.selection = CodeLineSelection.collapsed(
        index: s.extentIndex + 1, offset: s.extentOffset);
  }
}

void startNewCodeLine(CodeLineEditingController editor,
    {bool complete = false}) {
  if (editor.isComposing) return;
  final s = editor.selection;
  final text = editor.codeLines[s.extentIndex].text;
  editor.selection =
      CodeLineSelection.collapsed(index: s.extentIndex, offset: text.length);
  if (complete &&
      RegExp(r'^\s*(?:async\s+)?(?:if|elif|else|while|for|def|class|try|except|finally|with|match|case)\b')
          .hasMatch(text) &&
      !text.trimRight().endsWith(':') &&
      pythonCodePosition(text)) {
    editor.replaceSelection(':');
  }
  insertPythonNewLine(editor);
}

/// Python suites use indentation. Existing collapsed children stay collapsed;
/// bracketed containers additionally use the upstream structural analyzer.
class PythonChunkAnalyzer implements CodeChunkAnalyzer {
  const PythonChunkAnalyzer();
  @override
  List<CodeChunk> run(CodeLines lines) {
    final chunks = <int, CodeChunk>{};
    for (final chunk in const DefaultCodeChunkAnalyzer().run(lines)) {
      chunks[chunk.index] = chunk;
    }
    var prefix = '';
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.chunkParent) {
        chunks[i] = CodeChunk(i, i + 1);
      } else if (pythonLineCode(line.text).trimRight().endsWith(':') &&
          pythonCodePosition(prefix)) {
        final indent = RegExp(r'^\s*')
            .firstMatch(line.text)![0]!
            .replaceAll('\t', '    ')
            .length;
        var end = i + 1;
        for (; end < lines.length; end++) {
          final text = lines[end].text;
          if (text.trim().isEmpty || text.trimLeft().startsWith('#')) continue;
          final next = RegExp(r'^\s*')
              .firstMatch(text)![0]!
              .replaceAll('\t', '    ')
              .length;
          if (next <= indent) break;
        }
        while (end > i + 1 && lines[end - 1].text.trim().isEmpty) {
          end--;
        }
        if (end > i + 1) chunks[i] = CodeChunk(i, end);
      }
      prefix += '${line.text}\n';
    }
    return chunks.values.toList()..sort((a, b) => a.index.compareTo(b.index));
  }
}

int revealSourceLine(CodeLineEditingController editor, int sourceLine) {
  var location = editor.lineIndex2Index(sourceLine);
  while (location.chunkIndex >= 0) {
    editor.expandChunk(location.index);
    location = editor.lineIndex2Index(sourceLine);
  }
  return location.index;
}

void expandAllCode(CodeLineEditingController editor) {
  for (var i = 0; i < editor.codeLines.length; i++) {
    if (editor.codeLines[i].chunkParent) {
      editor.expandChunk(i);
      i--;
    }
  }
}
