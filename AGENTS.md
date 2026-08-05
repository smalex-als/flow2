# Repository Guidelines

## Project Structure & Module Organization

- `Flow2/` contains the macOS app source.
- `Flow2/Flow2App.swift` defines the app entry point, scenes, and menu bar extra.
- `Flow2/AppViewModel.swift` holds app state, the recording flow, the two dictation modes, translation, and transcript history persistence.
- `Flow2/AudioRecorder.swift`, `Flow2/OpenAITranscriptionClient.swift`, `Flow2/OpenAITranslationClient.swift`, and `Flow2/TextInsertionService.swift` contain the core services.
- `Flow2/SettingsView.swift` and `Flow2/ContentView.swift` contain the UI.
- `Flow2/Assets.xcassets` stores app assets.
- `Flow2.xcodeproj/` is the Xcode project. Update `project.pbxproj` when adding new source files.
- `Flow2Tests/` holds the unit test target, covering the pure logic worth pinning down: configuration decoding and migration, pasteboard save/restore, and audio level normalization.

## Build, Test, and Development Commands

- Build locally:
  ```bash
  xcodebuild -project Flow2.xcodeproj -scheme Flow2 -configuration Debug -derivedDataPath .deriveddata build
  ```
  Builds the macOS app without relying on Xcode UI.

- Run in Xcode:
  Open `Flow2.xcodeproj`, select the `Flow2` scheme, and run on `My Mac`.

- Git status:
  ```bash
  git status --short
  ```
  Use this before committing to avoid including unintended changes.

## Coding Style & Naming Conventions

- Language: Swift with SwiftUI/AppKit integration.
- Use 4-space indentation and keep files ASCII unless the file already needs Unicode.
- Prefer clear type names like `TextInsertionService` and `OpenAITranslationClient`.
- Use `UpperCamelCase` for types and `lowerCamelCase` for methods, properties, and variables.
- Keep UI logic in views and orchestration/state in `AppViewModel`.
- Prefer small focused services over large multi-purpose files.

## Testing Guidelines

- Run the suite with `make test`, or:
  ```bash
  xcodebuild test -project Flow2.xcodeproj -scheme Flow2 -destination 'platform=macOS' -derivedDataPath .deriveddata
  ```
- Add tests for logic that is decided once and then trusted forever — `AppConfiguration.init(from:)`
  is the clearest example, since a regression there rewrites a user's shortcuts or languages without
  anything appearing broken.
- Pasteboard tests must use a private `NSPasteboard`, never `.general`: the suite must not touch the
  clipboard of whoever runs it.
- UI behavior has no coverage; verify those changes by building and running.
- For behavioral changes, manually test:
  - recording start/stop
  - transcription
  - insertion into Notes or another native text field
  - terminal insertion in `Terminal` or `iTerm`

## Commit & Pull Request Guidelines

- Keep commit messages short, imperative, and specific, for example:
  - `Add per-message history deletion`
  - `Fix menu bar window reopening`
- The current history includes an initial baseline commit: `Initial working Flow2 app`.
- PRs should include:
  - a brief summary of behavior changes
  - any permission or setup implications
  - screenshots for visible UI changes
  - manual verification notes

## Security & Configuration Tips

- Never commit real OpenAI API keys.
- Runtime config and history are stored under `~/Library/Application Support/Flow2/`.
- `Accessibility`, `Microphone`, and sometimes `Input Monitoring` permissions are required for full functionality.
- Do not remove `DEVELOPMENT_TEAM` or `CODE_SIGN_IDENTITY` from the project-level build settings.
  They look like a needless tie to one developer's machine, but they are what keeps those
  permissions granted. macOS stores each grant against the app's designated requirement; with the
  ad-hoc signature you get by default, that requirement is a bare `cdhash`, so every rebuild looks
  like a new app and macOS asks again. Signing with a certificate makes the requirement name the
  certificate instead of the binary, and the grants survive rebuilds. Verify with
  `codesign -d -r- <app>` — the requirement must not mention `cdhash`.
