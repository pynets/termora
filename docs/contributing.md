# Contributing

Issues, feature requests, documentation improvements, and pull requests are welcome.

## Development workflow

```bash
flutter pub get
flutter test
flutter analyze
```

For documentation changes, install the Python dependencies and start a local preview:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r docs/requirements.txt
mkdocs serve
```

Open `http://127.0.0.1:8000` to preview the site. Changes under `docs/` are rebuilt automatically.

## Pull requests

1. Create a focused branch from `main`.
2. Keep code, tests, and documentation changes together when they describe the same feature.
3. Run the relevant Flutter checks before opening a pull request.
4. Include screenshots or a short video when a change affects the desktop UI.

Please read the repository [LICENSE](https://github.com/pynets/termora/blob/main/LICENSE) before contributing.
