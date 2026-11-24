# 执行与回放协议 v1

Flutter 客户端通过 RuntimeAdapter 启动 Python worker，stdin 接收逐行 JSON 命令，stdout 输出逐行 JSON 事件；用户的 print 输出被转为 output 事件，不能污染协议。

命令：`step`、`continue`、`pause`、`stop`、`input`（含 text）。演示模式在每个 line 事件发送后等待放行；line 表示该行即将执行，表达式事件表示该表达式已求值，避免误解状态的先后关系。当前单步粒度是代码行，表达式细节用于回放。

事件具有 seq、kind、file、line、frames、heap、values。frames 为从模块到当前函数的有序调用帧，每帧包括 id、name、源码位置和 locals。标量表示为 type/value，其他对象表示为 type/ref；ref 指向当前事件 heap，表达式结果与返回值位于 values。对象身份在单次运行中保持稳定，循环引用使用 ref 表示，历史事件不会随对象后续修改而变化。

finished 事件包含 status、error、sources、output。归档格式 version=1，保存原始源码与完整事件；回放仅消费归档，不调用解释器。

客户端可通过 `PYVIS_COMPACT_HEAP=1` 启用 worker 传输压缩。worker 依次处理事件的 `before` 和当前快照，在 `heap` 中用 `null` 表示沿用上一份快照里对应 ID 的完整对象。客户端收到后展开，导出的归档仍使用原有格式。普通命令行使用完整快照。

AST 插桩在原始表达式求值之后记录其值，不重复求值。覆盖二元、一元、比较、布尔、调用、属性、下标和名称读取。局部模块也被插桩，库内部默认仅显示调用输入输出与可见对象状态。sys.settrace 负责行、调用、返回和异常。必须继续用未插桩 CPython 的输出、异常与副作用做差异测试，不能以图形是否能显示作为语义正确的证据。

后续顺序：

1. 在 Windows 构建机验收便携包及无 Python 环境启动，补充新建文件和工作区初始化。
2. 完成对象连线、计算操作数流动、判断路径及变化高亮；实时跟随与回看分离。
3. 增量记录、检查点跳转、限额暂停与恢复；扩大语义差异测试。
4. 增加用户配置的 AI 解释接口与系统安全密钥存储，保持无文件修改能力。
5. 安卓独立服务进程嵌入 CPython，完成软键盘与离线安装验收。
6. macOS 打包，然后实现 iOS 嵌入与协作停止；不得将桌面子进程方案直接用于 iOS。

## 逐行图形演示

新增 statement 事件，在同一调用帧下一条 line 或 return / exception 到达时结束上一行。字段包括 before（执行前的作用域和对象）、当前执行后的 frames / heap、code、statement_type、operation_seqs、start_seq、outcome。函数调用期间的参数绑定从真实 call 事件取得，表达式操作数从子表达式实际求值事件和字面量取得，不重新执行表达式。

LineTheater 按操作数读取、计算、调用参数、结果写入、容器更新和路径选择构建动画阶段。默认时间轴按完成的执行行推进；无执行事件的空白和注释不生成虚构动作。不支持的结构仍可显示实际行状态，但不保证已经拥有专门的教学动画。
