import Cocoa
import FlutterMacOS
import desktop_multi_window
import ObjectiveC

extension NSWindow {
    @objc dynamic var swizzled_canBecomeKeyWindow: Bool {
        return true
    }

    static func swizzleCanBecomeKeyWindow() {
        let originalSelector = #selector(getter: NSWindow.canBecomeKey)
        let swizzledSelector = #selector(getter: NSWindow.swizzled_canBecomeKeyWindow)

        guard let originalMethod = class_getInstanceMethod(NSWindow.self, originalSelector),
              let swizzledMethod = class_getInstanceMethod(NSWindow.self, swizzledSelector) else {
            return
        }
        method_exchangeImplementations(originalMethod, swizzledMethod)
    }
}

@main
class AppDelegate: FlutterAppDelegate {
  private var securityScopedFileUrls: [String: URL] = [:]

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // 返回 false 以便关闭窗口后应用仍在托盘中常驻运行
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
      // 欺骗 macOS 系统：让所有（包括纯无边框的）窗口都可以接受键盘焦点，
      // 用于修复 borderless 的截图窗口收不到 ESC 按键的问题
      NSWindow.swizzleCanBecomeKeyWindow()

      let controller: FlutterViewController = mainFlutterWindow?.contentViewController as! FlutterViewController

