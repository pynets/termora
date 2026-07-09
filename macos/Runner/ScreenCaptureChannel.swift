import Cocoa
import FlutterMacOS
import ScreenCaptureKit

/// 原生截屏通道 — 简化版
/// 只负责截取屏幕和剪贴板操作，不做任何窗口管理
/// 窗口管理交给 desktop_multi_window（独立截屏编辑器窗口）
///
/// macOS 14+ 使用 ScreenCaptureKit（Apple 在 Sequoia/Tahoe 上唯一仍然认 TCC
/// 屏幕录制授权的 API）；更老版本回退到 CGDisplayCreateImage。
class ScreenCaptureChannel {
    
    static func register(with controller: FlutterViewController) {
        let channel = FlutterMethodChannel(
            name: "com.hxlive.termora/screen_capture",
            binaryMessenger: controller.engine.binaryMessenger
        )
        
        let instance = ScreenCaptureChannel()
        
        channel.setMethodCallHandler { (call, result) in
            switch call.method {
            case "captureScreen":
                instance.captureScreen(result: result)
            case "captureScreenToFile":
                instance.captureScreenToFile(result: result)
            case "copyImageToClipboard":
                instance.copyImageToClipboard(call: call, result: result)
            case "getWindowList":
                instance.getWindowList(result: result)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }
    
    // MARK: - 屏幕截取

    /// 截取全屏 — 返回 PNG 数据
    private func captureScreen(result: @escaping FlutterResult) {
        captureScreenAsPNG { data, error in
            DispatchQueue.main.async {
                if let data = data {
                    result(FlutterStandardTypedData(bytes: data))
                } else {
                    result(error ?? FlutterError(code: "UNKNOWN", message: "Unknown screenshot error", details: nil))
                }
            }
        }
    }

    /// 截取全屏 — 保存到临时文件，返回文件路径
    /// 用于多窗口模式：主窗口截图 → 保存文件 → 传路径给截屏编辑器窗口
    private func captureScreenToFile(result: @escaping FlutterResult) {
        captureScreenAsPNG { data, error in
            DispatchQueue.main.async {
                guard let data = data else {
                    result(error ?? FlutterError(code: "UNKNOWN", message: "Unknown screenshot error", details: nil))
                    return
                }
                let tempPath = NSTemporaryDirectory() + "screenshot_\(ProcessInfo.processInfo.globallyUniqueString).png"
                do {
                    try data.write(to: URL(fileURLWithPath: tempPath))
                    result(tempPath)
                } catch {
                    result(FlutterError(code: "WRITE_FAILED", message: error.localizedDescription, details: nil))
                }
            }
        }
    }

    /// 屏幕截取核心实现：macOS 14+ 用 ScreenCaptureKit，老版本回退 CGDisplayCreateImage。
    /// 完成回调 (pngData, flutterError) 二选一。
    private func captureScreenAsPNG(completion: @escaping (Data?, FlutterError?) -> Void) {
        if #available(macOS 14.0, *) {
            Task {
                do {
                    let content = try await SCShareableContent.excludingDesktopWindows(
                        false,
                        onScreenWindowsOnly: true
                    )
                    guard let display = content.displays.first else {
                        completion(nil, FlutterError(code: "NO_DISPLAY", message: "No display found", details: nil))
                        return
                    }

                    // 不排除自己的窗口：
                    //   - 截屏是在编辑器窗口创建之前发生的，此时屏幕上唯一可能存在的本 app 窗口就是主窗口
                    //   - 主窗口属于"用户按下快捷键时屏幕上的真实内容"，应该被忠实截下
                    //   - 如果排除，编辑器盖上来后用户会以为主窗口"凭空消失了"（实际只是被 P 掉）
                    let filter = SCContentFilter(display: display, excludingWindows: [])

                    let config = SCStreamConfiguration()
                    config.width = Int(CGFloat(display.width) * (NSScreen.main?.backingScaleFactor ?? 2.0))
                    config.height = Int(CGFloat(display.height) * (NSScreen.main?.backingScaleFactor ?? 2.0))
                    config.showsCursor = false
                    config.capturesAudio = false

                    let cgImage = try await SCScreenshotManager.captureImage(
                        contentFilter: filter,
                        configuration: config
                    )

                    let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
                    guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
                        completion(nil, FlutterError(code: "ENCODE_FAILED", message: "PNG encoding failed", details: nil))
                        return
                    }
                    print("[ScreenCapture] SCK capture OK: \(pngData.count) bytes")
                    completion(pngData, nil)
                } catch {
                    let ns = error as NSError
                    print("[ScreenCapture] SCK capture failed: domain=\(ns.domain) code=\(ns.code) msg=\(ns.localizedDescription)")
                    // SCStreamError.userDeclined == -3801 / SCK 权限拒绝相关错误
                    if ns.domain == SCStreamErrorDomain || ns.localizedDescription.contains("permission") || ns.localizedDescription.contains("declined") {
                        if #available(macOS 10.15, *) { CGRequestScreenCaptureAccess() }
                        completion(nil, FlutterError(code: "PERMISSION_DENIED", message: "Screen Recording permission denied (SCK)", details: ns.localizedDescription))
                    } else {
                        completion(nil, FlutterError(code: "CAPTURE_FAILED", message: ns.localizedDescription, details: nil))
                    }
                }
            }
            return
        }

        // macOS < 14 回退到 CGDisplayCreateImage
        if !hasScreenRecordingPermission() {
            if #available(macOS 10.15, *) { CGRequestScreenCaptureAccess() }
            completion(nil, FlutterError(code: "PERMISSION_DENIED", message: "Screen Recording permission not granted", details: nil))
            return
        }
        let displayID = CGMainDisplayID()
        guard let cgImage = CGDisplayCreateImage(displayID) else {
            if #available(macOS 10.15, *) { CGRequestScreenCaptureAccess() }
            completion(nil, FlutterError(code: "PERMISSION_DENIED", message: "CGDisplayCreateImage returned nil", details: nil))
            return
        }
        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
            completion(nil, FlutterError(code: "ENCODE_FAILED", message: "PNG encoding failed", details: nil))
            return
        }
        completion(pngData, nil)
    }

    // MARK: - 屏幕录制权限检测

    /// 通过窗口列表启发式检测屏幕录制权限是否已授予。
    /// 原理：未授权时 CGWindowListCopyWindowInfo 对非自身进程的窗口不会暴露
    /// kCGWindowName（标题），即使能拿到 bounds。所以如果屏幕上存在其他
    /// 进程的普通窗口、却没有任何一个有标题，则可以判定为权限缺失。
    /// 之所以不用 CGPreflightScreenCaptureAccess()：该 API 在 macOS Sequoia
    /// 上即使权限已授予也可能返回 false，不可靠。
    private func hasScreenRecordingPermission() -> Bool {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return true
        }

        let myPid = ProcessInfo.processInfo.processIdentifier
        let systemOwners: Set<String> = [
            "Window Server", "Dock", "SystemUIServer",
            "Control Center", "Notification Center",
            "Spotlight", "loginwindow", "WindowManager",
            "TextInputMenuAgent", "universalAccessAuthWarn",
            "Wallpaper"
        ]

        var otherProcessCount = 0
        var withTitleCount = 0

        for info in windowList {
            guard let ownerPid = info[kCGWindowOwnerPID as String] as? Int32,
                  ownerPid != myPid else { continue }

            if let ownerName = info[kCGWindowOwnerName as String] as? String,
               systemOwners.contains(ownerName) { continue }

            if let layer = info[kCGWindowLayer as String] as? Int, layer != 0 {
                continue
            }

            otherProcessCount += 1
            if let name = info[kCGWindowName as String] as? String, !name.isEmpty {
                withTitleCount += 1
            }
        }

        // 屏幕上没有其他进程的可见窗口 → 无从判断，保守放行
        let granted = otherProcessCount == 0 || withTitleCount > 0
        let preflight: Bool = {
            if #available(macOS 10.15, *) { return CGPreflightScreenCaptureAccess() }
            return true
        }()
        print("[ScreenCapture] permission check: otherProcWindows=\(otherProcessCount) withTitle=\(withTitleCount) heuristic=\(granted) preflight=\(preflight)")
        fflush(stdout)
        return granted
    }
    
    // MARK: - 窗口列表
    
    /// 获取当前屏幕上所有可见窗口的边界
    /// 用于截屏编辑器的智能窗口检测（悬停高亮 + 单击选中）
    private func getWindowList(result: @escaping FlutterResult) {
        guard let windowInfoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            result([])
            return
        }
        
        // 获取主屏幕尺寸
        let screenWidth = NSScreen.main?.frame.width ?? 0
        let screenHeight = NSScreen.main?.frame.height ?? 0
        
        var windows: [[String: Any]] = []
        var seenBounds: Set<String> = []
        
        for info in windowInfoList {
            // 过滤系统窗口
            if let ownerName = info[kCGWindowOwnerName as String] as? String {
                let skipOwners = [
                    "Window Server", "Dock", "SystemUIServer",
                    "Control Center", "Notification Center",
                    "Spotlight", "loginwindow", "WindowManager",
                    "TextInputMenuAgent", "universalAccessAuthWarn"
                ]
                if skipOwners.contains(ownerName) { continue }
            }
            
            // 窗口层级过滤：只保留普通窗口层级
            if let layer = info[kCGWindowLayer as String] as? Int, layer != 0 {
                continue
            }
            
            // 获取窗口边界
            guard let boundsDict = info[kCGWindowBounds as String] as? [String: Double],
                  let x = boundsDict["X"],
                  let y = boundsDict["Y"],
                  let w = boundsDict["Width"],
                  let h = boundsDict["Height"] else {
                continue
            }
            
            // 过滤太小的窗口
            if w < 50 || h < 50 { continue }
            
            // 过滤覆盖整个屏幕的窗口（通常是壁纸/桌面背景/全屏遮罩）
            if w >= screenWidth && h >= (screenHeight - 30) {
                continue
            }
            
            // 去重：相同 bounds 的窗口只保留一个
            let boundsKey = "\(Int(x)),\(Int(y)),\(Int(w)),\(Int(h))"
            if seenBounds.contains(boundsKey) { continue }
            seenBounds.insert(boundsKey)
            
            let windowData: [String: Any] = [
                "x": x,
                "y": y,
                "width": w,
                "height": h,
                "title": (info[kCGWindowName as String] as? String) ?? "",
                "ownerName": (info[kCGWindowOwnerName as String] as? String) ?? "",
            ]
            windows.append(windowData)
        }
        
        result(windows)
    }
    
    // MARK: - 剪贴板
    
    /// 将 PNG 图片复制到系统剪贴板 — 原生 NSPasteboard API
    private func copyImageToClipboard(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? FlutterStandardTypedData else {
            result(FlutterError(code: "INVALID_ARGS", message: "Expected Uint8List", details: nil))
            return
        }
        
        let data = args.data
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        
        // 写入 PNG 和 TIFF 双格式，兼容微信/钉钉等所有应用
        if let image = NSImage(data: data) {
            pasteboard.writeObjects([image])
        } else {
            pasteboard.setData(data, forType: .png)
        }
        result(true)
    }
}

