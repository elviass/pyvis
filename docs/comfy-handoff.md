# ComfyUI 画布改造接续记录

用户要求：图形画布采用 ComfyUI 的构架和渲染，可读性也参考 ComfyUI；执行语义参考 UE 蓝图。每个原子节点仍可独立拖动，代码块可折叠。每次完成后打开程序。语气严谨、内容易理解。

## 已保存的改动

- 应用入口从旧 Flutter BlueprintPanel 切换到 ComfyBlueprintPanel。
- 本地打包 Comfy-Org 发布的 @comfyorg/litegraph 0.17.2 UMD、CSS、MIT 许可证。是经典 Canvas2D 画布，不是新版 Nodes 2.0。
- assets/graph/model.js 把真实 Python AST 节点、端口、执行和数据边、分组转换为 LiteGraph。所有原子节点保留；多前驱汇合不丢边。
- assets/graph/canvas.js 使用真实 LGraphCanvas 渲染，支持拖动、框选、缩放、分组、节点折叠、代码块展开、来源定位、原生转接点和位置保留。默认主流程折叠，子流程可进入/返回。
- assets/graph/routing.js 给遮挡和回跳路径计算避障转接点；ComfyUI 引擎负责绘制曲线。
- Retina 处理：物理画布尺寸乘 DPR，CSS viewport 同步，前景/背景上下文统一比例。分组 resizeTo 前先更新节点实际边界。
- macOS 在 MainFlutterWindow.swift 注册明确的 WKWebView 平台视图和消息通道；其他宿主使用 flutter_inappwebview 6.2.0-beta.3。macOS SwiftPM 构建已成功，去掉了自动遗留的 Podfile/Pods xcconfig include。
- JS 消息的行号按 num.toInt() 处理，避免 WebKit 数字到 Dart double 造成异常。
- 整个离线 HTML 从 Flutter assets 合成，不依赖 CDN 或 ComfyUI 服务；不执行用户 JavaScript/Python。

## 已验证

- Python 53 项通过：/tmp/pyvis-comfy-python.log。
- Flutter 全量 59 项通过：/tmp/pyvis-comfy-all-tests.log。随后 3 项新面板回归重新通过：/tmp/pyvis-comfy-final-panel.log。
- 实际 LiteGraph 图适配测试 8 项通过：node --test tests/test_comfy_model.cjs；/tmp/pyvis-comfy-model.log。
- flutter analyze 无问题：/tmp/pyvis-comfy-analyze.log。
- macOS Debug 最终构建成功：/tmp/pyvis-comfy-build.log。
- 浏览器中的真实 Canvas 已检查，Retina 端口、分组和连线正常，无新 JS 错误。

## 尚未完成：原生窗口最终验收

WKWebView 原生显示在 CUA 截图中不稳定，曾看到真实 Comfy 节点，但部分重启显示白色/空白区域，即使消息已报告渲染 5 个节点。不能把渲染事件或构建成功当成视觉验收通过。需要继续确认 macOS 平台视图布局/合成与窗口激活问题，并实测展开、拖动、源码定位、子流程导航。Windows/Android/iOS 新画布未实机验收；移动 Python 运行桥仍未实现。

最近一次构建恢复了 WKWebView drawsBackground=false，并保留 AutoLayout 和 frame/bounds 尺寸同步。不要继续无依据修改渲染逻辑；先观察当前原生窗口和日志。

程序：client/build/macos/Build/Products/Debug/pyvis_editor.app。
Flutter：/Users/elvia/.local/share/pyvis-flutter/bin/flutter。
构建命令：flutter build macos --debug --dart-define=PYVIS_PYTHON=/Library/Frameworks/Python.framework/Versions/3.14/bin/python3。

## Codex 对话错误

用户两次指出 Codex 对话侧出现 {"detail":"Bad Request"}。已只读检查本地 logs_2.sqlite，在本聊天对应的模型 POST /responses 请求中确认 2026-11-16 14:39:44（Asia/Shanghai）HTTP 400；服务端没有具体字段解释。请求编号：338213f3-3ac6-411d-a0be-f70a0580f143。当前 provider 为 openai，无需修改项目 Python 或 Xcode 配置来处理这个错误。不能断言为网络故障或上下文过长。

