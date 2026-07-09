<div align="center">

# Termora

**现代、高效、跨平台的全能桌面级开发工具箱**

*A Modern, High-Performance Cross-Platform Desktop Developer Toolbox*

[English](./README.md) | **简体中文**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](./LICENSE)
[![Flutter](https://img.shields.io/badge/Flutter-%3E%3D3.16-02569B?logo=flutter)](https://flutter.dev)
[![Platform](https://img.shields.io/badge/Platform-macOS%20%7C%20Windows%20%7C%20Linux-lightgrey.svg)]()

</div>

---

## ✨ 简介 (Introduction)

**Termora** 是一款基于 Flutter 深度构建的桌面端全能开发者工具箱。旨在为工程师和高级用户提供一体化、跨平台、极致流畅的生产力客户端。

不再需要在各类分散的终端工具、数据库客户端、笔记软件和截屏小工具之间频繁切换，Termora 把日常开发最关键的工具流汇集到一个优雅得体的原生窗口中。

## 📥 下载安装包 (Release v0.0.1)

- **macOS 安装包 (.dmg)**: [下载 Termora-v0.0.1-macOS.dmg](./release/Termora-v0.0.1-macOS.dmg)

---

## 📸 应用预览 (Preview)

| 🖥️ 终端控制台 (Terminal) | 🌐 远程主机与 SFTP (Remote) |
| :---: | :---: |
| ![终端](docs/screenshots/terminal.png) | ![远程](docs/screenshots/remote.png) |
| **🗄️ 数据库客户端 (Database)** | **📝 全能笔记与 LaTeX (Notes)** |
| ![数据库](docs/screenshots/database.png) | ![笔记](docs/screenshots/notes.png) |

---

## 🚀 核心特性 (Key Features)

### 🖥️ 1. SSH / SFTP 终端连接与文件管理器
- **多会话管理与分屏**：同时管理与连接多个 SSH 主机，支持快速切换与多会话并发。
- **内置 SFTP 浏览器**：不仅支持命令行交互，更能便捷拖拽管理远端文件。
- **命令片段与高亮**：内置常用命令片段库与日志关键词自动高亮解析。

### 🗄️ 2. 数据库客户端 (Database Explorer)
- **多数据源支持**：内置支持 PostgreSQL、SQLite 等常用数据源的高效连接与操作。
- **SQL 编写与执行**：具备高亮提示的 SQL 编写器，快速执行查询并结构化浏览表格数据。

### 📝 3. 全能 Markdown 与 LaTeX 笔记
- **实时双栏预览**：流畅的 Markdown 编辑与渲染能力，支持表格、代码段与任务列表。
- **LaTeX 公式排版**：内置对数学物理公式（`$$` 语法）的精确排版渲染。
- **高清 PDF 导出**：支持把技术文档一键生成并导出为精美的标准 PDF。

### 📸 4. 截屏编辑与桌面贴图 (Screenshot & Pin Window)
- **快捷唤起截屏**：全局快捷键 `⌥+Shift+X` (macOS/Windows 通用) 一键截取屏幕。
- **轻量编辑器**：支持框选、标注和高亮处理。
- **桌面悬浮贴图**：一键将其贴图悬浮在桌面最前列，方便随时对比研发参考图。

### 🎨 5. 现代审美设计与双语无缝适配
- **明暗两极智能适配**：内置精调深色 / 浅色模式，与品牌自选主色体系连贯融合。
- **中英文双语界面**：应用设置内一键在 **English / 简体中文 / 跟随系统** 之间切换（默认英文）。
- **常驻系统托盘**：提供便捷开机自启、置顶及快捷操作菜单。

---

## 🛠️ 技术栈 (Tech Stack)

- **框架**：[Flutter 3.x](https://flutter.dev) / [Dart 3.x](https://dart.dev)
- **状态管理**：[Riverpod 2.x](https://riverpod.dev)
- **桌面原生特性**：`window_manager`, `tray_manager`, `desktop_multi_window`, `hotkey_manager`
- **本地化存储**：`shared_preferences`, `sqlite3`

---

## 📦 构建与运行 (Building & Running)

### 环境要求
- Flutter SDK `>= 3.16.0`
- macOS / Windows / Linux 桌面开发环境

### 克隆与依赖安装
```bash
git clone https://github.com/pynets/termora.git
cd termora
flutter pub get
```

### 本地运行
```bash
# macOS
flutter run -d macos

# Windows
flutter run -d windows

# Linux
flutter run -d linux
```

### 生产打包
```bash
flutter build macos --release
```

---

## 🤝 贡献指南 (Contributing)

非常欢迎各类 Issue 与 Pull Request！如果您对 Termora 有建议或新功能构想，欢迎共同建设。

1. Fork 本仓库
2. 创建特性分支 (`git checkout -b feature/AmazingFeature`)
3. 提交更改 (`git commit -m 'Add some AmazingFeature'`)
4. 推送到分支 (`git push origin feature/AmazingFeature`)
5. 提交 Pull Request

---

## 📄 开源协议 (License)

本项目采用 [MIT License](./LICENSE) 开源协议。
