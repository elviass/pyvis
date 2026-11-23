import 'package:material_ui/material_ui.dart';
import 'execution_flow.dart';

class ExecutionFlowView extends StatelessWidget {
  final ExecutionFlow flow;
  const ExecutionFlowView({super.key, required this.flow});
  static const muted = Color(0xff9b9fa8), blue = Color(0xffa5c7ff);
  Widget place(FlowPlace? place, String role,
          {bool active = false, String? fallback}) =>
      Container(
          width: 170,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
              color: active ? const Color(0xff293b57) : const Color(0xff24272e),
              border:
                  Border.all(color: active ? blue : const Color(0xff424650)),
              borderRadius: BorderRadius.circular(9)),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(role, style: const TextStyle(color: muted, fontSize: 11)),
            const SizedBox(height: 4),
            Text(place?.label ?? fallback ?? '',
                style: TextStyle(
                    color: active ? blue : const Color(0xffdee2ea),
                    fontSize: 15,
                    fontWeight: active ? FontWeight.w600 : FontWeight.normal)),
            if (place != null && place.code.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(place.code,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontFamily: 'JetBrains Mono', fontSize: 11, color: muted))
            ]
          ]));
  Widget link(String label) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(label, style: const TextStyle(fontSize: 10, color: blue)),
        const Icon(Icons.arrow_forward_rounded, size: 25, color: blue)
      ]));
  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('程序走到哪里', style: TextStyle(color: muted, fontSize: 12)),
        const SizedBox(height: 8),
        SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child:
                Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
              place(flow.previous, '刚才', fallback: '开始'),
              link(''),
              place(flow.current, '正在演示', active: true),
              link(flow.transition),
              place(flow.next, '接着', fallback: flow.transition)
            ])),
        const SizedBox(height: 8)
      ]);
}
