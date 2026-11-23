# 学习问答

入口：设置菜单 → 学习问答；设置 → 模型 API。问题面板可询问选中问题（未选时明确显示首个问题），回放区可询问当前步骤，运行异常区可询问当前错误。

配置 OpenAI 兼容 Chat Completions 服务地址（含 API 前缀，如 https://service.example/v1）、模型名、API Key。点击“保存模型配置”独立保存；“测试连接”用当前表单发送一个普通测试问题，不自动保存。完整配置与密钥以明文 JSON 存入 macOS 应用数据目录下的 PyvisCredentials 目录。目录权限为 0700，凭据文件为 0600。同一系统用户的进程有可能读取。成功读取旧版钥匙串条目时自动迁移。验证本地副本后尝试静默删除旧条目。若系统拒绝删除，旧条目可能仍在系统钥匙串里。公开配置快照不含密钥。

用户每次发送只携带本次问题及主动勾选的上下文；可先预览。上下文是打开问答时的快照。不会自动携带历史、项目源码或其他文件。问答记录仅存于当前应用会话。无工具调用、代码执行或修改能力。默认 45 秒超时，可取消并重新发送；关闭窗口也会取消请求。

HTTP 仅允许回环模拟服务，其他地址要求 HTTPS；禁止 URL 凭据、查询字符串、片段，禁止重定向转发密钥。服务错误正文与底层异常不展示，不记录请求或密钥；回复中的本次 API Key 会被屏蔽。

验证：
- `flutter test test/learning_ai_test.dart`：本地 HttpServer 校验请求协议、附件范围、响应、401/403/404/429/500/重定向、超时、取消、恢复、安全通道保存回读。
- `flutter test test/learning_ai_view_test.dart test/desktop_menus_test.dart`：配置输入屏蔽与回读、未配置恢复、代码选择/指定错误/步骤快照、默认不附带、原菜单回归。
- `flutter analyze`；`flutter build macos`。

真实模型须由用户在应用中提供配置后“测试连接”验证。自动化安全存储测试使用模拟平台通道，不能代替实际机器钥匙串权限验证。

手动模拟服务：运行 `python3 tools/mock_learning_ai.py`，地址填写 `http://127.0.0.1:8769/v1`，模型填 `mock`，Key 使用任意非空测试文字。模型 `slow` 用于取消/超时，`unauthorized` / `unavailable` / `limited` / `malformed` 用于错误恢复。

2026-11-19 验证结果：上述四个测试文件（含 flow_process_test.dart）共 15 项通过，静态分析无问题，通用 macOS Release 构建成功并打开，实际窗口可见“模型 API”设置及未配置状态。真实服务未测试；钥匙串写入/回读自动化使用模拟平台通道，原生窗口确认读取空配置成功。

## 多服务商与模型列表（2026-11-19）

在模型 API 页点击“添加服务商”，选择官方（OpenAI / DeepSeek）、第三方（OpenRouter / 硅基流动）或自定义 OpenAI 兼容接口。每个档案独立保存名称、地址、API Key、模型列表和默认模型。选择档案可继续编辑，草稿切换时保留；点击“保存模型配置”保存当前档案并将它设为问答所用服务。其它服务商配置保持不变。旧版单配置自动迁移成“原有配置”。

服务商条目、已保存服务卡片、问答顶栏与模型切换菜单显示对应的官方标志。图标取自 Lobe Icons（MIT，见 `assets/ide/Lobe-Icons-MIT.txt`），以单色绘制以适配深色界面；各服务商名称与标志归其所有者，仅用于标识所配置的模型服务。问答顶栏的标志也可点击进入“模型 API 配置”。

填好地址和密钥后点击“获取模型列表”，服务返回的模型 ID 直接加入当前档案的模型列表，重复项只保留一个。也可以手动添加服务端模型 ID、移除列表项，或设为默认。保存配置后，模型会出现在学习问答顶部的切换菜单中。每次请求使用所选模型 ID 和该模型所属服务的配置。旧配置里的单个模型自动成为列表中的默认模型。

获取列表不发送问题或代码。获取失败时可重试或手动添加。列表包含服务可见的模型，可用测试连接确认默认模型是否支持文字问答。

