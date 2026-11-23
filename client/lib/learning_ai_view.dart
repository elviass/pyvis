import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'learning_ai.dart';
import 'provider_logo.dart';
import 'pyvis_theme.dart';
import 'ide_chrome.dart' show IdeMenuItem;

class _CompactMenuItem<T> extends DropdownMenuItem<T> {
  final double height;
  const _CompactMenuItem({
    super.value,
    super.enabled,
    this.height = 36,
    required super.child,
  });

  @override
  Widget build(BuildContext context) => SizedBox(
      height: height,
      child: Align(alignment: AlignmentDirectional.centerStart, child: child));
}

Widget _compactDropdown<T>({
  required Key key,
  required String label,
  required T? value,
  required List<DropdownMenuItem<T>> items,
  required ValueChanged<T?>? onChanged,
}) =>
    Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 340),
        child: DropdownButtonFormField<T>(
          key: key,
          initialValue: value,
          isExpanded: true,
          menuMaxHeight: 320,
          dropdownColor: PyvisColors.raised,
          borderRadius: BorderRadius.circular(6),
          decoration: InputDecoration(labelText: label),
          items: items,
          onChanged: onChanged,
        ),
      ),
    );

class AiSettingsPane extends StatefulWidget {
  final AiConfigStore? store;
  final bool? custom;
  const AiSettingsPane({super.key, this.store, this.custom});
  @override
  State<AiSettingsPane> createState() => _AiSettingsPaneState();
}

class _AiSettingsPaneState extends State<AiSettingsPane> {
  final endpoint = TextEditingController(),
      model = TextEditingController(),
      keyField = TextEditingController(),
      profileName = TextEditingController(text: '自定义服务'),
      providerId = TextEditingController();
  AiProfiles saved = const AiProfiles([], null);
  final drafts = <String, AiProfile>{};
  String selectedProfile = 'new', provider = 'custom';
  bool customPage = false;
  bool isCustom(AiProfile p) => p.provider == 'custom';
  Iterable<AiProfile> get visibleProfiles =>
      drafts.values.where((p) => isCustom(p) == customPage);
  final lastProfile = <bool, String>{};
  final pendingModelIds = <String, String>{};

  void rememberDraft() {
    drafts[selectedProfile] = snapshot();
    pendingModelIds[selectedProfile] = model.text;
  }

  AiProfile newProfile() {
    final preset = AiProviderPreset.all.first;
    return AiProfile(
        DateTime.now().microsecondsSinceEpoch.toString(),
        customPage
            ? '自定义 API ${drafts.length + 1}'
            : '服务商配置 ${drafts.length + 1}',
        customPage ? 'custom' : preset.id,
        AiConfig(customPage ? '' : preset.endpoint, '', '',
            protocol: customPage ? AiProtocol.chat : preset.protocol));
  }

  void switchCategory(bool custom) {
    if (customPage == custom) return;
    setState(() {
      rememberDraft();
      lastProfile[customPage] = selectedProfile;
      customPage = custom;
      final previous = drafts[lastProfile[custom]];
      final target = previous ?? visibleProfiles.firstOrNull ?? newProfile();
      drafts[target.id] = target;
      selectProfile(target);
      status = custom ? '配置自定义 API 地址、协议和模型。' : '选择模型提供商并填写该服务的密钥。';
    });
  }

