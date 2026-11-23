import 'package:flutter_svg/flutter_svg.dart';
import 'package:material_ui/material_ui.dart';
import 'pyvis_theme.dart';

/// Brand marks for the model providers configured in 模型 API 配置.
///
/// The SVG files come from Lobe Icons (MIT); see
/// assets/ide/Lobe-Icons-MIT.txt. They are drawn as monochrome glyphs so the
/// official outline stays legible on the dark editor surface.
const providerLogos = <String, String>{
  'openai': 'assets/ide/brand/openai.svg',
  'deepseek': 'assets/ide/brand/deepseek.svg',
  'anthropic': 'assets/ide/brand/claude.svg',
  'gemini': 'assets/ide/brand/gemini.svg',
  'qwen': 'assets/ide/brand/qwen.svg',
  'kimi': 'assets/ide/brand/kimi.svg',
  'glm': 'assets/ide/brand/zhipu.svg',
  'mistral': 'assets/ide/brand/mistral.svg',
  'groq': 'assets/ide/brand/groq.svg',
  'xai': 'assets/ide/brand/xai.svg',
  'openrouter': 'assets/ide/brand/openrouter.svg',
  'siliconflow': 'assets/ide/brand/siliconcloud.svg',
  'ark': 'assets/ide/brand/doubao.svg',
  'custom': 'assets/ide/brand/model.svg',
};

String providerLogoAsset(String provider) =>
    providerLogos[provider] ?? providerLogos['custom']!;

class ProviderLogo extends StatelessWidget {
  final String provider;
  final double size;
  final Color color;
  const ProviderLogo(this.provider,
      {super.key, this.size = 18, this.color = PyvisColors.text});

  @override
  Widget build(BuildContext context) => SvgPicture.asset(
        providerLogoAsset(provider),
        width: size,
        height: size,
        colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
        semanticsLabel: provider,
      );
}