接口参考：[OpenAI Models](https://developers.openai.com/api/reference/resources/models/methods/list)、[DeepSeek Models](https://api-docs.deepseek.com/api/list-models/)、[OpenRouter](https://openrouter.ai/developers)、[硅基流动 Models](https://api-docs.siliconflow.cn/docs/api/models-get)。


## 主流协议兼容范围

设置页新增“接口协议”选择：

| 协议 | 问答端点 | 认证 | 模型列表 |
| --- | --- | --- | --- |
| OpenAI Chat Completions | POST /chat/completions | Bearer | /models，data[].id |
| OpenAI Responses | POST /responses | Bearer | /models，data[].id |
| Anthropic Messages | POST /messages | x-api-key + anthropic-version: 2023-06-01 | /models，支持 after_id 分页 |
| Google Gemini | POST /models/{model}:generateContent | x-goog-api-key | /models，支持 pageToken 分页，过滤不支持 generateContent 的模型 |

所有路径追加在配置的 API 版本前缀之后。Responses 使用 store=false，不携带 previous_response_id；所有协议仅包含当前问题和用户主动附带的上下文，不声明工具。回复仅提取最终文字，忽略 thinking/reasoning 数据。模型可手动输入，含第三方提供的模型 ID 或方舟推理接入点 ID，不绑定固定模型版本。

提供商预设：OpenAI、DeepSeek、Anthropic Claude、Google Gemini、阿里云百炼/Qwen、火山方舟/豆包、Moonshot/Kimi、智谱/GLM、Mistral、xAI/Grok、OpenRouter、硅基流动、Groq，以及自定义服务。Qwen/Llama 等开源模型可通过兼容的托管提供商接入。地域、专属业务空间、Coding 套餐可能使用不同地址，按控制台给出的地址配置。服务是否开放 /models 取决于供应商；失败时保留手动输入能力。

本版限文字问答和 API Key 认证，不包含 AWS Bedrock SigV4、Vertex AI OAuth、Azure 部署管理等专用云认证或控制面接口，也不声称已用真实凭据验证全部提供商。

本地模拟：`python3 tools/mock_learning_ai.py`；Chat/Responses 用 `http://127.0.0.1:8769/v1`，Anthropic 用 `http://127.0.0.1:8769/anthropic/v1`，Gemini 用 `http://127.0.0.1:8769/gemini/v1beta`，并选择对应协议、测试模型 mock 和非真实测试 Key。

新增 `test/ai_protocol_test.dart`：四协议认证与序列化、上下文范围、回复提取、密钥隐藏、协议配置回读、Claude/Gemini 分页、Gemini 能力过滤和模型路径校验。与既有配置/请求/界面/菜单测试共 17 项通过。

协议与预设参考：
- [OpenAI Responses](https://developers.openai.com/api/reference/resources/responses/methods/create)
- [Anthropic Messages](https://platform.claude.com/docs/en/api/messages/create) / [模型列表](https://platform.claude.com/docs/en/api/models/list)
- [Gemini generateContent](https://ai.google.dev/api/generate-content) / [模型列表](https://ai.google.dev/api/models)
- [百炼地址](https://help.aliyun.com/zh/model-studio/base-url)、[火山方舟](https://console.volcengine.com/ark/region%3Acn-beijing/docs/base-url-and-authentication)
- [Kimi](https://platform.kimi.com/docs/get-api-key)、[智谱](https://docs.bigmodel.cn/cn/guide/develop/openai/introduction)、[Mistral](https://docs.mistral.ai/resources/migration-guides)、[Groq](https://console.groq.com/docs/openai)、[xAI](https://docs.x.ai/developers/quickstart)

## 窗口与布局

模型设置独立窗口最大 900×780，编辑器设置中的模型页与其他设置页同宽。模型页采用单列配置卡片；“模型提供商”和“自定义模型 API”在同一卡片内作为同级标签。表单独立滚动，状态、测试与保存按钮固定底部；总设置窗口在此页只显示“关闭”，模型配置需使用明确的保存按钮。

问答窗口最大 900×780，按可用空间缩小。标题、上下文选择、输入框和发送按钮与消息列表分离；长回复独立滚动。上下文用可选标签与预览按钮呈现；已发送附件用预览标签展示，避免展开内容挤占消息区。

布局验证覆盖独立窗口 420×480、720×640、1200×850，以及嵌入设置窗口 1000×700、1400×900。检查溢出、固定操作按钮、长回复滚动和上下文勾选。运行 `flutter test test/learning_ai_layout_test.dart`。可追加 `--update-goldens --dart-define=CAPTURE_AI_LAYOUT=true` 在 /tmp 输出布局截图（测试字体仅用于结构检查）。


## 参考图结构调整

设置侧栏仅保留一个“模型”入口。页面上方展示已保存服务卡片（名称、当前模型、当前使用/已配置状态、编辑按钮），下方配置卡片包含两个同级标签：
- 模型提供商：提供商目录、密钥、模型选择；地址、协议与显示名称收纳在“自定义设置”折叠区。
- 自定义模型 API：Provider ID、显示名称、API 地址、API 协议、API 密钥、模型选择依序展开；不放在提供商下拉项中。

Provider ID 以小写字母开头，可含数字和连字符，同一份保存配置中不能重复。它是应用内配置标识，不额外上传到模型服务。旧版配置保持兼容，首次编辑自定义配置时填充默认标识。两个标签分别保留草稿；上方“编辑”自动切到对应标签；“取消”恢复当前已保存内容。仅保存凭据不会显示“已登录”。
