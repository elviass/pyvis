import Cocoa
import FlutterMacOS
import WebKit
import Security

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.titleVisibility = .hidden
    self.titlebarAppearsTransparent = true
    self.styleMask.insert(.fullSizeContentView)
    self.backgroundColor = NSColor(calibratedRed: 0.145, green: 0.149, blue: 0.157, alpha: 1)
    self.setContentSize(NSSize(width: 1400, height: 784))
    self.minSize = NSSize(width: 1000, height: 700)

    (NSApp.delegate as? AppDelegate)?.bindEditorCommands(flutterViewController.engine.binaryMessenger)
    bindAiCredentials(flutterViewController.engine.binaryMessenger)
    bindSourceFile(flutterViewController.engine.binaryMessenger)
    RegisterGeneratedPlugins(registry: flutterViewController)
    let graphRegistrar = flutterViewController.registrar(forPlugin: "PyvisComfyCanvas")
    graphRegistrar.register(GraphCanvasFactory(messenger: graphRegistrar.messenger), withId: "dev.pyvis.comfy")

    super.awakeFromNib()
  }
}

private func bindSourceFile(_ messenger: FlutterBinaryMessenger) {
  let channel = FlutterMethodChannel(name: "dev.pyvis/source_file", binaryMessenger: messenger)
  channel.setMethodCallHandler { call, result in
    guard call.method == "write" else { result(FlutterMethodNotImplemented); return }
    guard let arguments = call.arguments as? [String: Any],
          let path = arguments["path"] as? String,
          let data = arguments["data"] as? FlutterStandardTypedData else {
      result(FlutterError(code: "invalid_source_file", message: "无效的源文件数据", details: nil))
      return
    }
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        try data.data.write(to: URL(fileURLWithPath: path), options: .atomic)
        DispatchQueue.main.async { result(nil) }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "source_file_write", message: error.localizedDescription, details: nil))
        }
      }
    }
  }
}

/// A small, explicit WKWebView bridge. The native view does not execute Python.
/// The channel is installed before loading, independent of platform-view callbacks.
private final class GraphCanvasFactory: NSObject, FlutterPlatformViewFactory {
  let messenger: FlutterBinaryMessenger
  init(messenger: FlutterBinaryMessenger) { self.messenger = messenger }
  func createArgsCodec() -> (FlutterMessageCodec & NSObjectProtocol)? { FlutterStandardMessageCodec.sharedInstance() }
  func create(withViewIdentifier viewId: Int64, arguments args: Any?) -> NSView {
    let values = args as? [String: Any] ?? [:]
    return GraphCanvasHost(messenger: messenger, channelName: values["channel"] as? String ?? "", html: values["html"] as? String ?? "", size: NSSize(width: values["width"] as? Double ?? 1, height: values["height"] as? Double ?? 1))
  }
}

private final class GraphMessageHandler: NSObject, WKScriptMessageHandler {
  weak var host: GraphCanvasHost?
  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    if let event = message.body as? [String: Any] { host?.emit(event) }
  }
}

private final class GraphCanvasHost: NSView, WKNavigationDelegate {
  let webView: WKWebView
  let channel: FlutterMethodChannel
  let handler = GraphMessageHandler()
  init(messenger: FlutterBinaryMessenger, channelName: String, html: String, size: NSSize) {
    channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    let config = WKWebViewConfiguration()
    config.userContentController.add(handler, name: "graph")
    config.userContentController.addUserScript(WKUserScript(source: "window.flutter_inappwebview={callHandler:function(name,event){window.webkit.messageHandlers.graph.postMessage(event);return Promise.resolve(null);}};", injectionTime: .atDocumentStart, forMainFrameOnly: true))
    webView = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: config)
    super.init(frame: NSRect(origin: .zero, size: size))
    wantsLayer = true
    handler.host = self
    // Give WebKit a nonzero initial viewport before its offline document loads.
    // Flutter owns the host frame; the child follows it without Auto Layout
    // resetting the viewport to zero during platform-view attachment.
    webView.autoresizingMask = [.width, .height]
    webView.navigationDelegate = self
    webView.setValue(false, forKey: "drawsBackground")
    addSubview(webView)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(nil); return }
      if call.method == "render", let json = call.arguments as? String {
        self.webView.evaluateJavaScript("window.PyvisCanvas.receive(\(json));") { _, error in
          if let error = error { result(FlutterError(code: "canvas", message: error.localizedDescription, details: nil)) }
          else { result(nil) }
        }
      } else { result(FlutterMethodNotImplemented) }
    }
    webView.loadHTMLString(html, baseURL: nil)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func layout() {
    super.layout()
    webView.frame = bounds
  }
  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    webView.frame = bounds
  }
  override func setBoundsSize(_ newSize: NSSize) {
    super.setBoundsSize(newSize)
    webView.frame = NSRect(origin: .zero, size: newSize)
  }
  func emit(_ event: [String: Any]) { channel.invokeMethod("event", arguments: event) }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    webView.evaluateJavaScript("Boolean(window.PyvisCanvas)") { [weak self] ready, _ in
      if ready as? Bool == true { self?.emit(["action": "ready"]) }
      else { self?.emit(["action": "error", "message": "节点画布脚本加载失败。"] ) }
    }
  }
  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    emit(["action": "error", "message": error.localizedDescription])
  }
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    emit(["action": "error", "message": "节点画布进程已退出。"])
  }
  deinit {
    channel.setMethodCallHandler(nil)
    webView.configuration.userContentController.removeScriptMessageHandler(forName: "graph")
    webView.stopLoading()
  }
}

