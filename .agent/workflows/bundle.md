---
description: Create a .app macOS application bundle for HotkeyLauncher
---

# Package as macOS App

This workflow builds the project in release mode and packages it into a standard macOS `.app` bundle.

## Steps

// turbo

1. Run the bundling script:

```bash
./scripts/bundle.sh
```

2. The application will be created as `HotkeyLauncher.app` in the project root. You can move this to your `/Applications` folder.
