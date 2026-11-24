import 'dart:io';
import 'pyvis_theme.dart';
import 'package:material_ui/material_ui.dart';
import 'package:re_editor/re_editor.dart';

class _PythonLexicalFrame {
  final String? quote;
  final bool triple, formatted;
  int depth;
  _PythonLexicalFrame.string(this.quote, this.triple, this.formatted)
      : depth = 0;
  _PythonLexicalFrame.expression()
      : quote = null,
        triple = false,
        formatted = false,
        depth = 1;
}

/// Lexical context includes f-string expressions but excludes literal text.
bool pythonCodePosition(String text) {
  final frames = <_PythonLexicalFrame>[];
  var comment = false;
  for (var i = 0; i < text.length; i++) {
    final ch = text[i];
    if (comment) {
      if (ch == '\n') comment = false;
      continue;
    }
    final frame = frames.isEmpty ? null : frames.last;
    if (frame?.quote != null) {
      if (ch == r'\') {
        i++;
        continue;
      }
      final delimiter = frame!.quote! * (frame.triple ? 3 : 1);
      if (text.startsWith(delimiter, i)) {
        i += delimiter.length - 1;
        frames.removeLast();
        continue;
      }
      if (frame.formatted && ch == '{') {
        if (i + 1 < text.length && text[i + 1] == '{') {
          i++;
          continue;
        }
        frames.add(_PythonLexicalFrame.expression());
      } else if (frame.formatted &&
          ch == '}' &&
          i + 1 < text.length &&
          text[i + 1] == '}') {
        i++;
      }
      continue;
    }
    if (ch == '#') {
      comment = true;
      continue;
    }
    if (ch == '"' || ch == "'") {
      final triple = text.startsWith(ch * 3, i);
      final formatted = RegExp(r'\b(?:f|fr|rf)$', caseSensitive: false)
          .hasMatch(text.substring(i < 3 ? 0 : i - 3, i));
      frames.add(_PythonLexicalFrame.string(ch, triple, formatted));
      if (triple) i += 2;
    } else if (frame != null && ch == '{') {
      frame.depth++;
    } else if (frame != null && ch == '}') {
      if (--frame.depth == 0) frames.removeLast();
    }
  }
  return !comment && (frames.isEmpty || frames.last.quote == null);
}

class PythonPrompt extends CodePrompt {
  final String kind, detail, origin;
  final String? insertText, literalQuote;
  final bool existingParenthesis, hasParameters;
  const PythonPrompt(
      {required super.word,
      required this.kind,
      this.detail = '',
      this.origin = '',
      this.insertText,
      this.literalQuote,
      this.existingParenthesis = false,
      this.hasParameters = true});
  bool get callable => const ['函数', '方法', '内置函数', '类'].contains(kind);
  @override
  bool match(String input) =>
      word.startsWith(input) && (word != input || callable || kind == '关键字');
  @override
  CodeAutocompleteResult get autocomplete {
    final keywordSpace = kind == '关键字' &&
        const [
          'if',
          'elif',
          'for',
          'while',
          'def',
          'class',
          'return',
          'yield',
          'import',
          'from',
          'as',
          'with',
          'raise',
          'assert',
          'del',
          'global',
          'nonlocal',
          'except',
          'async',
          'await'
        ].contains(word);
    final insert = insertText ??
        (callable && !existingParenthesis
            ? '$word()'
            : keywordSpace
                ? '$word '
                : word);
    return CodeAutocompleteResult(
        input: '',
        word: insert,
        selection: TextSelection.collapsed(
            offset: insert.length -
                (insert.endsWith('()') && hasParameters ? 1 : 0)));
  }
}