接续时保持已有代码，先解决原生验收；不要重做已通过的 AST 语义。用户学习工作区中的 1.py、123.py、1234.py 不得改动。


## 最后一次窗口观察

已重新连接真实应用窗口，在 1.py 将用户选中的“完整图”关闭，确认当前层级显示 3 个折叠节点、100% 比例，原生文字和执行连线实际可见。应用保持打开。此前白屏记录仍保留作为待复查问题；原子展开拖动、子流程及反复切换的最终实机验收尚未完成，不宣称全部完成。


## 继续工作后的进度

已新增 focusNode/readableCamera，展开后定位真实成员，折叠后定位对应块；小型折叠子流程的上方分支留出工具栏间距，缩放最低 85%。路由刷新标志改为合并保留，节点拖动后先更新实际边界。当前 10 项 JS/真实 LiteGraph 适配测试通过，JS 语法检查通过，macOS Debug 构建成功并已重新打开。

本次原生验证：展开计算 total 后，读取 price/count 节点进入可读视口；点击与展开同步 L3/L4；折叠本层、进入判断子流程及 True/False 出口正常。自动化 drag 未产生可确认的节点位移，不能宣称原生拖动已验收。最后一次进一步操作遇到桌面工具超时，重新连接后确认程序仍打开。最新分支顶部留白修改有回归测试，最终原生显示尚待继续复核。用户学习文件没有改动。


## 底部演示运行修正（2026-11-16）

用户明确指向底部“图形化执行”的字典大文本问题，不是静态 ComfyUI 流程图。已新增 runtime_value_view.dart、object_binding_view.dart、process_diagram.dart，接入 line_theater.dart：一个容器实体、变量引用、键值/嵌套字段、有限预览和快照树；一般计算保留本行过程节点并隐藏未来值。main.dart 的 demo 游标停在请求后的第一个学习步骤，不覆盖函数返回/缓冲中的调用方赋值。engine.py 归并多行表达式物理续行，保留循环重复检查；for 记录目标及循环体范围，正确区分重复元素与结束。

56 项 Python、67 项客户端、10 项 LiteGraph 回归通过；最终减少重复说明后 16 项专项与 1400×784 四商品首屏边界回归通过；analyze 无问题，macOS Debug 最终构建并已打开。原生已看到 123444.py 的 L5 单次完整赋值、一个 inventory 引用一个字典及真实商品字段。最后原生工具出现状态延迟/窗口定位失败，不要把最终首屏断言说成原生四商品全屏实测；该断言来自真实 Python 的组件工作流回归。静态 ComfyUI 画布本轮没有改动，原生小节点拖动验证的旧待办仍保留。

## 2026-11-17 编辑器代码辅助修复

当前客户端 re_editor 改为 vendor/re_editor 本地依赖（上游 0.10.0 MIT），修改点见 PYVIS_PATCHES.md。核心改动包括异步补全控制器、排版完成后重试、原位更新候选、Tab 右侧替换、IME 让行、呈现层诊断/灰色多行预览。Jedi 0.19.2/Parso 0.8.5 wheels 离线打包到 runtime/pyvis_runtime/vendor；分析禁用不安全扩展与自动导入，显式加入项目路径，测试确认不会执行本地导入模块。

多行预览是上下文模板，不是通用 AI 补全。参数提示避开当前行、视口边界和候选列表；没有空间时收起。查找栏不再覆盖整个编辑区。83 项客户端/64 项 Python 全量通过，analyze 无问题，最终 macOS 构建成功。真实窗口自动化仍可能延迟，参数提示位置已有完整编辑器几何回归，但不能称为全平台或全部原生输入验收。静态图画布未修改，其此前原子节点拖动待办仍保留。


## 2026-11-17 原生平台编辑器对照

macOS 参照本机 PyCharm 2026.2.3 深色界面和默认键位；Windows 使用 Windows 默认键位并以平台变体验证。新增独立文档标签页（保留未保存内容、光标、折叠和撤销）、Python 缩进折叠/参考线、括号匹配、代码缩略图、右键操作、字体/换行/检查设置、紧凑检查状态和问题导航。修复 macOS Cmd+Backspace 被默认删除到行首动作抢占的问题。Enter 使用四空格 Python 缩进，补全支持 f-string 表达式、字典键、空参数函数光标，以及已输入关键字的优先排序。