  @override
  void didUpdateWidget(covariant AiSettingsPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.custom != null && widget.custom != oldWidget.custom) {
      switchCategory(widget.custom!);
    }
  }

  AiProtocol protocol = AiProtocol.chat;
  List<String> models = [];
  String? defaultModel;

  void addModel() {
    final id = model.text.trim();
    if (id.isEmpty) return;
    setState(() {
      if (!models.contains(id)) {
        models.add(id);
        status = '已添加模型，保存后可在学习提问中切换。';
      } else {
        status = '模型已在列表中。';
      }
      defaultModel ??= id;
      model.clear();
    });
  }

  void removeModel(String id) => setState(() {
        models.remove(id);
        if (defaultModel == id) defaultModel = models.firstOrNull;
      });

  AiConfig get config =>
      AiConfig(endpoint.text.trim(), defaultModel ?? '', keyField.text.trim(),
          protocol: protocol);

  AiProfile snapshot() => AiProfile(
      selectedProfile,
      profileName.text.trim().isEmpty ? '自定义服务' : profileName.text.trim(),
      provider,
      config,
      customId: customPage ? providerId.text.trim() : '',
      modelIds: List.of(models));
  void selectProfile(AiProfile p) {
    selectedProfile = p.id;
    provider = p.provider;
    providerId.text = p.customId.isEmpty ? 'custom-${p.id}' : p.customId;
    protocol = p.config.protocol;
    profileName.text = p.name;
    endpoint.text = p.config.endpoint;
    model.text = pendingModelIds[p.id] ?? '';
    keyField.text = p.config.key;
    models = p.modelIds;
    defaultModel = p.config.model.isEmpty ? models.firstOrNull : p.config.model;
  }

  void switchProfile(String id) {
    setState(() {
      rememberDraft();
      selectProfile(drafts[id]!);
      status = '编辑中的改动需保存后才会用于问答。';
    });
  }

  void addProfile() {
    setState(() {
      rememberDraft();
      final p = newProfile();
      drafts[p.id] = p;
      selectProfile(p);
      status = '请选择服务类型并填写独立的 API Key。';
    });
  }

  late final store = widget.store ?? AiConfigStore();
  bool busy = true;
  bool profilesLoaded = false;
  String status = '正在读取配置…';
  AiRequest? request;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      saved = await store.loadProfiles();
      profilesLoaded = true;
      if (!mounted) return;
      for (final p in saved.profiles) {
        drafts[p.id] = p;
      }
      customPage =
          widget.custom ?? (saved.active != null && isCustom(saved.active!));
      final active = saved.active;
      final target = active != null && isCustom(active) == customPage
          ? active
          : visibleProfiles.firstOrNull ?? newProfile();
      drafts[target.id] = target;
      selectProfile(target);
      status = saved.active == null ? '尚未配置模型服务。' : '已读取安全保存的配置。';
    } catch (e) {
      status = '$e';
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> perform(bool test, {bool fetchModels = false}) async {
    if (!fetchModels) addModel();
    setState(() {
      busy = true;
      status = fetchModels
          ? '正在获取模型列表…'
          : test
              ? '正在测试连接…'
              : '正在安全保存…';
    });
    try {
      if (fetchModels) {
        request = AiRequest();
        final result = await request!.listModels(config);
        if (!mounted) return;
        final oldCount = models.length;
        models = {...models, ...result}.toList();
        defaultModel ??= models.firstOrNull;
        status = models.length == oldCount
            ? '获取到的模型已全部在列表中。'
            : '已添加 ${models.length - oldCount} 个模型，保存后可在学习提问中切换。';
      } else if (test) {
        request = AiRequest();
        await request!.send(config, '请回复“连接成功”。', const {});
        status = '连接成功，模型可返回文字。配置需点击保存。';
      } else {
        final current = snapshot();
        if (customPage &&
            !RegExp(r'^[a-z][a-z0-9-]*$').hasMatch(current.customId)) {
          throw const AiFailure('Provider ID 需以小写字母开头，只包含小写字母、数字和连字符。');
        }
        if (customPage &&
            saved.profiles.any(
                (p) => p.id != current.id && p.customId == current.customId)) {
          throw const AiFailure('Provider ID 已存在，请使用其他标识。');
        }
        final updated = AiProfiles([
          for (final p in saved.profiles)
            if (p.id != current.id) p,
          current,
        ], current.id);
        await store.saveProfiles(updated);
        saved = updated;
        drafts[current.id] = current;
        status = '配置已安全保存。';
      }
    } catch (e) {
      status = '$e';
    } finally {
      request = null;
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    request?.cancel();
    endpoint.dispose();
    model.dispose();
    keyField.dispose();
    profileName.dispose();
    providerId.dispose();
    super.dispose();
  }

  void editProfile(AiProfile p) => setState(() {
        rememberDraft();
        lastProfile[customPage] = selectedProfile;
        customPage = isCustom(p);
        selectProfile(drafts[p.id] ?? p);
        status = '正在编辑 ${p.name}，修改后请保存。';
      });
  void cancelEdits() => setState(() {
        final target =
            saved.profiles.where((p) => p.id == selectedProfile).firstOrNull ??
                newProfile();
        drafts.remove(selectedProfile);
        pendingModelIds.remove(selectedProfile);
        drafts[target.id] = target;
        selectProfile(target);
        status = '已取消当前编辑，已保存的配置保持不变。';
      });
  Widget get providerField => _compactDropdown<String>(
      key: ValueKey('provider-$selectedProfile-$provider'),
      value: provider == 'custom' ? null : provider,
      label: '提供商',
      items: [
        for (final category in ['官方', '第三方']) ...[
          _CompactMenuItem<String>(
              enabled: false,
              height: 28,
              child: Text(category,
                  style:
                      const TextStyle(color: PyvisColors.muted, fontSize: 12))),
          for (final preset in AiProviderPreset.all
              .where((p) => p.label.startsWith('$category · ')))
            _CompactMenuItem<String>(
                value: preset.id,
                child: Row(children: [
                  ProviderLogo(preset.id, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                      child:
                          Text(preset.label, overflow: TextOverflow.ellipsis)),
                ])),
        ],
      ],
      onChanged: busy
          ? null
          : (id) => setState(() {
                final preset =
                    AiProviderPreset.all.firstWhere((p) => p.id == id);
                if (provider == id) return;
                provider = id!;
                protocol = preset.protocol;
                endpoint.text = preset.endpoint;
                profileName.text = preset.label;
                keyField.clear();
                model.clear();
                models = [];
                defaultModel = null;
                status = '请填写该提供商的 API 密钥。';
              }));
  Widget get protocolField => _compactDropdown<AiProtocol>(
      key: ValueKey('protocol-$selectedProfile-$protocol'),
      value: protocol,
      label: 'API 协议',
      items: AiProtocol.values
          .map((p) => _CompactMenuItem<AiProtocol>(
              value: p, child: Text(p.label, overflow: TextOverflow.ellipsis)))
          .toList(),
      onChanged: busy
          ? null
          : (value) => setState(() {
                protocol = value!;
                models = [];
                defaultModel = null;
                model.clear();
              }));
  Widget get endpointField => TextField(
      key: const ValueKey('ai-endpoint'),
      controller: endpoint,
      enabled: !busy,
      decoration: const InputDecoration(
          labelText: 'API 地址',
          hintText: 'https://gateway.example/v1',
          helperText: '填写包含 API 版本前缀的服务地址。',
          helperMaxLines: 2));
  Widget get nameField => TextField(
      key: const ValueKey('ai-name'),
      controller: profileName,
      enabled: !busy,
      decoration: const InputDecoration(labelText: '显示名称'));
  Widget get footer => Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Divider(height: 1),
        const SizedBox(height: 10),
        Semantics(
            liveRegion: true,
            child: Text(status,
                style: const TextStyle(fontSize: 12, height: 1.5))),
        const SizedBox(height: 10),
        Wrap(
            alignment: WrapAlignment.end,
            spacing: 12,
            runSpacing: 10,
            children: [
              if (!profilesLoaded && !busy)
                TextButton(
                    onPressed: () {
                      setState(() => busy = true);
                      load();
                    },
                    child: const Text('重试读取配置')),
              if (request != null)
                TextButton(
                    onPressed: () => request?.cancel(),
                    child: const Text('取消请求')),
              OutlinedButton(
                  style:
                      OutlinedButton.styleFrom(minimumSize: const Size(72, 32)),
                  onPressed: busy ? null : () => perform(true),
                  child: const Text('测试连接')),
              OutlinedButton(
                  style:
                      OutlinedButton.styleFrom(minimumSize: const Size(72, 32)),
                  onPressed: busy ? null : cancelEdits,
                  child: const Text('取消')),
              FilledButton(
                  style:
                      FilledButton.styleFrom(minimumSize: const Size(96, 32)),
                  onPressed:
                      busy || !profilesLoaded ? null : () => perform(false),
                  child: const Text('保存模型配置')),
            ]),
      ]));

  Future<void> openConfigFile() async {
    setState(() => busy = true);
    try {
      final file = AiConfigStore.publicConfigFile;
      if (file == null) throw const AiFailure('无法定位本机设置目录。');
      final contents = await store.writePublicConfig(file, saved);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('模型配置文件'),
          content: SizedBox(
            width: 620,
            height: 420,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('此文件是已保存设置的快照。请在模型设置页修改配置。'),
                const SizedBox(height: 8),
                SelectableText(file.path, style: const TextStyle(fontSize: 12)),
                const SizedBox(height: 12),
                Expanded(
                    child: SingleChildScrollView(
                  child: SelectableText(contents,
                      style: const TextStyle(
                          fontFamily: 'JetBrains Mono', fontSize: 12)),
                )),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () =>
                    Clipboard.setData(ClipboardData(text: file.path)),
                child: const Text('复制文件路径')),
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('关闭')),
          ],
        ),
      );
    } catch (_) {
      if (mounted) status = '无法打开模型配置文件，请检查本机设置目录。';
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget categoryTab(String label, bool custom) {
    final selected = customPage == custom;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      showCheckmark: false,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      selectedColor: PyvisColors.selection,
      backgroundColor: Colors.transparent,
      side:
          BorderSide(color: selected ? PyvisColors.accent : Colors.transparent),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
      onSelected: busy ? null : (_) => switchCategory(custom),
    );
  }

  @override
  Widget build(BuildContext context) =>
      LayoutBuilder(builder: (context, constraints) {
        final form =
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            const Icon(Icons.dns_outlined, size: 16),
            const SizedBox(width: 8),
            const Expanded(
                child: Text('模型服务',
                    style: TextStyle(fontWeight: FontWeight.w600))),
            OutlinedButton(
              onPressed: busy || !profilesLoaded ? null : openConfigFile,
              child: const Text('打开配置文件'),
            ),
          ]),
          const SizedBox(height: 14),
          for (final p in saved.profiles)
            Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                    border: Border.all(color: Theme.of(context).dividerColor),
                    color: PyvisColors.canvas,
                    borderRadius: BorderRadius.circular(6)),
                child: Row(children: [
                  ProviderLogo(p.provider, size: 20),
                  const SizedBox(width: 10),
                  Icon(
                      saved.activeId == p.id
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      color: saved.activeId == p.id
                          ? PyvisColors.accent
                          : PyvisColors.muted,
                      size: 14),
                  const SizedBox(width: 10),
                  Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        Text(p.name,
                            style:
                                const TextStyle(fontWeight: FontWeight.w600)),
                        const SizedBox(height: 4),
                        Text(
                            saved.activeId == p.id
                                ? '当前问答服务：${p.name} · ${p.config.model}'
                                : '已配置 · ${p.config.model}',
                            style: const TextStyle(fontSize: 12)),
                      ])),
                  const SizedBox(width: 10),
                  OutlinedButton(
                      onPressed: busy ? null : () => editProfile(p),
                      child: const Text('编辑'))
                ])),
          if (saved.profiles.isEmpty)
            const Padding(
                padding: EdgeInsets.only(bottom: 18),
                child: Text('尚未配置模型服务。',
                    style: TextStyle(color: PyvisColors.muted, fontSize: 12))),
          Container(
              padding: EdgeInsets.all(constraints.maxWidth < 450 ? 16 : 24),
              decoration: BoxDecoration(
                  color: PyvisColors.canvas,
                  border: Border.all(color: PyvisColors.border),
                  borderRadius: BorderRadius.circular(6)),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Wrap(spacing: 10, runSpacing: 8, children: [
                      categoryTab('模型提供商', false),
                      categoryTab('自定义模型 API', true),
                    ]),
                    const SizedBox(height: 12),
                    const Divider(height: 1),
                    const SizedBox(height: 20),
                    if (customPage) ...[
                      TextField(
                          key: const ValueKey('ai-provider-id'),
                          controller: providerId,
                          enabled: !busy,
                          decoration: const InputDecoration(
                              labelText: 'Provider ID',
                              hintText: 'acme-gateway',
                              helperText: '以小写字母开头的唯一配置标识，可包含数字和连字符。',
                              helperMaxLines: 2)),
                      const SizedBox(height: 16),
                      nameField,
                      const SizedBox(height: 16),
                      endpointField,
                      const SizedBox(height: 16),
                      protocolField,
                    ] else
                      providerField,
                    const SizedBox(height: 16),
                    TextField(
                        key: const ValueKey('ai-key'),
                        controller: keyField,
                        enabled: !busy,
                        obscureText: true,
                        enableSuggestions: false,
                        autocorrect: false,
                        decoration: const InputDecoration(labelText: 'API 密钥')),
                    const SizedBox(height: 16),
                    Text('模型列表（${models.length}）',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    if (models.isNotEmpty)
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 216),
                        child: ListView.separated(
                          primary: false,
                          shrinkWrap: true,
                          itemCount: models.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final id = models[index];
                            final isDefault = id == defaultModel;
                            return Row(children: [
                              Expanded(
                                  child: Tooltip(
                                      message: id,
                                      child: Text(id,
                                          overflow: TextOverflow.ellipsis))),
                              TextButton(
                                onPressed: busy || isDefault
                                    ? null
                                    : () => setState(() => defaultModel = id),
                                child: Text(isDefault ? '默认模型' : '设为默认'),
                              ),
                              IconButton(
                                tooltip: '移除 $id',
                                onPressed: busy ? null : () => removeModel(id),
                                icon: const Icon(Icons.close, size: 16),
                              ),
                            ]);
                          },
                        ),
                      ),
                    const SizedBox(height: 10),
                    TextField(
                        key: const ValueKey('ai-model'),
                        controller: model,
                        enabled: !busy,
                        onSubmitted: (_) => addModel(),
                        decoration: const InputDecoration(
                            labelText: '手动添加模型', hintText: '输入服务商提供的模型 ID')),
                    const SizedBox(height: 10),
                    Wrap(spacing: 10, runSpacing: 8, children: [
                      OutlinedButton(
                        onPressed: busy ? null : addModel,
                        child: const Text('添加模型'),
                      ),
                      OutlinedButton(
                        onPressed: busy
                            ? null
                            : () => perform(false, fetchModels: true),
                        child: const Text('获取模型列表'),
                      ),
                    ]),
                    if (!customPage) ...[
                      const SizedBox(height: 16),
                      const Divider(),
                      Material(
                          color: Colors.transparent,
                          child: ExpansionTile(
                              key: ValueKey('advanced-$selectedProfile'),
                              tilePadding: EdgeInsets.zero,
                              title: const Text('自定义设置'),
                              childrenPadding: const EdgeInsets.only(top: 8),
                              children: [
                                nameField,
                                const SizedBox(height: 16),
                                endpointField,
                                const SizedBox(height: 16),
                                protocolField,
                                const SizedBox(height: 16)
                              ])),
                    ],
                    const SizedBox(height: 16),
                    Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                            onPressed: busy ? null : addProfile,
                            child: Text(customPage ? '添加自定义 API' : '添加服务商'))),
                  ])),
        ]);
        if (!constraints.hasBoundedHeight) {
          return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [form, footer]);
        }
        return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                  child: SingleChildScrollView(
                      padding: const EdgeInsets.only(right: 4), child: form)),
              footer,
            ]);
      });
}