class PythonPromptsBuilder implements CodeAutocompletePromptsBuilder {
  final CodeLineEditingController controller;
  Map<String, dynamic> analysis = {};
  String? semanticSource;
  int? semanticLine, semanticColumn;
  List<Map> semanticCompletions = [];
  PythonPromptsBuilder(this.controller);
  static final identifier =
      RegExp(r'[A-Za-z_\u0080-\uffff][A-Za-z0-9_\u0080-\uffff]*');
  List<PythonPrompt> suggestions(String source, int line, int offset) {
    final lines = source.split('\n');
    if (line < 0 ||
        line >= lines.length ||
        offset < 0 ||
        offset > lines[line].length) {
      return [];
    }
    final before = lines[line].substring(0, offset);
    final prefix = [...lines.take(line), before].join('\n');
    final semantic = semanticSource == source &&
        semanticLine == line &&
        semanticColumn == offset;
    final dictionary =
        RegExp(r'''[\w\u0080-\uffff]+\[(['"])([^'"\n]*)$''').firstMatch(before);
    if (controller.isComposing ||
        (!pythonCodePosition(prefix) && !(semantic && dictionary != null))) {
      return [];
    }
    if (RegExp(r'^\s*(?:async\s+)?(?:def|class)\s+[\w]*$').hasMatch(before)) {
      return [];
    }
    final importContext =
        RegExp(r'^\s*(?:from\s+\S+\s+import|import)\s+').hasMatch(before);
    final member =
        RegExp('(${identifier.pattern})\\.(${identifier.pattern})?\$')
            .firstMatch(before);
    final word = dictionary?.group(2) ??
        member?.group(2) ??
        RegExp('(${identifier.pattern})\$').firstMatch(before)?.group(1) ??
        '';
    final dotted = before.endsWith('.') ||
        RegExp(r'\.[\w\u0080-\uffff]*$').hasMatch(before);
    if (member == null &&
        word.isEmpty &&
        !(semantic && (dotted || dictionary != null))) {
      return [];
    }
    if (dotted && member == null && !semantic) return [];
    final suffix = lines[line].substring(offset);
    final candidates = <Map>[];
    if (semantic) {
      candidates.addAll(semanticCompletions);
    } else if (member != null) {
      candidates.addAll(
          ((analysis['members'] as Map?)?[member.group(1)] as List? ?? [])
              .cast<Map>());
    } else {
      candidates.addAll((analysis['symbols'] as List? ?? []).cast<Map>());
      // Pending/partial code still provides recently declared names, never all
      // words in the document (which would suggest comments and string data).
      final declared = RegExp(
          '(?:^|\\n)(?:(def|class)[ \\t]+(${identifier.pattern})|(${identifier.pattern})[ \\t]*=(?!=))');
      for (final match in declared.allMatches(source)) {
        candidates.add({
          'name': match.group(2) ?? match.group(3),
          'kind': match.group(1) == 'def'
              ? '函数'
              : match.group(1) == 'class'
                  ? '类'
                  : '变量',
          'start': 0
        });
      }
      candidates.addAll((analysis['builtins'] as List? ??
              [
                for (final name in [
                  'print',
                  'input',
                  'len',
                  'range',
                  'enumerate',
                  'int',
                  'float',
                  'str',
                  'list',
                  'dict',
                  'set',
                  'sum',
                  'sorted'
                ])
                  {'name': name, 'kind': '内置函数'},
                for (final name in [
                  'if',
                  'elif',
                  'else',
                  'for',
                  'while',
                  'def',
                  'return',
                  'class',
                  'import',
                  'from',
                  'try',
                  'except',
                  'finally',
                  'with',
                  'as',
                  'break',
                  'continue',
                  'True',
                  'False',
                  'None',
                  'and',
                  'or',
                  'not',
                  'in',
                  'pass'
                ])
                  {'name': name, 'kind': '关键字'}
              ])
          .cast<Map>());
    }
    final found = <String, PythonPrompt>{};
    final sorted = [...candidates]..sort((a, b) =>
        ((b['start'] as num?)?.toInt() ?? 0)
            .compareTo((a['start'] as num?)?.toInt() ?? 0));
    for (final candidate in sorted) {
      final start = (candidate['start'] as num?)?.toInt() ?? 0;
      final end = (candidate['end'] as num?)?.toInt() ?? 0;
      if (start > 0 && (line + 1 < start || line + 1 > end)) continue;
      final name = '${candidate['name']}';
      if (dictionary != null && semantic) {
        final quote = dictionary.group(1)!;
        if (name.startsWith(quote) && name.endsWith(quote)) {
          final key = name.substring(1, name.length - 1);
          found[name] = PythonPrompt(
              word: name,
              kind: '字典键',
              origin: '字典键',
              literalQuote: quote,
              insertText: key + (suffix.startsWith(quote) ? '' : quote));
        }
        continue;
      }
      final kind = '${candidate['kind'] ?? '变量'}';
      final callable = const ['函数', '方法', '内置函数', '类'].contains(kind);
      if ((name == word &&
              ((!callable && kind != '关键字') ||
                  importContext ||
                  suffix.trimLeft().startsWith('('))) ||
          (!semantic &&
              !name
                  .startsWith(member != null ? member.group(2) ?? '' : word)) ||
          (name.startsWith('__') && !word.startsWith('_'))) {
        continue;
      }
      found.putIfAbsent(
          name,
          () => PythonPrompt(
              word: name,
              kind: '${candidate['kind'] ?? '变量'}',
              detail: '${candidate['detail'] ?? ''}',
              origin: '${candidate['origin'] ?? ''}',
              hasParameters: candidate['has_parameters'] != false,
              existingParenthesis:
                  importContext || suffix.trimLeft().startsWith('(')));
    }
    final result = found.values.toList();
    final exact = result.indexWhere((p) => p.word == word);
    if (exact > 0) result.insert(0, result.removeAt(exact));
    return result.take(40).toList();
  }

