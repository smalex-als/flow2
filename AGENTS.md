# Repository Guidelines

## Project Structure & Module Organization

- `Flow2/` contains the macOS app source.
- `Flow2/Flow2App.swift` defines the app entry point, scenes, and menu bar extra.
- `Flow2/AppViewModel.swift` holds app state, recording flow, AI post-processing, and transcript history persistence.
- `Flow2/AudioRecorder.swift`, `Flow2/OpenAITranscriptionClient.swift`, `Flow2/OpenAIEditingClient.swift`, and `Flow2/TextInsertionService.swift` contain the core services.
- `Flow2/SettingsView.swift` and `Flow2/ContentView.swift` contain the UI.
- `Flow2/Assets.xcassets` stores app assets.
- `Flow2.xcodeproj/` is the Xcode project. Update `project.pbxproj` when adding new source files.
- There is currently no test target in the repository.

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
- Prefer clear type names like `TextInsertionService` and `OpenAIEditingClient`.
- Use `UpperCamelCase` for types and `lowerCamelCase` for methods, properties, and variables.
- Keep UI logic in views and orchestration/state in `AppViewModel`.
- Prefer small focused services over large multi-purpose files.

## Testing Guidelines

- There is no automated test suite yet.
- At minimum, verify changes by building with `xcodebuild`.
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