class AiSettingsDialog extends StatelessWidget {
  final AiConfigStore? store;
  const AiSettingsDialog({super.key, this.store});
  @override
  Widget build(BuildContext context) => Dialog(
      insetPadding: const EdgeInsets.all(20),
      child: SizedBox(
          width: 900,
          height: 780,
          child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(children: [
                Row(children: [
                  const Expanded(
                      child: Text('模型服务设置',
                          style: TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w600))),
                  IconButton(
                      tooltip: '关闭模型设置',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close))
                ]),
                const SizedBox(height: 16),
                Expanded(child: AiSettingsPane(store: store)),
              ]))));
}

typedef LearningReference = ({String label, Future<String> Function() read});

class LearningAiPanel extends StatefulWidget {
  final Map<String, String> available;
  final List<AiMessage> messages;
  final AiConfigStore? store;
  final bool inEditor;
  final VoidCallback? onChatsChanged;
  final VoidCallback? onModelChanged;
  final VoidCallback? onTogglePlacement;
  final AiRequest Function()? createRequest;
  final VoidCallback? onClose;
  final List<LearningReference> Function()? references;
  const LearningAiPanel(
      {super.key,
      required this.available,
      required this.messages,
      this.store,
      this.inEditor = false,
      this.onChatsChanged,
      this.onModelChanged,
      this.onTogglePlacement,
      this.createRequest,
      this.onClose,
      this.references});
  @override
  State<LearningAiPanel> createState() => LearningAiPanelState();
}