  @override
  CodeAutocompleteEditingValue? build(
      BuildContext context, CodeLine line, CodeLineSelection selection) {
    if (!selection.isCollapsed || controller.isComposing) return null;
    final prompts = suggestions(
        controller.text,
        controller.index2lineIndex(selection.extentIndex),
        selection.extentOffset);
    if (prompts.isEmpty) return null;
    final before = line.text.substring(0, selection.extentOffset);
    final dictionary =
        RegExp(r'''[\w\u0080-\uffff]+\[(['"])([^'"\n]*)$''').firstMatch(before);
    final input = dictionary?.group(2) ??
        RegExp('(${identifier.pattern})\$').firstMatch(before)?.group(1) ??
        '';
    return CodeAutocompleteEditingValue(
        input: input, prompts: prompts, index: 0);
  }
}

List<TextSpan> completionNameSpans(String name, String input) {
  final at =
      input.isEmpty ? -1 : name.toLowerCase().indexOf(input.toLowerCase());
  if (at < 0) return [TextSpan(text: name)];
  return [
    TextSpan(text: name.substring(0, at)),
    TextSpan(
        text: name.substring(at, at + input.length),
        style: const TextStyle(
            color: PyvisColors.accent, fontWeight: FontWeight.w600)),
    TextSpan(text: name.substring(at + input.length))
  ];
}

class _CompletionKindIcon extends StatelessWidget {
  final String kind;
  const _CompletionKindIcon(this.kind);
  @override
  Widget build(BuildContext context) {
    final callable = const ['函数', '方法', '内置函数'].contains(kind);
    final color = callable
        ? const Color(0xffdb5c5c)
        : kind == '类'
            ? const Color(0xff548af7)
            : kind == '模块'
                ? const Color(0xffb99b55)
                : const Color(0xffc77dbb);
    return Container(
        width: 15,
        height: 15,
        alignment: Alignment.center,
        decoration: BoxDecoration(
            shape: BoxShape.circle, border: Border.all(color: color)),
        child: Text(
            callable
                ? 'f'
                : kind == '类'
                    ? 'C'
                    : kind == '模块'
                        ? 'm'
                        : kind == '关键字'
                            ? 'k'
                            : 'v',
            style: TextStyle(fontSize: 10, color: color, height: 1)));
  }
}

class PythonCompletionPopup extends StatefulWidget
    implements PreferredSizeWidget {
  final ValueNotifier<CodeAutocompleteEditingValue> notifier;
  final ValueChanged<CodeAutocompleteResult> onSelected;
  final double width;
  final VoidCallback? onClosed;
  const PythonCompletionPopup(
      {super.key,
      required this.notifier,
      required this.onSelected,
      this.width = 360,
      this.onClosed});
  @override
  Size get preferredSize => Size(
      width, (notifier.value.prompts.length.clamp(1, 9) * 28 + 28).toDouble());
  @override
  State<PythonCompletionPopup> createState() => _PythonCompletionPopupState();
}

class _PythonCompletionPopupState extends State<PythonCompletionPopup> {
  final scroll = ScrollController();
  @override
  void initState() {
    super.initState();
    widget.notifier.addListener(followSelection);
  }

