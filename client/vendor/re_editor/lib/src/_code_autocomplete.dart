part of re_editor;

class _DefaultCodeAutocompletePromptsBuilder implements DefaultCodeAutocompletePromptsBuilder {

  final Mode? language;
  final List<CodeKeywordPrompt> keywordPrompts;
  final List<CodePrompt> directPrompts;
  final Map<String, List<CodePrompt>> relatedPrompts;

  final Set<CodePrompt> _allKeywordPrompts = {};

  _DefaultCodeAutocompletePromptsBuilder({
    this.language,
    required this.keywordPrompts,
    required this.directPrompts,
    required this.relatedPrompts
  }) {
    _allKeywordPrompts.addAll(keywordPrompts);
    _allKeywordPrompts.addAll(directPrompts);
    final dynamic keywords = language?.keywords;
    if (keywords is Map) {
      final dynamic keywordList = keywords['keyword'];
      if (keywordList is List) {
        _allKeywordPrompts.addAll(keywordList.map(
          (keyword) => CodeKeywordPrompt(word: keyword))
        );
      }
      final dynamic builtInList = keywords['built_in'];
      if (builtInList is List) {
        _allKeywordPrompts.addAll(builtInList.map(
          (keyword) => CodeKeywordPrompt(word: keyword))
        );
      }
      final dynamic literalList = keywords['literal'];
      if (literalList is List) {
        _allKeywordPrompts.addAll(literalList.map(
          (keyword) => CodeKeywordPrompt(word: keyword))
        );
      }
      final dynamic typeList = keywords['type'];
      if (typeList is List) {
        _allKeywordPrompts.addAll(typeList.map(
          (keyword) => CodeKeywordPrompt(word: keyword))
        );
      }
    }
  }

  @override
  CodeAutocompleteEditingValue? build(BuildContext context, CodeLine codeLine, CodeLineSelection selection) {
    final String text = codeLine.text;
    final Characters charactersBefore = text.substring(0, selection.extentOffset).characters;
    if (charactersBefore.isEmpty) {
      return null;
    }
    final Characters charactersAfter = text.substring(selection.extentOffset).characters;
    // FIXME：Check whether the position is inside a string
    if (charactersBefore.containsSymbols(const ['\'', '"']) && charactersAfter.containsSymbols(const ['\'', '"'])) {
      return null;
    }
    // TODO Should check operator `->` for some languages like c/c++
    final Iterable<CodePrompt> prompts;
    final String input;
    if (charactersBefore.takeLast(1).string == '.') {
      input = '';
      int start = charactersBefore.length - 2;
      for (; start >= 0; start--) {
        if (!charactersBefore.elementAt(start).isValidVariablePart) {
          break;
        }
      }
      final String target = charactersBefore.getRange(start + 1, charactersBefore.length - 1).string;
      prompts = relatedPrompts[target] ?? const [];
    } else {
      int start = charactersBefore.length - 1;
      for (; start >= 0; start--) {
        if (!charactersBefore.elementAt(start).isValidVariablePart) {
          break;
        }
      }
      input = charactersBefore.getRange(start + 1, charactersBefore.length).string;
      if (input.isEmpty) {
        return null;
      }
      if (start > 0 && charactersBefore.elementAt(start) == '.') {
        final int mark = start;
        for (start = start - 1; start >= 0; start--) {
          if (!charactersBefore.elementAt(start).isValidVariablePart) {
            break;
          }
        }
        final String target = charactersBefore.getRange(start + 1, mark).string;
        prompts = relatedPrompts[target]?.where(
          (prompt) => prompt.match(input)
        ) ?? const [];
      } else {
        prompts = _allKeywordPrompts.where(
          (prompt) => prompt.match(input)
        );
      }
    }
    if (prompts.isEmpty) {
      return null;
    }
    return CodeAutocompleteEditingValue(
      input: input,
      prompts: prompts.toList(),
      index: 0
    );
  }

}

class _CodeAutocomplete extends StatefulWidget {

  const _CodeAutocomplete({
    required this.viewBuilder,
    required this.promptsBuilder,
    required this.child,
    this.controller,
  });

  final CodeAutocompleteController? controller;
  final CodeAutocompleteWidgetBuilder viewBuilder;
  final CodeAutocompletePromptsBuilder promptsBuilder;
  final Widget child;

  @override
  State<StatefulWidget> createState() => _CodeAutocompleteState();

}

class _CodeAutocompleteState extends State<_CodeAutocomplete> {

  late final _CodeAutocompleteNavigateAction _navigateAction;
  late final _CodeAutocompleteAction _selectAction;

  ValueChanged<CodeAutocompleteResult>? _onAutocomplete;
  OverlayEntry? _overlayEntry;
  ValueNotifier<CodeAutocompleteEditingValue>? _notifier;
  CodeLineEditingValue? _lookupSource;
  LayerLink? _layerLink;
  Offset _position = Offset.zero;
  double _lineHeight = 0;

  @override
  void initState() {
    super.initState();
    widget.controller?._dismiss = dismiss;
    widget.controller?._select = (result) => _onAutocomplete?.call(result);
    _navigateAction = _CodeAutocompleteNavigateAction(
      onInvoke: (intent) {
        final CodeAutocompleteEditingValue? value = _notifier?.value;
        if (value == null) {
          return null;
        }
        int newIndex = value.index;
        if (intent.direction == AxisDirection.up) {
          newIndex--;
        } else {
          newIndex++;
        }
        if (newIndex < 0) {
          newIndex = value.prompts.length - 1;
        } else if (newIndex >= value.prompts.length) {
          newIndex = 0;
        }
        _notifier?.value = value.copyWith(
          index: newIndex,
        );
        return intent;
      },
    );
    _selectAction = _CodeAutocompleteAction<CodeShortcutNewLineIntent>(
      onInvoke: (intent) {
        final CodeAutocompleteEditingValue? value = _notifier?.value;
        if (value == null) {
          return null;
        }
        _onAutocomplete?.call(value.autocomplete);
        return intent;
      },
    );
  }