class LearningAiPanelState extends State<LearningAiPanel> {
  final input = TextEditingController();
  final questionFocus = FocusNode();
  bool expandedComposer = false;
  void setComposerSize() =>
      setState(() => expandedComposer = !expandedComposer);
  void updateFocusBorder() => setState(() {});
  bool get questionHasFocus => questionFocus.hasFocus && !busy;

  Future<void> pasteQuestion() async {
    if (busy) return;
    final pasted = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (!mounted || busy || pasted == null || pasted.isEmpty) return;
    final value = input.value;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : value.text.length;
    final end = selection.isValid ? selection.end : start;
    input.value = TextEditingValue(
      text: value.text.replaceRange(start, end, pasted),
      selection: TextSelection.collapsed(offset: start + pasted.length),
    );
    questionFocus.requestFocus();
  }

  final promptMenu = GlobalKey<PopupMenuButtonState<String>>();
  final scroll = ScrollController();
  final selected = <String>{};
  final references = <String, String>{};
  String? referenceQuery;
  String? referenceError;
  bool readingReference = false;

  RegExpMatch? referenceToken(String text, int offset) {
    if (offset < 0 || offset > text.length) return null;
    return RegExp(r'(?:^|\s)@([^@\s]*)$').firstMatch(text.substring(0, offset));
  }

  void updateReferenceQuery(String text) {
    if (text == "/") promptMenu.currentState?.showButtonMenu();
    setState(() {
      referenceQuery =
          referenceToken(text, input.selection.baseOffset)?.group(1);
      referenceError = null;
    });
  }

  Future<void> attachReference(LearningReference item,
      {bool removeToken = true}) async {
    if (busy || readingReference) return;
    final before = input.value;
    final offset = before.selection.baseOffset;
    final token = referenceToken(before.text, offset);
    setState(() {
      readingReference = true;
      referenceError = null;
    });
    try {
      final content = await item.read();
      if (!mounted) return;
      final next = {...references, item.label: content};
      final bytes = next.values
          .fold<int>(0, (total, text) => total + utf8.encode(text).length);
      if (bytes > 128 * 1024) throw const AiFailure('引用合计超过 128 KB，请移除部分引用。');
      if (removeToken && token != null && input.value == before) {
        final start = token.end - token.group(1)!.length - 1;
        input.value = TextEditingValue(
          text: before.text.replaceRange(start, offset, ''),
          selection: TextSelection.collapsed(offset: start),
        );
      }
      setState(() {
        references[item.label] = content;
        referenceQuery = null;
      });
    } on AiFailure catch (error) {
      if (mounted) setState(() => referenceError = error.message);
    } catch (_) {
      if (mounted) setState(() => referenceError = '无法读取该引用。');
    } finally {
      if (mounted) setState(() => readingReference = false);
    }
  }