  void followSelection() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !scroll.hasClients) return;
        final y = widget.notifier.value.index * 28.0;
        if (y < scroll.offset ||
            y + 28 > scroll.offset + scroll.position.viewportDimension) {
          scroll.jumpTo((y - scroll.position.viewportDimension + 28)
              .clamp(0.0, scroll.position.maxScrollExtent));
        }
      });
  @override
  void didUpdateWidget(covariant PythonCompletionPopup old) {
    super.didUpdateWidget(old);
    if (old.notifier != widget.notifier) {
      old.notifier.removeListener(followSelection);
      widget.notifier.addListener(followSelection);
    }
  }

  @override
  void dispose() {
    widget.notifier.removeListener(followSelection);
    widget.onClosed?.call();
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
      width: widget.width,
      height: widget.preferredSize.height,
      child: Material(
          color: PyvisColors.raised,
          elevation: 8,
          shape: RoundedRectangleBorder(
              side: const BorderSide(color: PyvisColors.border),
              borderRadius: BorderRadius.circular(6)),
          child: ValueListenableBuilder<CodeAutocompleteEditingValue>(
              valueListenable: widget.notifier,
              builder: (context, value, _) => Column(children: [
                    Expanded(
                        child: ListView.builder(
                            itemCount: value.prompts.length,
                            itemExtent: 28,
                            controller: scroll,
                            itemBuilder: (context, index) {
                              final prompt =
                                  value.prompts[index] as PythonPrompt;
                              return InkWell(
                                  onTap: () => widget.onSelected(value
                                      .copyWith(index: index)
                                      .autocomplete),
                                  child: Container(
                                      color: index == value.index
                                          ? PyvisColors.selection
                                          : null,
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 10, vertical: 3),
                                      child: Row(children: [
                                        _CompletionKindIcon(prompt.kind),
                                        const SizedBox(width: 8),
                                        Expanded(
                                            child: Semantics(
                                                label: prompt.word,
                                                child: RichText(
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    text: TextSpan(
                                                        style: const TextStyle(
                                                            fontFamily:
                                                                'JetBrains Mono',
                                                            fontSize: 13,
                                                            color: Color(
                                                                0xffbfc0c5)),
                                                        children: [
                                                          ...completionNameSpans(
                                                              prompt.word,
                                                              value.input),
                                                          if (prompt.detail
                                                              .startsWith(
                                                                  prompt.word))
                                                            TextSpan(
                                                                text: prompt
                                                                    .detail
                                                                    .substring(prompt
                                                                        .word
                                                                        .length),
                                                                style: const TextStyle(
                                                                    color: Color(
                                                                        0xff858992))),
                                                        ])))),
                                        ConstrainedBox(
                                            constraints: BoxConstraints(
                                                maxWidth: widget.width * .28),
                                            child: Text(
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                prompt.origin.isEmpty
                                                    ? prompt.kind
                                                    : prompt.origin,
                                                style: const TextStyle(
                                                    color: Color(0xffa6afbd),
                                                    fontSize: 10)))
                                      ])));
                            })),
                    SizedBox(
                        height: 24,
                        child: Center(
                            child: Text(
                                Platform.isAndroid
                                    ? '点按候选项插入代码'
                                    : '↵ 插入   Tab 替换   Esc 关闭',
                                style: TextStyle(
                                    fontSize: 10, color: Color(0xffa6afbd)))))
                  ]))));
}

/// IME owns navigation/confirmation until composition is committed.
class _CompletionAction<T extends Intent> extends CallbackAction<T> {
  final CodeLineEditingController editor;
  _CompletionAction(this.editor, {required super.onInvoke});
  @override
  bool consumesKey(T intent) => !editor.isComposing;
  @override
  Object? invoke(T intent) => editor.isComposing ? null : super.invoke(intent);
}

class PythonCompletionActions {
  final CodeLineEditingController editor;
  final CodeFindController? finder;
  final CodeAutocompleteController? popup;
  final bool Function()? acceptInline, dismissInline;
  ValueNotifier<CodeAutocompleteEditingValue>? _attached;
  ValueChanged<CodeAutocompleteResult>? _select;
  PythonCompletionActions(this.editor,
      {this.finder, this.popup, this.acceptInline, this.dismissInline});
  ValueNotifier<CodeAutocompleteEditingValue>? get _notifier =>
      popup == null ? _attached : popup!.notifier;
  void attach(ValueNotifier<CodeAutocompleteEditingValue> notifier,
      ValueChanged<CodeAutocompleteResult> select) {
    _attached = notifier;
    _select = select;
  }

  void detach(ValueNotifier<CodeAutocompleteEditingValue> notifier) {
    if (identical(_attached, notifier)) {
      _attached = null;
      _select = null;
    }
  }

  void dismissLookup() {
    if (popup != null) {
      popup!.dismiss();
    } else {
      _select?.call(const CodeAutocompleteResult(
          input: '', word: '', selection: TextSelection.collapsed(offset: 0)));
      _attached = null;
      _select = null;
    }
  }