  @override
  void didUpdateWidget(covariant _CodeAutocomplete oldWidget) {
    super.didUpdateWidget(oldWidget);
  }

  @override
  void dispose() {
    dismiss();
    widget.controller?._request = null;
    widget.controller?._dismiss = null;
    widget.controller?._select = null;
    widget.controller?._cancelPending = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Actions(
      actions: {
        CodeShortcutCursorMoveIntent: _navigateAction,
        CodeShortcutNewLineIntent: _selectAction,
      },
      child: widget.child
    );
  }

  void show({
    required LayerLink layerLink,
    required Offset position,
    required double lineHeight,
    required CodeLineEditingValue value,
    required ValueChanged<CodeAutocompleteResult> onAutocomplete,
  }) {
    widget.controller?._allowRefresh = true;
    final next = widget.promptsBuilder.build(
      context, value.codeLines[value.selection.extentIndex], value.selection);
    if (next == null) {
      dismiss();
      // Keep async refresh enabled while the user is still typing a token.
      widget.controller?._allowRefresh = true;
      return;
    }
    var selected = 0;
    if (_notifier != null && _lookupSource?.selection == value.selection &&
        _lookupSource?.codeLines == value.codeLines) {
      final previous = _notifier!.value;
      final word = previous.prompts[previous.index].word;
      final match = next.prompts.indexWhere((prompt) => prompt.word == word);
      if (match >= 0) selected = match;
    }
    _lookupSource = value;
    _layerLink = layerLink;
    _position = position;
    _lineHeight = lineHeight;
    _onAutocomplete = onAutocomplete;
    if (_notifier == null) {
      _notifier = ValueNotifier(next.copyWith(index: selected));
      widget.controller?._value = _notifier;
      _overlayEntry = OverlayEntry(builder: (context) =>
          _buildWidget(context, _layerLink!, _position, _lineHeight));
      Overlay.of(context, rootOverlay: true).insert(_overlayEntry!);
    } else {
      _notifier!.value = next.copyWith(index: selected);
      _overlayEntry?.markNeedsBuild();
    }
    _navigateAction.setEnabled(true);
    _selectAction.setEnabled(true);
  }

  void dismiss() {
    widget.controller?._allowRefresh = false;
    widget.controller?._setBounds(null);
    widget.controller?._value = null;
    _notifier = null;
    _lookupSource = null;
    _onAutocomplete = null;
    _overlayEntry?.remove();
    _overlayEntry = null;
    _navigateAction.setEnabled(false);
    _selectAction.setEnabled(false);
  }

  Widget _buildWidget(BuildContext context, LayerLink layerLink, Offset position, double lineHeight) {
    final PreferredSizeWidget child = widget.viewBuilder(context, _notifier!, (result) {
      _onAutocomplete?.call(result);
    });
    final media = MediaQuery.of(context);
    final Size screenSize = media.size;
    final double visibleBottom = screenSize.height - (kIsAndroid ? media.viewInsets.bottom : 0);
    final double offsetX;
    if (position.dx + child.preferredSize.width > screenSize.width) {
      offsetX = screenSize.width - (position.dx + child.preferredSize.width);
    } else {
      offsetX = 0;
    }
    final double offsetY;
    if (position.dy + child.preferredSize.height > visibleBottom) {
      offsetY = -child.preferredSize.height - lineHeight;
    } else {
      offsetY = 0;
    }
    widget.controller?._setBounds(Rect.fromLTWH(position.dx + offsetX,
        position.dy + offsetY, child.preferredSize.width, child.preferredSize.height));
    return CompositedTransformFollower(
      link: layerLink,
      showWhenUnlinked: false,
      offset: Offset(offsetX, offsetY),
      child: Align(
        alignment: Alignment.topLeft,
        child: Material(
          color: Colors.transparent,
          child: TapRegion(
            groupId: widget.controller,
            onTapOutside: (event) {
              dismiss();
            },
            child: CodeEditorTapRegion(
              child: ExcludeSemantics(
                child: child,
              )
            )
          ),
        )
      ),
    );
  }

}

class _CodeAutocompleteAction<T extends Intent> extends CallbackAction<T> {

  bool _isEnabled = false;

  _CodeAutocompleteAction({
    required super.onInvoke
  });

  void setEnabled(bool enabled) {
    _isEnabled = enabled;
  }

  @override
  bool get isActionEnabled => _isEnabled;

}

class _CodeAutocompleteNavigateAction extends _CodeAutocompleteAction<CodeShortcutCursorMoveIntent> {

  _CodeAutocompleteNavigateAction({
    required super.onInvoke
  });

  @override
  bool consumesKey(CodeShortcutCursorMoveIntent intent) {
    return intent.direction == AxisDirection.up || intent.direction == AxisDirection.down;
  }

}

extension _CodeAutocompleteStringExtension on String {

  bool get isValidVariablePart {
    final int char = codeUnits.first;
    return (char >= 65 && char <= 90) || (char >= 97 && char <= 122) || char == 95;
  }

}

extension _CodeAutocompleteCharactersExtension on Characters {

  bool containsSymbols(List<String> symbols) {
    for (int i = length - 1; i >= 0; i--) {
      if (symbols.contains(elementAt(i))) {
        return true;
      }
    }
    return false;
  }

}
