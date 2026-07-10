# Getting started

## Requirements

- Flutter SDK `>= 3.16.0`
- A macOS, Windows, or Linux desktop development environment

## Install and run

```bash
git clone https://github.com/pynets/termora.git
cd termora
flutter pub get
flutter run -d macos
```

Replace `macos` with `windows` or `linux` for another desktop target.

## Build a release

```bash
flutter build macos --release
```

The equivalent commands for other targets are `flutter build windows --release` and `flutter build linux --release`.

## First steps in Termora

1. Add an SSH host from the **Remote** area.
2. Open a terminal session and optionally split the workspace into panes.
3. Add a database connection when you need to inspect SQLite or PostgreSQL data.
4. Use **Notes** for Markdown documentation and technical scratch work.

!!! note
    Some database integrations need a reachable database and valid credentials. Termora does not upload your connection information to a hosted service.
