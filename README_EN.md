<div align="center">

# Termora

**A Modern, High-Performance Cross-Platform Desktop Developer Toolbox**

**English** | [简体中文](./README.md)

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](./LICENSE)
[![Flutter](https://img.shields.io/badge/Flutter-%3E%3D3.16-02569B?logo=flutter)](https://flutter.dev)
[![Platform](https://img.shields.io/badge/Platform-macOS%20%7C%20Windows%20%7C%20Linux-lightgrey.svg)]()

</div>

---

## ✨ Overview

**Termora** is a sleek, modern desktop toolbox for engineers and developers built with Flutter. Designed for cross-platform desktop operating systems (macOS, Windows, and Linux), it consolidates everyday developer tools into one elegant workspace.

Instead of jumping between fragmented SSH clients, database tools, note-taking apps, and screenshot utilities, Termora brings everything together seamlessly.

---

## 🚀 Key Features

### 🖥️ 1. SSH / SFTP Terminal Console & File Management
- **Multi-Session Management**: Connect to and manage multiple SSH servers concurrently with split panes and tabbed sessions.
- **Integrated SFTP Browser**: Effortlessly drag and drop files between local storage and remote servers.
- **Command Snippets & Highlighting**: Built-in snippet library and customizable terminal syntax/log highlighting.

### 🗄️ 2. Database Explorer
- **Multi-Engine Support**: Connect directly to PostgreSQL and SQLite databases.
- **SQL Editor & Data Viewer**: Write and execute SQL queries with rich syntax highlights and browse table records.

### 📝 3. All-in-One Markdown & LaTeX Notes
- **Live Markdown Preview**: Write documentation or scratch notes with real-time markdown rendering.
- **LaTeX Math Rendering**: Precision typesetting for complex mathematical equations (`$$`).
- **High-Quality PDF Export**: Convert and export technical notes to beautifully styled PDF documents.

### 📸 4. Screenshot Capture & Floating Pin Windows
- **Global Shortcut Capture**: Trigger screenshot capture anytime with `⌥+Shift+X` (macOS/Windows).
- **Lightweight Annotation Editor**: Highlight, draw, and crop screenshots on the fly.
- **Always-on-Top Floating Pin**: Pin reference images onto your desktop while coding or debugging.

### 🎨 5. Modern Aesthetics & Bilingual Support
- **Adaptive Light & Dark Themes**: Fully refined dark and light modes with customizable brand colors.
- **Bilingual Interface**: Switch instantly between **English**, **Simplified Chinese**, or **System Default** in app settings.
- **System Tray Integration**: Background tray icon with startup toggle and quick-action menu.

---

## 🛠️ Tech Stack

- **Framework**: [Flutter 3.x](https://flutter.dev) / [Dart 3.x](https://dart.dev)
- **State Management**: [Riverpod 2.x](https://riverpod.dev)
- **Desktop Native Integration**: `window_manager`, `tray_manager`, `desktop_multi_window`, `hotkey_manager`
- **Local Storage**: `shared_preferences`, `sqlite3`

---

## 📦 Getting Started

### Prerequisites
- Flutter SDK `>= 3.16.0`
- macOS / Windows / Linux desktop development environment

### Clone & Install
```bash
git clone https://github.com/wangxi/termora.git
cd termora
flutter pub get
```

### Run Locally
```bash
# macOS
flutter run -d macos

# Windows
flutter run -d windows

# Linux
flutter run -d linux
```

### Build for Production
```bash
flutter build macos --release
```

---

## 🤝 Contributing

Contributions, issues, and feature requests are always welcome!

1. Fork the Project
2. Create your Feature Branch (`git checkout -b feature/AmazingFeature`)
3. Commit your Changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the Branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

---

## 📄 License

Distributed under the [MIT License](./LICENSE).