// Model credentials are plaintext inside an owner-only app support directory.
private struct LocalModelCredentials {
  let directory: URL

  private var file: URL { directory.appendingPathComponent("credentials.json") }

  private func fileError(_ code: Int32 = errno) -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(code))
  }

  private func ensurePrivateDirectory() throws {
    if mkdir(directory.path, 0o700) != 0 && errno != EEXIST { throw fileError() }
    var info = stat()
    if lstat(directory.path, &info) != 0 { throw fileError() }
    guard info.st_uid == geteuid(),
          (info.st_mode & S_IFMT) == S_IFDIR,
          (info.st_mode & 0o7777) == 0o700 else { throw fileError(EACCES) }
  }

  func load() throws -> String? {
    try ensurePrivateDirectory()
    let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    if fd < 0 {
      if errno == ENOENT { return nil }
      throw fileError()
    }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? handle.close() }
    var info = stat()
    if fstat(fd, &info) != 0 { throw fileError() }
    guard info.st_uid == geteuid(), info.st_nlink == 1,
          (info.st_mode & S_IFMT) == S_IFREG,
          (info.st_mode & 0o7777) == 0o600 else { throw fileError(EACCES) }
    guard let data = try handle.readToEnd(),
          let value = String(data: data, encoding: .utf8) else { throw fileError(EINVAL) }
    return value
  }

  func save(_ data: Data) throws {
    try ensurePrivateDirectory()
    let temporary = directory.appendingPathComponent(UUID().uuidString)
    let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    if fd < 0 { throw fileError() }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer {
      try? handle.close()
      _ = unlink(temporary.path)
    }
    if fchmod(fd, 0o600) != 0 { throw fileError() }
    try handle.write(contentsOf: data)
    try handle.synchronize()
    try handle.close()
    if rename(temporary.path, file.path) != 0 { throw fileError() }
  }

  static func appStore() throws -> LocalModelCredentials {
    let support = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask,
      appropriateFor: nil, create: true)
    return LocalModelCredentials(directory: support.appendingPathComponent("PyvisCredentials"))
  }
}

private func bindAiCredentials(_ messenger: FlutterBinaryMessenger) {
  let channel = FlutterMethodChannel(name: "dev.pyvis.ai.credentials", binaryMessenger: messenger)
  channel.setMethodCallHandler { call, result in
    if call.method == "load" {
      do {
        let store = try LocalModelCredentials.appStore()
        if let value = try store.load() {
          result(value)
          return
        }
        migrateLegacyModelCredentials(store, allowInteraction: call.arguments as? Bool ?? true, result: result)
      } catch {
        result(FlutterError(code: "secure_storage", message: "无法读取本地模型凭据", details: nil))
      }
    } else if call.method == "save", let value = call.arguments as? String {
      do {
        try LocalModelCredentials.appStore().save(Data(value.utf8))
        result(nil)
      } catch {
        result(FlutterError(code: "secure_storage", message: "无法保存本地模型凭据", details: nil))
      }
    } else {
      result(FlutterMethodNotImplemented)
    }
  }
}

private func migrateLegacyModelCredentials(
  _ store: LocalModelCredentials, allowInteraction: Bool, result: FlutterResult
) {
  let itemQuery: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "dev.pyvis.model-api",
    kSecAttrAccount as String: "configuration",
  ]
  var lookup = itemQuery
  lookup[kSecReturnData as String] = true
  lookup[kSecMatchLimit as String] = kSecMatchLimitOne
  var previousInteraction = DarwinBoolean(true)
  if !allowInteraction {
    guard SecKeychainGetUserInteractionAllowed(&previousInteraction) == errSecSuccess,
          SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else {
      result(FlutterError(code: "keychain_locked", message: nil, details: nil))
      return
    }
  }
  var item: CFTypeRef?
  let status = SecItemCopyMatching(lookup as CFDictionary, &item)
  if !allowInteraction {
    _ = SecKeychainSetUserInteractionAllowed(previousInteraction.boolValue)
  }
  switch status {
  case errSecItemNotFound:
    result(nil)
  case errSecSuccess:
    guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
      result(FlutterError(code: "secure_storage", message: "无法读取旧版模型配置", details: nil))
      return
    }
    do {
      try store.save(data)
      guard try store.load() == value else {
        result(FlutterError(code: "secure_storage", message: "无法确认本地凭据副本", details: nil))
        return
      }
      // Remove the legacy item only after verifying the new copy. Cleanup must
      // not prompt for a second Keychain authorization.
      var previousCleanupInteraction = DarwinBoolean(true)
      if SecKeychainGetUserInteractionAllowed(&previousCleanupInteraction) == errSecSuccess,
         SecKeychainSetUserInteractionAllowed(false) == errSecSuccess {
        _ = SecItemDelete(itemQuery as CFDictionary)
        _ = SecKeychainSetUserInteractionAllowed(previousCleanupInteraction.boolValue)
      }
      result(value)
    } catch {
      result(FlutterError(code: "secure_storage", message: "无法迁移旧版模型配置", details: nil))
    }
  case errSecInteractionNotAllowed, errSecInteractionRequired, errSecAuthFailed, errSecUserCanceled:
    result(FlutterError(code: "keychain_locked", message: nil, details: nil))
  default:
    result(FlutterError(code: "secure_storage", message: "无法读取旧版模型配置", details: nil))
  }
}
