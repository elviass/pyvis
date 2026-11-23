# PyCharm 开源实现对照

查看日期：2026-11-17。上游：[JetBrains/intellij-community](https://github.com/JetBrains/intellij-community)。固定源码提交：`95e604c033cd5cb6a267bf816c4d9c430b1b4c0e`。本页记录源码阅读结果；不表示项目已接入或移植 IntelliJ 引擎。

JetBrains 已将 PyCharm 合并为统一产品，开源部分仍维护于该仓库，参见[官方说明](https://www.jetbrains.com/help/pycharm/unified-pycharm.html)。

| 功能 | 源码入口 | 已确认的职责 |
| --- | --- | --- |
| 自动补全触发 | [CompletionAutoPopupHandler.java](https://github.com/JetBrains/intellij-community/blob/95e604c033cd5cb6a267bf816c4d9c430b1b4c0e/platform/lang-impl/src/com/intellij/codeInsight/editorActions/CompletionAutoPopupHandler.java) | 输入状态与活动候选列表协调，交给 AutoPopupController 调度。 |
| Python 候选权重 | [PythonCompletionWeigher.java](https://github.com/JetBrains/intellij-community/blob/95e604c033cd5cb6a267bf816c4d9c430b1b4c0e/python/python-psi-impl/src/com/jetbrains/python/codeInsight/completion/PythonCompletionWeigher.java) | 结合当前文件、限定引用、关键字及字典键等信息评分；不是单纯字母排序。 |
| 函数接受与光标 | [PyFunctionInsertHandler.java](https://github.com/JetBrains/intellij-community/blob/95e604c033cd5cb6a267bf816c4d9c430b1b4c0e/python/python-psi-impl/src/com/jetbrains/python/codeInsight/completion/PyFunctionInsertHandler.java) | 函数插入委托括号处理器；根据真实参数决定光标位置并请求参数提示。 |
| 接受候选动作 | [ChooseItemAction.java](https://github.com/JetBrains/intellij-community/blob/95e604c033cd5cb6a267bf816c4d9c430b1b4c0e/platform/lang-impl/src/com/intellij/codeInsight/lookup/impl/actions/ChooseItemAction.java) | IntelliJ 平台统一处理候选接受动作。 |
| Python 参数信息 | [PyParameterInfoHandler.java](https://github.com/JetBrains/intellij-community/blob/95e604c033cd5cb6a267bf816c4d9c430b1b4c0e/python/python-code-insight/src/com/jetbrains/python/PyParameterInfoHandler.java) | 通过 Python 调用表达式和参数映射建立提示。 |
| 参数提示避障 | [ParameterInfoController.java](https://github.com/JetBrains/intellij-community/blob/95e604c033cd5cb6a267bf816c4d9c430b1b4c0e/platform/lang-impl/src/com/intellij/codeInsight/hint/ParameterInfoController.java) | setupLookupListener 跟踪候选列表变化；chooseBestHintPosition 比较上下位置和列表实际边界，必要时放在列表外侧。 |
| 候选列表布局 | [LookupUi.java](https://github.com/JetBrains/intellij-community/blob/95e604c033cd5cb6a267bf816c4d9c430b1b4c0e/platform/lang-impl/src/com/intellij/codeInsight/lookup/impl/LookupUi.java) | 平台管理候选窗口布局与尺寸。 |
| 语法合法性 | [PySyntaxAnnotator.java](https://github.com/JetBrains/intellij-community/blob/95e604c033cd5cb6a267bf816c4d9c430b1b4c0e/python/python-psi-impl/src/com/jetbrains/python/validation/PySyntaxAnnotator.java) | 分派给赋值目标、参数、return/yield、break/continue、import、async/await、模式匹配和 try/except 等访问器。 |
| 名称及属性解析 | [PyUnresolvedReferencesInspection.kt](https://github.com/JetBrains/intellij-community/blob/95e604c033cd5cb6a267bf816c4d9c430b1b4c0e/python/src/com/jetbrains/python/inspections/unresolvedReference/PyUnresolvedReferencesInspection.kt) | 检查委托 unresolved-reference visitor，并使用检查会话中的类型上下文。 |
| 函数参数匹配 | [PyArgumentListInspection.java](https://github.com/JetBrains/intellij-community/blob/95e604c033cd5cb6a267bf816c4d9c430b1b4c0e/python/python-psi-impl/src/com/jetbrains/python/inspections/PyArgumentListInspection.java) | 映射实参与形参，报告缺少参数、额外参数等问题。 |
| 类型检查 | [PyTypeCheckerInspection.kt](https://github.com/JetBrains/intellij-community/blob/95e604c033cd5cb6a267bf816c4d9c430b1b4c0e/python/python-psi-impl/src/com/jetbrains/python/inspections/PyTypeCheckerInspection.kt) | 基于 PSI 与类型上下文进行检查；依赖 Python 类型系统及解析基础设施。 |
| 后台检查调度 | [DaemonCodeAnalyzerImpl.java](https://github.com/JetBrains/intellij-community/blob/95e604c033cd5cb6a267bf816c4d9c430b1b4c0e/platform/lang-impl/src/com/intellij/codeInsight/daemon/impl/DaemonCodeAnalyzerImpl.java) | 管理检查任务、编辑后延迟、取消和重启。 |
| 诊断统一表示 | [HighlightInfo.java](https://github.com/JetBrains/intellij-community/blob/95e604c033cd5cb6a267bf816c4d9c430b1b4c0e/platform/analysis-impl/src/com/intellij/codeInsight/daemon/impl/HighlightInfo.java) | 保存源码范围、严重级别、说明和悬浮描述等信息。 |
| 右侧检查条 | [ErrorStripeUpdateManager.kt](https://github.com/JetBrains/intellij-community/blob/95e604c033cd5cb6a267bf816c4d9c430b1b4c0e/platform/lang-impl/src/com/intellij/codeInsight/daemon/impl/ErrorStripeUpdateManager.kt) | 连接编辑器 markup、提示渲染器与检查条刷新。 |
| 检查状态汇总 | [TrafficLightRenderer.kt](https://github.com/JetBrains/intellij-community/blob/95e604c033cd5cb6a267bf816c4d9c430b1b4c0e/platform/lang-impl/src/com/intellij/codeInsight/daemon/impl/TrafficLightRenderer.kt) | 维护检查状态与严重级别的显示。 |

## 当前项目与上游的差别

当前项目使用 Flutter/re_editor，分析采用 CPython compile、AST/symtable、离线 Jedi/Parso，以及随软件打包的 Ruff 0.17.5 与 ty 0.0.104。当前已支持语法、缩进、保守的未定义名称、未使用导入/变量、部分风格、可推断的类型、参数及属性检查。它没有 IntelliJ 的 PSI、项目索引和完整 Python 检查体系，不能将规则覆盖或结果等同于 PyCharm。

多行灰色预览目前是本地上下文模板。不能把普通候选补全、模板展开、整行/多行预测补全混为一个引擎，也不能因为开源仓库存在就声称用户截图中的所有预测功能均可直接复用。

## 对本项目的实现约束

以下约束已用于本轮实现，但不表示完整移植上游引擎：

1. 分析、候选调度、接受操作、弹窗布局分别管理；文本/光标/输入法状态必须对应同一文档版本。
2. 检查规则独立运行，统一输出文件、版本、源码范围、严重级别、原因和修复引导；波浪线、右侧标记和问题列表共享同一批诊断。
3. 实时检查允许取消和淘汰过期结果；运行前 CPython 语法检查继续作为独立保障，不能代替静态语义检查。
4. 参数提示与候选列表共享真实几何信息，跟随光标、滚动和窗口变化；不能以固定 top=0 代替定位。
5. 上游 Java/Kotlin 实现依赖 IntelliJ 平台，不能直接塞入 Flutter 控件。应逐项移植行为或评估单独的分析服务；本次不改技术栈、不声称引擎已接入。

本轮按上述职责重构了编辑器交互、诊断显示和分析调度。macOS 以本机 PyCharm 2026.2.3 深色界面为参照，Windows 使用其默认键位映射；Windows 原生外观和交互仍需实机逐项对照。源码快照留在本机 `/tmp/pyvis-jetbrains-reference`，没有将上游代码并入应用。各下载文件头声明的许可证及仓库 LICENSE 应在实际引入代码时保留并核对。

## 灰色续写与诊断样式对照（2026-11-17）

实际读取本机颜色设置，主题为 Islands Dark，而不是仅按“深色”推测 Darcula。对照安装包 `intellij.platform.ide.impl.jar` 内的 `themes/islands/IslandSchemeDark.xml` 及父方案：错误波浪线 #FA6675 / 检查条 #D64D5B，警告 #F2C55C / #C29E4A，Typo #7EC482，未使用代码前景 #6F737A；弱警告继承 INFO_ATTRIBUTES #AEAE80 / #756D56。Typo 和未使用代码不虚构同色检查条。波形参照 [WavePainter2D](https://github.com/JetBrains/intellij-community/blob/95e604c033cd5cb6a267bf816c4d9c430b1b4c0e/platform/util/ui/src/com/intellij/util/ui/WavePainter2D.java)：幅度 1 像素、周期 4、线宽 .7、连续横向相位，裁切到实际源码范围。未使用代码采用淡化字形，不再统一画灰色波浪线。重叠范围优先显示更高严重度，F2 优先最高级别。

官方依据：[严重级别及可配置样式](https://www.jetbrains.com/help/pycharm/configuring-inspection-severities.html)、[检查导航](https://www.jetbrains.com/help/pycharm/running-inspections.html)、[拼写](https://www.jetbrains.com/help/pycharm/spellchecking.html)。这些不是运行阻断等级；类型/参数检查为警告，语法错误仍阻断运行。

绿色提示按词法范围检查英文注释、字符串和标识符词段。采用 pyspellchecker 0.9.1 的 MIT 英文频率数据及本项目检查器，不是 Grazie 词库；专有词、形态变化和部分语言的触发结果仍可能不同。单词加入用户词典会重新检查，不修改代码；标识符不提供会破坏引用的局部替换。支持 `# noinspection` 对后续语句/套件的相应检查抑制，语法错误不能被抑制。

灰色续写使用独立的快速上下文结果，不依赖完整诊断结束；仅当前输入行继续键入时可复用其前面的未变化上下文。新增逗号空格、用户输入的循环变量、已有代码体（只补头部）、注解参数、可静态推断的函数返回容器、计数循环、布尔条件及同文件已写调用的续写。Tab 接受、一次撤销、Esc/IME/字符串保护仍生效。它仍是确定性的上下文续写，不等同于 PyCharm Full Line 的预测模型。


## 本地模型续写

macOS 构建内置约 420 MB 的 Qwen2.5-Coder-0.5B Q5_K_M 基础模型和 llama.cpp b12470。应用启动后在后台预热模型，使用光标附近的代码做本地 FIM 推理，并在流式生成中尽早显示第一段通过校验的整行或多行续写。

候选列表由 Jedi 的作用域/类型语义结果提供，Enter 插入、Tab 替换右侧标识符；存在灰色模型建议时 Tab 接受整段，支持单次撤销。模型结果先检查语法和可见变量，继续输入、切换光标/文件或进入输入法组合时丢弃旧结果。右上角续写图标显示本地模型状态。模型建议需主动接受，不自动修改学习代码。

源码构建先运行 `python3 tools/prepare_local_completion.py`（首次联网下载并验证 SHA-256）；`tools/run_desktop.sh` 已包含此准备步骤。模型/二进制缓存不提交版本控制；下载地址、版本、校验值见 `tools/local_completion_manifest.json`。模型为 Apache-2.0，llama.cpp 为 MIT，许可证随软件提供。

这不是 JetBrains 专有 Full Line 模型或 IntelliJ PSI 引擎，预测质量和检查范围仍可能不同。JetBrains 本机 Python 模型配置为 LlamaForCausalLM / python-v2 / 0.1.198-native-llama-bundle，1536 tokens；仅作研究对照，没有复制其权重。当前新增推理运行环境完成 macOS arm64 打包；macOS Intel 有固定下载记录但未实机验证，Windows 和移动端尚未打包本地模型。

官方对照：[Full Line](https://www.jetbrains.com/help/pycharm/full-line-code-completion.html)、[基本补全](https://www.jetbrains.com/help/pycharm/auto-completing-code.html)、[模型与许可](https://huggingface.co/Qwen/Qwen2.5-Coder-0.5B)、[量化模型](https://huggingface.co/bartowski/Qwen2.5-Coder-0.5B-GGUF)。
