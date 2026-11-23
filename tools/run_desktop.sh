#!/bin/sh
set -eu
task_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
task_developer_dir=${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || true)}
if [ ! -d "$task_developer_dir/Platforms/MacOSX.platform" ]; then
  cat >&2 <<'MESSAGE'
无法启动：当前尚未配置完整版 Xcode。
Command Line Tools 不包含构建 macOS 应用需要的完整工具链。

请先从 App Store 安装 Xcode，安装完成后打开一次，完成初始化。
如果安装在默认位置，再执行：
  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
  sudo xcodebuild -runFirstLaunch
  sudo xcodebuild -license

如果 Xcode 安装在其他位置，请把上面的路径替换为实际路径。
配置完成后，重新执行本脚本。
MESSAGE
  exit 1
fi
task_flutter=${PYVIS_FLUTTER:-flutter}
if ! command -v "$task_flutter" >/dev/null 2>&1; then
  task_flutter="$HOME/.local/share/pyvis-flutter/bin/flutter"
fi
if ! command -v "$task_flutter" >/dev/null 2>&1; then
  echo '无法启动：未找到 Flutter，请安装 Flutter 或通过 PYVIS_FLUTTER 指定其可执行文件。' >&2
  exit 1
fi
python3 "$task_repo_root/tools/prepare_local_completion.py"
cd "$task_repo_root/client"
exec "$task_flutter" run -d macos