  void confirm({bool replaceRest = false}) {
    final value = _notifier?.value;
    if (value == null) return;
    dismissInline?.call();
    var result = value.autocomplete;
    if (replaceRest) {
      final selection = editor.selection;
      final right = editor.codeLines[selection.extentIndex].text
          .substring(selection.extentOffset);
      var prompt = value.prompts[value.index];
      final quote = prompt is PythonPrompt ? prompt.literalQuote : null;
      final tail = quote != null
          ? right.split(quote).first
          : RegExp(r'^[A-Za-z0-9_\u0080-\uffff]+').firstMatch(right)?[0] ?? '';
      if (prompt is PythonPrompt &&
          right.substring(tail.length).trimLeft().startsWith('(')) {
        prompt = PythonPrompt(
            word: prompt.word,
            kind: prompt.kind,
            detail: prompt.detail,
            hasParameters: prompt.hasParameters,
            existingParenthesis: true);
      }
      final insertion = prompt.autocomplete;
      result = CodeAutocompleteResult(
          input: value.input,
          word: insertion.word,
          selection: TextSelection.collapsed(
              offset: insertion.selection.extentOffset - value.input.length),
          replaceRight: tail.length);
    }
    if (popup != null) {
      popup!.select(result);
    } else {
      _select?.call(result);
    }
  }

  void handleTab() {
    if (editor.isComposing) return;
    if (acceptInline?.call() ?? false) {
      dismissLookup();
    } else if (_notifier != null) {
      confirm(replaceRest: true);
    } else {
      editor.applyIndent();
    }
  }

  Map<Type, Action<Intent>> get actions => {
        CodeShortcutNewLineIntent:
            _CompletionAction<CodeShortcutNewLineIntent>(editor, onInvoke: (_) {
          if (_notifier != null) {
            confirm();
          } else {
            insertPythonNewLine(editor);
          }
          return null;
        }),
        CodeShortcutIndentIntent:
            _CompletionAction<CodeShortcutIndentIntent>(editor, onInvoke: (_) {
          handleTab();
          return null;
        }),
        CodeShortcutCursorMoveIntent:
            _CompletionAction<CodeShortcutCursorMoveIntent>(editor,
                onInvoke: (intent) {
          final value = _notifier?.value;
          if (value != null &&
              (intent.direction == AxisDirection.up ||
                  intent.direction == AxisDirection.down)) {
            dismissInline?.call();
            final offset = intent.direction == AxisDirection.up ? -1 : 1;
            _notifier!.value = value.copyWith(
                index: (value.index + offset) % value.prompts.length);
          } else {
            editor.moveCursor(intent.direction);
          }
          return null;
        }),
        CodeShortcutEscIntent:
            _CompletionAction<CodeShortcutEscIntent>(editor, onInvoke: (_) {
          final dismissed = dismissInline?.call() ?? false;
          if (_notifier != null || popup != null) {
            dismissLookup();
          }
          if (!dismissed && finder?.value != null) {
            finder!.close();
          } else if (!dismissed) {
            editor.cancelSelection();
          }
          return null;
        }),
      };
}

String pythonLineCode(String line) {
  for (var i = 0; i < line.length; i++) {
    if (line[i] == '#' && pythonCodePosition(line.substring(0, i))) {
      return line.substring(0, i);
    }
  }
  return line;
}

/// Python suites indent after a header; bracket pairs keep the closing token
/// on its own line. The edit is one undo operation and respects IME ownership.
void insertPythonNewLine(CodeLineEditingController editor) {
  if (editor.isComposing) return;
  final s = editor.selection;
  final before =
      editor.codeLines[s.startIndex].text.substring(0, s.startOffset);
  final after = editor.codeLines[s.endIndex].text.substring(s.endOffset);
  final indent = RegExp(r'^\s*').firstMatch(before)![0]!;
  final sourceLines = editor.text.split('\n');
  final sourceIndex = editor.index2lineIndex(s.startIndex);
  final code = pythonLineCode(before).trimRight();
  final prefix = [...sourceLines.take(sourceIndex), code].join('\n');
  final block =
      RegExp(r'^\s*(?:async\s+)?(?:if|elif|else|for|while|def|class|try|except|finally|with|match|case)\b')
              .hasMatch(code) &&
          code.endsWith(':') &&
          pythonCodePosition(prefix);
  final opening = before.trimRight().isEmpty
      ? ''
      : before.trimRight().substring(before.trimRight().length - 1);
  final closing = after.trimLeft().isEmpty ? '' : after.trimLeft()[0];
  final pair = const {'(': ')', '[': ']', '{': '}'}[opening] == closing &&
      closing.isNotEmpty &&
      pythonCodePosition(prefix);
  if (pair) {
    editor.replaceSelection('\n$indent${editor.options.indent}\n$indent');
    editor.selection = CodeLineSelection.collapsed(
        index: s.startIndex + 1,
        offset: indent.length + editor.options.indent.length);
  } else {
    editor.replaceSelection('\n$indent${block ? editor.options.indent : ''}');
  }
}