      // 启动时主动触发屏幕录制权限弹窗（首次运行时弹出，已授权或已拒绝则静默返回）
      if #available(macOS 10.15, *) {
          CGRequestScreenCaptureAccess()
      }

      // 注册原生截屏 / 终端 PTY 通道（主窗口）
      ScreenCaptureChannel.register(with: controller)
      TerminalPtyChannel.register(with: controller)

      let fileAccessChannel = FlutterMethodChannel(name: "com.hxlive.termora/file_access",
                                                   binaryMessenger: controller.engine.binaryMessenger)
      fileAccessChannel.setMethodCallHandler { [weak self] call, result in
          guard let self = self else {
              result(FlutterError(code: "APP_DELEGATE_RELEASED", message: "App delegate is unavailable", details: nil))
              return
          }
          self.handleFileAccessCall(call, result: result)
      }

      // 注册子窗口创建回调 — 用于配置截屏编辑器窗口
      FlutterMultiWindowPlugin.setOnWindowCreatedCallback { [weak self] childController in
          self?.configureChildWindow(childController)
      }

      super.applicationDidFinishLaunching(notification)
  }

  private func handleFileAccessCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String else {
          result(FlutterError(code: "INVALID_ARGUMENTS", message: "Missing file path", details: nil))
          return
      }

      switch call.method {
      case "createBookmark":
          do {
              let url = URL(fileURLWithPath: path)
              let data = try url.bookmarkData(options: [.withSecurityScope],
                                              includingResourceValuesForKeys: nil,
                                              relativeTo: nil)
              result(data.base64EncodedString())
          } catch {
              result(FlutterError(code: "BOOKMARK_CREATE_FAILED",
                                  message: error.localizedDescription,
                                  details: nil))
          }
      case "startAccessing":
          guard let bookmark = args["bookmark"] as? String,
                let bookmarkData = Data(base64Encoded: bookmark) else {
              result(FlutterError(code: "INVALID_ARGUMENTS", message: "Missing bookmark data", details: nil))
              return
          }
          do {
              var isStale = false
              let url = try URL(resolvingBookmarkData: bookmarkData,
                                options: [.withSecurityScope],
                                relativeTo: nil,
                                bookmarkDataIsStale: &isStale)
              let ok = url.startAccessingSecurityScopedResource()
              if ok {
                  securityScopedFileUrls[path] = url
              }
              result(ok)
          } catch {
              result(FlutterError(code: "BOOKMARK_RESOLVE_FAILED",
                                  message: error.localizedDescription,
                                  details: nil))
          }
      case "stopAccessing":
          if let url = securityScopedFileUrls.removeValue(forKey: path) {
              url.stopAccessingSecurityScopedResource()
          }
          result(nil)
      default:
          result(FlutterMethodNotImplemented)
      }
  }

  // MARK: - 子窗口配置

  /// 配置子窗口 — 由 desktop_multi_window 创建时回调
  func configureChildWindow(_ childController: FlutterViewController) {
      // 为子窗口注册截屏通道（用于剪贴板操作）
      ScreenCaptureChannel.register(with: childController)

      // Make the FlutterViewController transparent to avoid initial black/white flash
      childController.backgroundColor = NSColor.clear

      // 记住截屏前用户正在使用的应用（截屏关闭后恢复焦点用）
      let previousApp = NSWorkspace.shared.frontmostApplication

      // 判断当前 app 是否在前台
      // - 前台触发：编辑器在主窗口上直接盖上去，无闪烁问题，主窗口保持可见即可
      // - 后台触发：NSApp.activate 会把主窗口提到 normal level 最前，
      //             而编辑器图片异步加载期间是透明的，主窗口会"闪一下"。
      //             此时用 alphaValue=0 暂时隐形（保留 z-order 位置），关闭编辑器时恢复。
      let wasAppActive = NSApp.isActive
      let mainWindow = mainFlutterWindow
      let savedMainAlpha = mainWindow?.alphaValue ?? 1.0

      // 注册截屏窗口管理通道
      let windowChannel = FlutterMethodChannel(
          name: "com.hxlive.termora/screenshot_window",
          binaryMessenger: childController.engine.binaryMessenger
      )

      windowChannel.setMethodCallHandler { [weak childController, weak mainWindow] (call, result) in
          guard let controller = childController, let window = controller.view.window else {
              result(FlutterError(code: "NO_WINDOW", message: "No window", details: nil))
              return
          }

          switch call.method {
          case "presentEditor":
              // Dart 在 _loadImage 完成、首帧已渲染后调用 —— 此时图片已经准备好绘制
              if !wasAppActive {
                  mainWindow?.alphaValue = 0
              }
              window.makeKeyAndOrderFront(nil)
              NSApp.activate(ignoringOtherApps: true)
              result(nil)
          case "close":
              window.orderOut(nil)
              if let flutterController = window.contentViewController as? FlutterViewController {
                  flutterController.engine.shutDownEngine()
              }
              window.close()
              // 恢复主窗口可见性（z-order 不变）
              mainWindow?.alphaValue = savedMainAlpha
              // 将焦点精确还给截屏前的活跃应用，不影响主窗口层级
              if !wasAppActive,
                 let prev = previousApp,
                 prev.bundleIdentifier != Bundle.main.bundleIdentifier {
                  prev.activate()
              }
              result(nil)
          default:
              result(FlutterMethodNotImplemented)
          }
      }

      // 仅配置窗口属性（不显示）。显示推迟到 Dart 端 _loadImage 完成后的 presentEditor 调用
      DispatchQueue.main.async {
          guard let window = childController.view.window else { return }
          guard let screen = NSScreen.main else { return }

          // 设为真正的无边框全屏，使其完全覆盖顶部菜单栏
          window.styleMask = [.borderless]
          window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
          window.hasShadow = false
          window.isOpaque = false
          window.backgroundColor = NSColor.clear
          window.setFrame(screen.frame, display: true, animate: false)
      }

      // ═══ 贴图浮窗通道 ═══
      let pinChannel = FlutterMethodChannel(
          name: "com.hxlive.termora/pin_window",
          binaryMessenger: childController.engine.binaryMessenger
      )

      pinChannel.setMethodCallHandler { [weak childController] (call, result) in
          guard let controller = childController, let window = controller.view.window else {
              result(FlutterError(code: "NO_WINDOW", message: "No window", details: nil))
              return
          }

          switch call.method {
          case "present":
              // 贴图窗口就绪后调用 — 重新配置窗口为浮动小窗口
              guard let args = call.arguments as? [String: Any],
                    let imgWidth = args["width"] as? Double,
                    let imgHeight = args["height"] as? Double else {
                  result(FlutterError(code: "INVALID_ARGS", message: "Missing width/height", details: nil))
                  return
              }

              guard let screen = NSScreen.main else {
                  result(FlutterError(code: "NO_SCREEN", message: "No main screen", details: nil))
                  return
              }

              // 计算窗口大小：使用传递过来的逻辑尺寸，但限制最大为屏幕的 1/2
              let maxWidth = screen.visibleFrame.width * 0.5
              let maxHeight = screen.visibleFrame.height * 0.5
              let scale = min(1.0, min(maxWidth / CGFloat(imgWidth), maxHeight / CGFloat(imgHeight)))
              let winWidth = CGFloat(imgWidth) * scale
              let winHeight = CGFloat(imgHeight) * scale

              // 放置在屏幕右上角，留一些边距
              let x = screen.visibleFrame.maxX - winWidth - 20
              let y = screen.visibleFrame.maxY - winHeight - 20

              window.styleMask = [.borderless]
              window.level = .floating
              window.hasShadow = true
              window.isOpaque = false
              window.backgroundColor = NSColor.clear
              window.isMovableByWindowBackground = false  // 我们自己处理拖拽
              window.setFrame(NSRect(x: x, y: y, width: winWidth, height: winHeight),
                              display: true, animate: false)
              window.makeKeyAndOrderFront(nil)
              // 不 activate app — 贴图窗口不抢主窗口焦点
              result(nil)

          case "close":
              window.orderOut(nil)
              if let flutterController = window.contentViewController as? FlutterViewController {
                  flutterController.engine.shutDownEngine()
              }
              window.close()
              result(nil)

          case "startDragging":
              if let event = NSApp.currentEvent {
                  window.performDrag(with: event)
              }
              result(nil)

          default:
              result(FlutterMethodNotImplemented)
          }
      }
  }
}