  Widget referencePicker() {
    final query = referenceQuery;
    if (query == null) return const SizedBox.shrink();
    final items = widget.references!()
        .where((item) => item.label.toLowerCase().contains(query.toLowerCase()))
        .toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        const Expanded(child: Text('选择要引用的代码或文件')),
        IconButton(
            tooltip: '关闭引用列表',
            icon: const Icon(Icons.close, size: 16),
            onPressed: () => setState(() => referenceQuery = null)),
      ]),
      if (items.isEmpty)
        const Text('没有匹配的引用。')
      else
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 144),
          child: ListView.builder(
            shrinkWrap: true,
            primary: false,
            itemCount: items.length,
            itemBuilder: (context, index) => Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: readingReference || busy
                    ? null
                    : () => attachReference(items[index]),
                child:
                    Text(items[index].label, overflow: TextOverflow.ellipsis),
              ),
            ),
          ),
        ),
    ]);
  }

  bool busy = false;
  AiRequest? request;
  late final store = widget.store ?? AiConfigStore();
  AiProfiles profiles = const AiProfiles([], null);
  (String, String)? selectedModel;
  String get selectedProvider {
    final selection = selectedModel;
    if (selection == null) return 'custom';
    return profiles.profiles
            .where((profile) => profile.id == selection.$1)
            .firstOrNull
            ?.provider ??
        'custom';
  }

  String? configurationError;
  bool keychainLocked = false;
  bool loadingModels = true;
  (String, String)? previewContent;

  @override
  void didUpdateWidget(covariant LearningAiPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.inEditor && !oldWidget.inEditor) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.inEditor) questionFocus.requestFocus();
      });
    }
    selected.removeWhere(
        (name) => oldWidget.available[name] != widget.available[name]);
  }

  @override
  void initState() {
    super.initState();
    questionFocus.addListener(updateFocusBorder);
    loadModels();
  }

  Future<void> loadModels(
      {bool allowInteraction = false, AiProfiles? alreadyLoaded}) async {
    if (!loadingModels) setState(() => loadingModels = true);
    try {
      final catalog = allowInteraction || alreadyLoaded != null
          ? null
          : await store.loadModelCatalog();
      final loaded = alreadyLoaded ??
          catalog ??
          await store.loadProfiles(allowInteraction: allowInteraction);
      if (!mounted) return;
      final active = loaded.active;
      final selection = selectedModel;
      setState(() {
        configurationError = null;
        keychainLocked = false;
        profiles = loaded;
        if (selection == null ||
            !loaded.profiles.any((p) =>
                p.id == selection.$1 && p.modelIds.contains(selection.$2))) {
          selectedModel =
              active == null ? null : (active.id, active.config.model);
        }
      });
      widget.onModelChanged?.call();
    } on AiFailure catch (error) {
      if (mounted) {
        setState(() {
          configurationError = error.message;
          keychainLocked = error is AiKeychainLocked;
        });
      }
    } finally {
      if (mounted) setState(() => loadingModels = false);
    }
  }

  Future<void> openModelSettings() async {
    await showDialog<void>(
        context: context, builder: (_) => AiSettingsDialog(store: store));
    if (mounted) await loadModels();
  }

  Future<void> send() async {
    final question = input.text.trim();
    if (busy ||
        loadingModels ||
        keychainLocked ||
        readingReference ||
        question.isEmpty) {
      return;
    }
    setState(() => busy = true);
    int? replyIndex;
    final partial = StringBuffer();
    try {
      if (configurationError != null) throw AiFailure(configurationError!);
      final selection = selectedModel;
      if (selection == null) {
        throw const AiFailure('尚未配置模型，请在“模型 API 配置”中保存配置。');
      }
      final secureProfiles = await store.loadProfiles(allowInteraction: false);
      if (!mounted) return;
      final profile = secureProfiles.profiles
          .where(
              (p) => p.id == selection.$1 && p.modelIds.contains(selection.$2))
          .firstOrNull;
      if (profile == null) {
        await loadModels(alreadyLoaded: secureProfiles);
        throw const AiFailure('模型配置已更新，请重新选择模型后发送。');
      }
      final config = profile.config.withModel(selection.$2);
      final attachments = {
        for (final name in selected) name: widget.available[name]!,
        ...references,
      };
      setState(() {
        widget.messages.add(AiMessage(true, question, attachments));
        input.clear();
        selected.clear();
        references.clear();
        referenceQuery = null;
      });
      widget.onChatsChanged?.call();
      request = widget.createRequest?.call() ?? AiRequest();
      replyIndex = widget.messages.length;
      setState(() => widget.messages.add(AiMessage(false, '')));
      _followReply();
      final answer =
          await request!.send(config, question, attachments, onText: (delta) {
        if (!mounted) return;
        partial.write(delta);
        setState(() => widget.messages[replyIndex!] =
            AiMessage(false, partial.toString()));
        _followReply();
      });
      if (mounted) widget.messages[replyIndex] = AiMessage(false, answer);
    } on AiKeychainLocked {
      if (mounted) setState(() => keychainLocked = true);
    } catch (e) {
      if (mounted) {
        if (replyIndex == null) {
          widget.messages.add(AiMessage(false, '$e'));
        } else {
          input.text = question;
          references.addAll(widget.messages[replyIndex - 1].attachments);
          widget.messages[replyIndex] = AiMessage(
              false, partial.isEmpty ? '$e' : '${partial.toString()}\n\n$e');
        }
      }
    } finally {
      request = null;
      if (mounted) {
        setState(() => busy = false);
        widget.onChatsChanged?.call();
        _followReply();
      }
    }
  }

  bool scrollPending = false;

  void _followReply() {
    if (scrollPending ||
        (scroll.hasClients && scroll.position.extentAfter > 64)) {
      return;
    }
    scrollPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      scrollPending = false;
      if (mounted && scroll.hasClients) {
        scroll.jumpTo(scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  void dispose() {
    request?.cancel();
    questionFocus.removeListener(updateFocusBorder);
    questionFocus.dispose();
    input.dispose();
    scroll.dispose();
    super.dispose();
  }

  void preview(String name, String content) =>
      setState(() => previewContent = (name, content));

  Widget attachmentPreview((String, String) attachment) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Expanded(
                child: Text(attachment.$1, overflow: TextOverflow.ellipsis)),
            TextButton(
                onPressed: () => setState(() => previewContent = null),
                child: const Text('返回提问')),
          ]),
          Expanded(
              child:
                  SingleChildScrollView(child: SelectableText(attachment.$2))),
        ],
      );

  @override
  Widget build(BuildContext context) => DragTarget<LearningReference>(
      onWillAcceptWithDetails: (_) => !busy && !readingReference,
      onAcceptWithDetails: (details) =>
          attachReference(details.data, removeToken: false),
      builder: (context, candidates, rejected) => Stack(
            fit: StackFit.expand,
            children: [
              buildPanel(context),
              if (candidates.isNotEmpty)
                IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                        border:
                            Border.all(color: PyvisColors.accent, width: 2)),
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: Material(
                        color: PyvisColors.selection,
                        child: const Padding(
                          padding: EdgeInsets.all(8),
                          child: Text('松开以添加引用'),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ));

  final chats = <({
    String title,
    List<AiMessage> messages,
    String draft,
    Map<String, String> attachments
  })>[];

  void switchChat(int? index) {
    if (busy || readingReference) return;
    final previous = index == null ? null : chats.removeAt(index);
    if (widget.messages.isNotEmpty ||
        input.text.isNotEmpty ||
        references.isNotEmpty ||
        selected.isNotEmpty) {
      final title =
          widget.messages.where((m) => m.user).firstOrNull?.text ?? input.text;
      chats.insert(0, (
        title: title.isEmpty ? '未发送的提问' : title,
        messages: List.of(widget.messages),
        draft: input.text,
        attachments: {
          for (final k in selected)
            if (widget.available[k] != null) k: widget.available[k]!,
          ...references
        }
      ));
    }
    setState(() {
      widget.messages
        ..clear()
        ..addAll(previous?.messages ?? []);
      input.text = previous?.draft ?? '';
      references
        ..clear()
        ..addAll(previous?.attachments ?? {});
      selected.clear();
      previewContent = null;
      referenceQuery = null;
      referenceError = null;
    });
    widget.onChatsChanged?.call();
  }

  Widget tool(String label, IconData icon, VoidCallback? action) => IconButton(
      tooltip: label,
      onPressed: action,
      constraints: const BoxConstraints.tightFor(width: 28, height: 30),
      padding: EdgeInsets.zero,
      icon: Icon(icon, size: 17, color: const Color(0xffbfc1c8)));

  Widget modelSelector() {
    final selection = selectedModel!;
    final profile =
        profiles.profiles.firstWhere((profile) => profile.id == selection.$1);
    return PopupMenuButton<(String, String)>(
        tooltip: '选择提问模型',
        enabled: !busy,
        constraints: const BoxConstraints(maxHeight: 240, maxWidth: 320),
        onSelected: (value) {
          setState(() => selectedModel = value);
          widget.onModelChanged?.call();
        },
        itemBuilder: (_) => [
              for (final p in profiles.profiles)
                for (final model in p.modelIds)
                  IdeMenuItem(
                      value: (p.id, model),
                      child: Row(children: [
                        ProviderLogo(p.provider, size: 14),
                        const SizedBox(width: 7),
                        Expanded(
                            child: Text('${p.name} / $model',
                                maxLines: 1, overflow: TextOverflow.ellipsis))
                      ]))
            ],
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          ProviderLogo(profile.provider, size: 14),
          const SizedBox(width: 6),
          Flexible(
              child: Text('${profile.name} / ${selection.$2}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      const TextStyle(color: PyvisColors.muted, fontSize: 13))),
          const Icon(Icons.expand_more, size: 15)
        ]));
  }

  Widget header(bool narrow, {bool editor = false}) => Padding(
      padding: EdgeInsets.only(left: narrow ? 0 : 10, right: 0),
      child: Row(children: [
        Expanded(
            child: PopupMenuButton<int>(
                tooltip: '切换聊天',
                enabled: !busy && !readingReference,
                onSelected: switchChat,
                itemBuilder: (_) => [
                      if (chats.isEmpty)
                        const IdeMenuItem(
                            enabled: false, child: Text('暂无其他聊天')),
                      for (var i = 0; i < chats.length; i++)
                        IdeMenuItem(
                            value: i,
                            child: Text(chats[i].title,
                                maxLines: 1, overflow: TextOverflow.ellipsis))
                    ],
                child: const Row(children: [
                  Icon(Icons.forum_outlined, size: 15),
                  SizedBox(width: 4),
                  Flexible(
                      child: Text('聊天历史记录',
                          maxLines: 1, overflow: TextOverflow.ellipsis)),
                  Icon(Icons.expand_more, size: 15)
                ]))),
        if (narrow)
          tool('新建聊天', Icons.add,
              busy || readingReference ? null : () => switchChat(null))
        else
          Tooltip(
              message: '新建聊天',
              child: TextButton.icon(
                  style: TextButton.styleFrom(
                      foregroundColor: PyvisColors.text,
                      iconColor: PyvisColors.text,
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      textStyle: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w400)),
                  onPressed:
                      busy || readingReference ? null : () => switchChat(null),
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('新建聊天'))),
        if (widget.onTogglePlacement != null)
          tool(widget.inEditor ? '移回侧栏' : '在编辑区打开聊天',
              Icons.view_sidebar_outlined, widget.onTogglePlacement),
        if (!editor)
          tool('模型 API 配置', Icons.more_vert, busy ? null : openModelSettings),
        if (!editor) tool('收起学习提问', Icons.remove, widget.onClose)
      ]));

  Widget emptyChat(bool compact) => Padding(
      padding: EdgeInsets.fromLTRB(12, compact ? 6 : 19, 12, compact ? 6 : 44),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Row(children: [
          Icon(Icons.hub_outlined, size: 15),
          SizedBox(width: 9),
          Text('学习提问',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700))
        ]),
        const Spacer(),
        if (!compact && widget.onTogglePlacement != null) ...[
          const Icon(Icons.view_sidebar_outlined,
              size: 22, color: PyvisColors.accent),
          const SizedBox(height: 18),
          Text(widget.inEditor ? '对话已在编辑区打开' : '在编辑区展开对话',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
          const SizedBox(height: 6),
          const Text('在编辑区阅读长回复，或将对话移回侧栏，边看代码边提问。',
              style: TextStyle(
                  fontSize: 13, height: 1.2, color: PyvisColors.muted)),
          const SizedBox(height: 10),
          InkWell(
              onTap: widget.onTogglePlacement,
              child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (widget.inEditor) ...[
                      const Icon(Icons.arrow_back,
                          size: 14, color: Color(0xff76a5ff)),
                      const SizedBox(width: 4)
                    ],
                    Text(widget.inEditor ? '返回侧栏' : '在编辑区打开聊天',
                        style: const TextStyle(
                            fontSize: 13, color: Color(0xff76a5ff)))
                  ])))
        ]
      ]));
  Widget buildPanel(BuildContext context) => Material(
      borderRadius: BorderRadius.circular(11),
      clipBehavior: Clip.antiAlias,
      color: PyvisColors.background,
      child: LayoutBuilder(builder: (context, constraints) {
        final compact = constraints.maxHeight < 520;
        return Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (widget.inEditor)
                    header(constraints.maxWidth < 420, editor: true)
                  else
                    header(constraints.maxWidth < 310),
                  if (keychainLocked)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: loadingModels
                            ? null
                            : () => loadModels(allowInteraction: true),
                        child: const Text('解锁模型配置'),
                      ),
                    ),
                  Expanded(
                      child: previewContent != null
                          ? attachmentPreview(previewContent!)
                          : widget.messages.isEmpty
                              ? LayoutBuilder(
                                  builder: (_, box) => box.maxHeight < 85
                                      ? const SizedBox.shrink()
                                      : emptyChat(
                                          compact || box.maxHeight < 255))
                              : ListView.builder(
                                  controller: scroll,
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 16),
                                  itemCount: widget.messages.length,
                                  itemBuilder: (_, i) {
                                    final message = widget.messages[i];
                                    return Container(
                                        margin:
                                            const EdgeInsets.only(bottom: 14),
                                        padding: const EdgeInsets.all(14),
                                        decoration: BoxDecoration(
                                            color: message.user
                                                ? PyvisColors.surface
                                                : PyvisColors.canvas,
                                            border: Border.all(
                                                color: PyvisColors.border),
                                            borderRadius:
                                                BorderRadius.circular(6)),
                                        child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.stretch,
                                            children: [
                                              Row(children: [
                                                Icon(
                                                    message.user
                                                        ? Icons.person_outline
                                                        : Icons
                                                            .auto_awesome_outlined,
                                                    size: 14,
                                                    color: message.user
                                                        ? PyvisColors.muted
                                                        : PyvisColors.accent),
                                                const SizedBox(width: 6),
                                                Text(
                                                    message.user ? '你' : '学习助手',
                                                    style: const TextStyle(
                                                        fontSize: 12,
                                                        fontWeight:
                                                            FontWeight.w600)),
                                              ]),
                                              const SizedBox(height: 8),
                                              SelectableText(
                                                  message.text.isEmpty && busy
                                                      ? '等待模型回复…'
                                                      : message.text,
                                                  style: const TextStyle(
                                                      height: 1.6)),
                                              if (message
                                                  .attachments.isNotEmpty)
                                                Padding(
                                                    padding:
                                                        const EdgeInsets.only(
                                                            top: 8),
                                                    child: Wrap(
                                                        spacing: 8,
                                                        children: [
                                                          for (final entry
                                                              in message
                                                                  .attachments
                                                                  .entries)
                                                            ActionChip(
                                                                label: Text(
                                                                    '已附带：${entry.key}'),
                                                                onPressed: () =>
                                                                    preview(
                                                                        entry
                                                                            .key,
                                                                        entry
                                                                            .value)),
                                                        ])),
                                            ]));
                                  })),
                  Container(
                      decoration: BoxDecoration(
                          border: Border.all(
                              color: questionFocus.hasFocus
                                  ? PyvisColors.accent
                                  : const Color(0xff45474f),
                              width: questionFocus.hasFocus ? 1.5 : 1),
                          borderRadius: BorderRadius.circular(6)),
                      padding: const EdgeInsets.all(6),
                      child: Column(children: [
                        ConstrainedBox(
                            constraints: BoxConstraints(
                                maxHeight: constraints.maxHeight * .42),
                            child: SingleChildScrollView(
                                child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                  if (widget.available.isNotEmpty)
                                    Wrap(spacing: 8, runSpacing: 6, children: [
                                      for (final entry
                                          in widget.available.entries)
                                        Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              FilterChip(
                                                  label: Text(entry.key),
                                                  selected: selected
                                                      .contains(entry.key),
                                                  onSelected: busy
                                                      ? null
                                                      : (value) => setState(() {
                                                            if (value) {
                                                              selected.add(
                                                                  entry.key);
                                                            } else {
                                                              selected.remove(
                                                                  entry.key);
                                                            }
                                                          })),
                                              IconButton(
                                                  tooltip: '预览${entry.key}',
                                                  visualDensity:
                                                      VisualDensity.compact,
                                                  onPressed: () => preview(
                                                      entry.key, entry.value),
                                                  icon: const Icon(
                                                      Icons.visibility_outlined,
                                                      size: 16)),
                                            ]),
                                    ]),
                                  if (widget.references != null) ...[
                                    referencePicker(),
                                    if (referenceError != null)
                                      Text(referenceError!),
                                    if (references.isNotEmpty)
                                      Wrap(
                                          spacing: 6,
                                          runSpacing: 4,
                                          children: [
                                            for (final entry
                                                in references.entries)
                                              InputChip(
                                                label: Text(entry.key,
                                                    overflow:
                                                        TextOverflow.ellipsis),
                                                onPressed: () => preview(
                                                    entry.key, entry.value),
                                                onDeleted: busy
                                                    ? null
                                                    : () => setState(() =>
                                                        references
                                                            .remove(entry.key)),
                                                deleteButtonTooltipMessage:
                                                    '移除引用 ${entry.key}',
                                              ),
                                          ]),
                                  ],
                                  const SizedBox(height: 8),
                                  TextField(
                                      controller: input,
                                      focusNode: questionFocus,
                                      onChanged: updateReferenceQuery,
                                      enabled: !busy,
                                      minLines:
                                          widget.inEditor && expandedComposer
                                              ? 6
                                              : compact
                                                  ? 1
                                                  : 3,
                                      maxLines:
                                          widget.inEditor && expandedComposer
                                              ? 9
                                              : compact
                                                  ? 2
                                                  : 4,
                                      decoration: InputDecoration(
                                          suffixIconConstraints:
                                              const BoxConstraints(
                                                  maxWidth: 28, maxHeight: 28),
                                          suffixIcon: widget.inEditor
                                              ? Align(
                                                  widthFactor: 1,
                                                  heightFactor: 1,
                                                  alignment: Alignment.topRight,
                                                  child: tool(
                                                      expandedComposer
                                                          ? '缩小输入框'
                                                          : '展开输入框',
                                                      expandedComposer
                                                          ? Icons
                                                              .close_fullscreen
                                                          : Icons.open_in_full,
                                                      setComposerSize))
                                              : null,
                                          hintText:
                                              '输入您的任务，使用 @ 添加文件或使用 / 输入命令',
                                          hintMaxLines: 1,
                                          hintStyle: TextStyle(
                                              fontSize: 14,
                                              color: Color(0xff76787e)),
                                          border: InputBorder.none,
                                          enabledBorder: InputBorder.none,
                                          focusedBorder: InputBorder.none,
                                          filled: false,
                                          contentPadding: EdgeInsets.symmetric(
                                              horizontal: 3, vertical: 4)))
                                ]))),
                        Row(children: [
                          if (widget.references != null)
                            tool(
                                '引用代码或文件',
                                Icons.add,
                                busy
                                    ? null
                                    : () => setState(() => referenceQuery =
                                        referenceQuery == null ? '' : null)),
                          const Spacer(),
                          tool('粘贴到提问', Icons.content_paste_outlined,
                              busy ? null : pasteQuestion),
                          tool(
                              busy ? '取消' : '发送',
                              busy
                                  ? Icons.stop_circle_outlined
                                  : Icons.send_outlined,
                              busy
                                  ? request?.cancel
                                  : loadingModels ||
                                          keychainLocked ||
                                          readingReference
                                      ? null
                                      : send),
                          const SizedBox(
                              height: 15, child: VerticalDivider(width: 3)),
                          SizedBox(
                              width: 21,
                              height: 30,
                              child: PopupMenuButton<String>(
                                  key: promptMenu,
                                  tooltip: '提问方式',
                                  enabled: !busy,
                                  icon: const Icon(Icons.expand_more, size: 15),
                                  constraints:
                                      const BoxConstraints(maxWidth: 200),
                                  padding: EdgeInsets.zero,
                                  onSelected: (prompt) {
                                    final draft =
                                        input.text.isEmpty || input.text == '/'
                                            ? prompt
                                            : '${input.text}\n$prompt';
                                    input.value = TextEditingValue(
                                        text: draft,
                                        selection: TextSelection.collapsed(
                                            offset: draft.length));
                                    questionFocus.requestFocus();
                                  },
                                  itemBuilder: (_) => const [
                                        IdeMenuItem(
                                            value: '请举一个输入例子，带我走一遍这段代码。',
                                            child: Text('读懂代码')),
                                        IdeMenuItem(
                                            value: '请帮我找出报错原因，并给一个验证步骤。',
                                            child: Text('定位错误')),
                                        IdeMenuItem(
                                            value: '请只给我下一步的提示。',
                                            child: Text('给我提示'))
                                      ]))
                        ])
                      ])),
                  SizedBox(
                      height: 30,
                      child: Row(children: [
                        const SizedBox(width: 8),
                        if (selectedModel == null) ...[
                          const Icon(Icons.hub_outlined, size: 14),
                          const SizedBox(width: 5),
                        ],
                        Expanded(
                            child: selectedModel == null
                                ? Align(
                                    alignment: Alignment.centerLeft,
                                    child: TextButton(
                                        onPressed:
                                            busy ? null : openModelSettings,
                                        child: const Text('选择模型')))
                                : Align(
                                    alignment: Alignment.centerLeft,
                                    child: modelSelector())),
                        if (busy ||
                            selected.isNotEmpty ||
                            references.isNotEmpty)
                          Text(
                              busy
                                  ? '正在生成…'
                                  : '本次附带 ${selected.length + references.length} 项上下文',
                              style: const TextStyle(
                                  color: PyvisColors.muted, fontSize: 11))
                        else
                          InkWell(
                              onTap: busy ? null : openModelSettings,
                              child: const Padding(
                                  padding: EdgeInsets.symmetric(horizontal: 4),
                                  child: Text('设置 ↗',
                                      style: TextStyle(
                                          color: PyvisColors.muted,
                                          fontSize: 13))))
                      ]))
                ]));
      }));
}