离线 Ruff 0.17.5 / ty 0.0.104 与原 CPython/Jedi 分工；后台检查纳入本地依赖包结构和已打开文档的未保存内容，检查不会执行学习代码。支持可推断的类型赋值、调用参数、属性、未使用代码和部分风格诊断。显式格式化、优化导入和安全修复可撤销；诊断过期则拒绝套用旧修复。运行前继续仅用 CPython 编译错误阻断启动。

真实 macOS 首轮发现缓存中的原始 Mach-O 工具被沙盒拒绝启动。现由 Xcode 构建阶段校验官方 wheel、提取当前构建架构、放入 Contents/Helpers，并以父应用身份签名，仅带 app-sandbox / inherit 两项沙盒权限；保留主应用沙盒。方法参照 [Apple helper tool 文档](https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app)。运行进程使用这些内置工具。随后真实窗口确认检查不可用错误消失，独立临时 .py 文件显示两个错误、一个未使用导入警告和对应范围波浪线。

还修复 macOS 自定义扩展过滤拒绝有效 .py 文件的问题：原生选择器选择后由应用校验扩展名。选择单文件没有目录读取权限时显示已打开文件，不保留旧项目的错乱树；深层目录缩进限宽、名称省略。验证 93 项 Flutter 全量、72 项 Python 全量通过，Flutter analyze 无问题，macOS Debug 构建成功。新增回归覆盖 Mac/Windows 实际编辑器键位、缩进撤销、折叠定位、补全上下文、格式化/安全修复撤销、类型诊断导航、文件选择校验和深目录布局。

仍不等同于完整 PyCharm：未接入 IntelliJ PSI/索引或全套检查/重构；文档弹窗、设置等仍是项目自己的实现。灰色多行预览是本地模板；Jedi 对导入文件的补全仍主要读取已保存文件（检查使用未保存依赖快照）。Windows 仅完成键位平台变体测试，原生窗口尚未实机验收。静态 ComfyUI 图本轮未修改，此前原生小节点拖动的验收待办仍保留。

本机 macOS 构建目录 `client/build` 已改为指向 `~/Library/Caches/Pyvis/desktop-build-20261117` 的本地符号链接，避免 Documents 的文件同步元数据污染代码签名。该链接已加入忽略规则，不提交机器绝对路径。源码位置不变。`tools/bundle_editor_tools.py` 在 Flutter embed 后签名 Helpers，并将其声明为构建输出；主应用由 Xcode 最终签名。

最终干净构建还暴露并修复了 macOS 启动回调问题：`FlutterAppDelegate` 没有实现可选的 `applicationDidFinishLaunching:`，原先直接调用 super 会抛出 unrecognized selector，留下无窗口进程。已移除该调用，保留窗口置前逻辑；重新构建成功，主应用和两个 Helpers 的 `codesign --verify --strict` 均通过。修复后的最终窗口仍待桌面连接恢复后确认：CUA 当前对新版、PyCharm 和活动监视器均返回 cgWindowNotFound，已询问用户是否锁屏。请勿将早先的原生诊断截图描述为最终启动修复的窗口验收。旧无窗口进程 PID 10538 属于修复前版本，需要正常退出后重新打开最终构建。

2026-11-17 16:15（Asia/Shanghai）用户解锁后继续验收：旧进程 10538 已正常退出，重新启动最终构建，新进程 13304 的启动时间晚于最终 debug dylib 构建时间。已通过原生窗口截图和无障碍状态确认编辑器完整显示，右上角检查状态为当前源码的 0 个错误、2 个警告，未出现分析工具不可用或启动异常。程序保持打开。此前“最终窗口待确认”及旧进程退出待办至此解决；此观察不代表 Windows 原生或所有编辑交互均已验收。


## 2026-11-17 补全启动、检查样式与缩略图

