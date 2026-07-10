# 快速开始

## 环境要求

- Flutter SDK `>= 3.16.0`
- macOS、Windows 或 Linux 桌面开发环境

## 安装并运行

```bash
git clone https://github.com/pynets/termora.git
cd termora
flutter pub get
flutter run -d macos
```

如果使用其他桌面平台，可以将 `macos` 换成 `windows` 或 `linux`。

## 构建发布版本

```bash
flutter build macos --release
```

其他平台对应的命令是 `flutter build windows --release` 和 `flutter build linux --release`。

## 第一次使用 Termora

1. 在 **Remote** 区域添加 SSH 主机。
2. 打开终端会话，也可以将工作区拆分成多个面板。
3. 需要查看 SQLite 或 PostgreSQL 数据时，添加对应的数据库连接。
4. 使用 **Notes** 编写 Markdown 文档和技术草稿。

!!! note
    某些数据库功能需要可访问的数据库和有效凭据。Termora 不会将你的连接信息上传到托管服务。
