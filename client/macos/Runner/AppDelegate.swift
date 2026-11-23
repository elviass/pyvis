import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private var editorCommands: FlutterMethodChannel?
  private var editItems: [String: NSMenuItem] = [:]
  private var editState: [String: Bool] = [:]
  private var runState: [String: Bool] = [:]
  private var runMenu: NSMenu?

  func bindEditorCommands(_ messenger: FlutterBinaryMessenger) {
    editorCommands = FlutterMethodChannel(name: "dev.pyvis/editor_commands", binaryMessenger: messenger)
    editorCommands?.setMethodCallHandler { [weak self] call, result in
      guard let values = call.arguments as? [String: Bool] else {
        result(FlutterMethodNotImplemented)
        return
      }
      switch call.method {
      case "editState":
        self?.editState = values
        self?.refreshEditItems()
      case "runMenuState":
        self?.runState = values
        self?.refreshRunItems()
      default:
        result(FlutterMethodNotImplemented)
        return
      }
      result(nil)
    }
  }

  @objc private func editorCommand(_ sender: NSMenuItem) {
    if let command = sender.representedObject as? String {
      editorCommands?.invokeMethod(command, arguments: nil)
    }
  }

  private func refreshEditItems() {
    for (name, item) in editItems { item.isEnabled = editState[name] ?? true }
  }

  private func refreshRunItems() {
    for item in runMenu?.items ?? [] {
      if let name = item.representedObject as? String {
        item.isEnabled = runState[name] ?? false
      }
    }
  }

  private func installEditorMenus() {
    guard let menu = NSApp.mainMenu else { return }
    func command(_ title: String, _ name: String, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
      let item = NSMenuItem(title: title, action: #selector(editorCommand(_:)), keyEquivalent: key)
      item.target = self
      item.representedObject = name
      item.keyEquivalentModifierMask = modifiers
      return item
    }
    func insertMenu(_ submenu: NSMenu) {
      let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
      item.submenu = submenu
      let index = menu.items.firstIndex { $0.submenu === NSApp.windowsMenu } ?? menu.numberOfItems
      menu.insertItem(item, at: index)
    }
    if menu.items.contains(where: { $0.identifier?.rawValue == "pyvis-file" }) { return }
    let file = NSMenu(title: "文件")
    file.addItem(command("新建 Python 文件", "new", "n"))
    file.addItem(command("打开 Python 文件…", "open", "o"))
    file.addItem(command("打开项目…", "project"))
    file.addItem(.separator())
    file.addItem(command("保存全部", "save", "s"))
    file.addItem(command("另存为…", "saveAs", "s", [.command, .shift]))
    file.addItem(command("关闭文件", "close", "w"))
    let fileItem = NSMenuItem(title: "文件", action: nil, keyEquivalent: "")
    fileItem.identifier = NSUserInterfaceItemIdentifier("pyvis-file")
    fileItem.submenu = file
    menu.insertItem(fileItem, at: 1)
    if let view = menu.items.first(where: { $0.title == "视图" })?.submenu {
      view.insertItem(command("编辑代码", "showCode"), at: 0)
      view.insertItem(command("代码流程图", "showFlow"), at: 1)
      view.insertItem(.separator(), at: 2)
      let tools = NSMenu(title: "工具窗口")
      tools.addItem(command("项目", "toggleProject"))
      tools.addItem(command("控制台", "toggleConsole"))
      tools.addItem(command("问题", "showProblems"))
      let toolsItem = NSMenuItem(title: tools.title, action: nil, keyEquivalent: "")
      toolsItem.submenu = tools
      view.insertItem(toolsItem, at: 3)
      view.insertItem(.separator(), at: 4)
    }
    if let editItem = menu.items.first(where: { $0.title == "Edit" || $0.title == "编辑" }) {
      let edit = NSMenu(title: "编辑")
      edit.autoenablesItems = false
      func editCommand(_ title: String, _ name: String, _ key: String, _ modifiers: NSEvent.ModifierFlags = [.command]) {
        let item = command(title, name, key, modifiers)
        editItems[name] = item
        edit.addItem(item)
      }
      editCommand("撤销", "editUndo", "z")
      editCommand("重做", "editRedo", "z", [.command, .shift])
      edit.addItem(.separator())
      editCommand("剪切", "editCut", "x")
      editCommand("复制", "editCopy", "c")
      editCommand("粘贴", "editPaste", "v")
      editCommand("全选", "editSelectAll", "a")
      edit.addItem(.separator())
      editCommand("查找…", "find", "f")
      editCommand("替换…", "replace", "r")
      editItem.title = "编辑"
      editItem.submenu = edit
      refreshEditItems()
    }
    let navigate = NSMenu(title: "导航")
    navigate.addItem(command("转到声明或用法", "definition", "b"))
    navigate.addItem(command("转到行和列…", "goToLine", "l"))
    navigate.addItem(.separator())
    let f2 = String(UnicodeScalar(NSF2FunctionKey)!)
    navigate.addItem(command("下一个问题", "nextIssue", f2, []))
    navigate.addItem(command("上一个问题", "previousIssue", f2, [.shift]))
    insertMenu(navigate)

    let code = NSMenu(title: "代码")
    code.autoenablesItems = false
    func addEditorAction(_ title: String, _ name: String, _ key: String, _ modifiers: NSEvent.ModifierFlags) {
      let item = command(title, name, key, modifiers)
      item.isEnabled = editState[name] ?? false
      editItems[name] = item
      code.addItem(item)
    }
    addEditorAction("复制行或选区", "duplicateCode", "d", [.command])
    addEditorAction("在下方另起一行", "startNewLine", "\r", [.shift])
    addEditorAction("完成当前语句", "completeStatement", "\r", [.command, .shift])
    code.addItem(.separator())
    code.addItem(command("重新格式化代码", "format", "l", [.command, .option]))
    code.addItem(command("优化导入", "imports", "o", [.command, .option]))
    code.addItem(.separator())
    addEditorAction("显示上下文操作", "intentions", "\r", [.option])
    code.addItem(command("参数信息", "parameters", "p"))
    code.addItem(command("快速文档", "documentation", String(UnicodeScalar(NSF1FunctionKey)!), []))
    code.addItem(.separator())
    code.addItem(command("检查代码", "check"))
    let refactor = NSMenu(title: "重构")
    refactor.autoenablesItems = false
    let rename = command("重命名变量…", "renameVariable", String(UnicodeScalar(NSF6FunctionKey)!), [.shift])
    editItems["renameVariable"] = rename
    rename.isEnabled = editState["renameVariable"] ?? false
    refactor.addItem(rename)
    code.addItem(.separator())
    let refactorItem = NSMenuItem(title: "重构", action: nil, keyEquivalent: "")
    refactorItem.submenu = refactor
    code.addItem(refactorItem)
    insertMenu(code)

    let run = NSMenu(title: "运行")
    run.autoenablesItems = false
    run.addItem(command("直接运行", "run"))
    run.addItem(command("演示运行", "runDemo"))
    run.addItem(command("停止运行", "stopRun"))
    run.addItem(.separator())
    run.addItem(command("打开执行记录…", "openTrace"))
    run.addItem(command("保存执行记录…", "saveTrace"))
    runMenu = run
    refreshRunItems()
    insertMenu(run)
    if let help = menu.items.first(where: { $0.title == "帮助" })?.submenu {
      help.addItem(command("键盘快捷键", "keymap"))
      help.addItem(.separator())
      help.addItem(command("关于 Pyvis", "about"))
    }
    if let about = menu.items.first?.submenu?.items.first(where: {
      $0.action == #selector(NSApplication.orderFrontStandardAboutPanel(_:))
    }) {
      about.action = #selector(editorCommand(_:))
      about.target = self
      about.representedObject = "about"
    }
    if let appMenu = menu.items.first?.submenu,
       let settings = appMenu.items.first(where: { $0.keyEquivalent == "," }) {
      settings.title = "设置…"
      settings.action = #selector(editorCommand(_:))
      settings.target = self
      settings.representedObject = "settings"
      settings.keyEquivalent = ","
      settings.keyEquivalentModifierMask = [.command]
    }
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    // FlutterAppDelegate does not implement this optional NSApplicationDelegate
    // selector; calling super raises NSInvalidArgumentException on a clean build.
    // A development launch must also reveal the editor when another app is fullscreen.
    DispatchQueue.main.async {
      self.installEditorMenus()
      self.mainFlutterWindow?.collectionBehavior.insert(.moveToActiveSpace)
      self.mainFlutterWindow?.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
    }
  }

  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    mainFlutterWindow?.collectionBehavior.insert(.moveToActiveSpace)
    mainFlutterWindow?.makeKeyAndOrderFront(nil)
    sender.activate(ignoringOtherApps: true)
    return true
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
