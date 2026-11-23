import 'package:material_ui/material_ui.dart';

import 'ide_chrome.dart';
import 'pyvis_theme.dart';

class QuickDocumentation extends StatelessWidget {
  final List<Map> documents;

  const QuickDocumentation({super.key, required this.documents});

  @override
  Widget build(BuildContext context) => Dialog(
        insetPadding: const EdgeInsets.all(24),
        backgroundColor: PyvisColors.background,
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620, maxHeight: 460),
          child: SizedBox(
            width: 620,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ColoredBox(
                  color: PyvisColors.surface,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: SizedBox(
                      height: 38,
                      child: Row(children: [
                        Expanded(
                          child: Text(
                            '快速文档',
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                        ),
                        IdeButton(
                          icon: 'close',
                          tooltip: '关闭文档',
                          extent: 26,
                          onTap: () => Navigator.pop(context),
                        ),
                      ]),
                    ),
                  ),
                ),
                const Divider(),
                Flexible(
                  child: SelectionArea(
                    child: SingleChildScrollView(
                      primary: false,
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final (index, document)
                              in documents.indexed) ...[
                            if (index > 0) const Divider(height: 28),
                            _DocumentationEntry(document),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
}

class _DocumentationEntry extends StatelessWidget {
  final Map document;

  const _DocumentationEntry(this.document);

  @override
  Widget build(BuildContext context) {
    final name = document['name']?.toString() ?? '';
    final signatures =
        (document['signatures'] as List? ?? []).whereType<String>();
    final body =
        (document['body'] ?? document['text'] ?? '').toString().trimRight();
    final declaration = signatures.isEmpty
        ? document['description']?.toString() ?? ''
        : signatures.join('\n');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (name.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(name,
                style:
                    const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          ),
        if (declaration.isNotEmpty)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: PyvisColors.surface,
              border: Border.all(color: PyvisColors.border),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(declaration,
                style: const TextStyle(
                  fontFamily: 'JetBrains Mono',
                  fontSize: 12,
                  height: 1.5,
                  color: PyvisColors.text,
                )),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(
            body.isEmpty ? '此符号未提供文档说明。' : body,
            style: TextStyle(
              fontSize: 13,
              height: 1.5,
              color: body.isEmpty ? PyvisColors.muted : PyvisColors.text,
            ),
          ),
        ),
      ],
    );
  }
}
