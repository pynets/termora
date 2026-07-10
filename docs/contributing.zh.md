# 参与贡献

欢迎提交 Issue、功能建议、文档改进和 Pull Request。

## 开发流程

```bash
flutter pub get
flutter test
flutter analyze
```

如果修改了文档，可以安装 Python 依赖并启动本地预览：

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r docs/requirements.txt
mkdocs serve
```

打开 `http://127.0.0.1:8000` 即可预览网站。修改 `docs/` 下的文件后，页面会自动重新构建。

## 提交 Pull Request

1. 从 `main` 创建一个聚焦的功能分支。
2. 如果代码、测试和文档描述的是同一项功能，尽量放在同一个变更中。
3. 提交 Pull Request 前运行相关的 Flutter 检查。
4. 如果改动影响桌面界面，请附上截图或简短视频。

提交贡献前请阅读仓库中的 [LICENSE](https://github.com/pynets/termora/blob/main/LICENSE)。
