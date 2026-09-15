# KeyboardShortcuts 3.1.0

Source: https://github.com/sindresorhus/KeyboardShortcuts/tree/3.1.0
License: MIT (see `license`).

Vendored to build with Apple's Command Line Tools without full Xcode:

- Replaced `@Entry` in `ConflictPolicy.swift` with the equivalent explicit `EnvironmentKey`.
- Removed three design-time `#Preview` declarations from `Recorder.swift`.
- Package manifest includes only the library target; upstream tests are not copied.

The keyboard shortcut implementation is otherwise unchanged.
- Deployment target is macOS 26, matching Diktat and the isolated-deinit runtime requirement.
- Expanded the nested conditional in `HotKeyCenter.updateMode()` to `if`/`else` per workspace rules.
- Localization checks the app's `Contents/Resources` before the SwiftPM fallback so the signed `.app` has a standard bundle layout.
