import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    var windowFrame = self.frame

    // 设置 Flutter 视图背景色与 Splash 一致（#F5F5F2），
    // 消除 Flutter 引擎首帧渲染前的黑屏闪烁
    let splashBgColor = NSColor(red: 0.961, green: 0.961, blue: 0.949, alpha: 1.0)
    flutterViewController.backgroundColor = splashBgColor

    // 把窗口强行挪到屏幕外，彻底杜绝哪怕是阴影和边框的闪动
    windowFrame.origin = CGPoint(x: -10000, y: -10000)

    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    self.isOpaque = false
    self.backgroundColor = splashBgColor
    self.alphaValue = 0.0
    self.hasShadow = false // 禁用原生边框阴影

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