修复原生打包初始化将空 .DS_Store 作为资源加载导致运行目录未就绪、语义补全失败的问题；运行资源过滤隐藏元数据和缓存，已有学习文件不覆盖。新增真实打包资源/CPython 补全回归。跳转行对话框由自身状态持有控制器，避免关闭动画期间提前释放导致框架断言。Mac 原生文件/代码菜单接入现有操作。

灰色续写改用独立快速上下文，覆盖字典遍历、用户变量名、注解容器、已有代码体及同文件调用续写；它仍是确定性续写，并非 PyCharm Full Line 模型。检查颜色、波形和淡化参照本机 Islands Dark；新增离线英文拼写与用户词典，但检查引擎和词库仍非 IntelliJ/Grazie，触发范围不完全相同。

代码缩略图复用编辑区语法配色，支持多行字符串、视口和源码跳转。按用户最后一次纠正：只保留缩略图右侧的总览滚动条，关闭代码区与缩略图之间的内部竖向滚动条；横向滚动保留。问题标记仍可点击。

验证：本轮完整 Flutter 串行测试 103 项通过；并行首次有两个使用固定等待的既有测试失败，串行全量通过。最后纠正滚动条位置后，5 项缩略图/检查专项通过、analyze 无问题、macOS Debug 构建和严格签名校验通过。最终原生显示观察另记；灰色续写与 Tab 的最终原生键盘验收尚未确认，组件工作流回归已通过。Windows 原生未验收。

最终原生窗口已确认：123444.py 长文件只在彩色缩略图右侧显示滚动条，代码区与缩略图之间没有重复滚动条；程序保持打开。此次未修改学习源码。


## 2026-11-17 本地模型续写与原生补全验收

按用户最新指令把补全拆为语义候选（Jedi）和真实本地 FIM 续写（Qwen2.5-Coder-1.5B Q8_0 / llama.cpp b12470）。推理只经 127.0.0.1、随机端口与每进程密钥；离线模式，源码不发往云端 API。首次源码构建需 tools/prepare_local_completion.py；模型和运行时固定地址/校验值在 tools/local_completion_manifest.json，约 1.65 GB 模型随 macOS app 打包。没有复制 JetBrains 专有权重。当前 arm64 已验证，Intel 有下载配置未实机验证，Windows/移动端新增模型未打包。

生产 app 检测到模型后关闭旧模板灰色预览，改为模型前后文预测。模型结果先作语法和作用域可见变量检查；输入、光标/文件变化、输入法组合、Esc 与选择改变会取消或丢弃过期结果。Tab 接受、一次撤销。保留语义候选 Enter 插入与 Tab 替换。

修复 re_editor 空的 macOS performSelector：原生编辑指令进入同一套编辑/补全 Actions。新增回归先复现 native selector Tab 无效，再确认修复。进一步实机发现 XIB 原生 Edit → Undo 没有连接代码文档撤销历史：新增“编辑”原生菜单和焦点分派，更新菜单可用状态，编辑器与转到行 TextField 各用自己的动作；原生 Cmd+A/Cmd+Z 不再被无效默认菜单截获。

实机首次模型启动因给无 Team ID 的 Debug helper 单独添加 hardened-runtime 导致 DYLD 拒绝同包 dylib。现 helper 跟随父应用的签名模式：ad-hoc Debug 与现有父程序一致，分发身份保留 hardened-runtime；主应用沙盒和 inherit 保留，没有添加禁用库验证权限。随后真实窗口确认本地模型就绪、灰色两行循环建议，点击代码区后 Tab 接受，语法颜色和源码光标移动正确。模型子进程退出回收另加 stop，并在确认退出后等待结束。

验证：107 项 Flutter 全量串行、82 项 Python 全量通过；最后进程回收修改后 13 项本地推理/编辑专项通过；flutter analyze 无问题；macOS Debug 构建成功。真实模型 Python 探针：循环约 0.54 秒、返回值约 0.09 秒（本机单次观察，不作为固定性能承诺）。原生最终撤销、候选列表及退出回收继续在窗口验收，结论另记。

最终构建原生对话框已验证 Cmd+A：原有行列值被完整选中，输入 3:4 正确替换，没有拼接旧值。模型服务在最终包中启动并显示就绪；此前无 Team ID 的 Debug DYLD 问题已解决。
