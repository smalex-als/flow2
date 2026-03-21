# Flow2

Flow2 is a native macOS push-to-talk speech-to-text app built with SwiftUI.

It records audio, sends it to OpenAI for transcription, optionally post-processes the result with AI, and then inserts the final text into the app you were using.

## What It Does

- Global push-to-talk hotkey.
- Native macOS `.app` project in `Flow2.xcodeproj`.
- Audio recording with microphone permission handling.
- OpenAI transcription through `POST /v1/audio/transcriptions`.
- Optional AI auto-edit pass after transcription.
- Optional Russian-to-English auto-translation during AI editing when the raw transcript contains Cyrillic text.
- Direct Accessibility-based insertion into native macOS text fields.
- Terminal typing path for `Terminal` and `iTerm`.
- Paste fallback when direct insertion is not available.
- Persistent transcript history across launches.
- Per-message copy and delete actions in history.
- Menu bar extra with quick controls and quick AI toggle switches.
- Configurable hotkey presets.
- Optional launch at login.
- Debug log and runtime status visible in the main window.

## Current AI Behavior

Flow2 has two separate OpenAI steps:

1. Transcription
   Uses the configured transcription model. Default:
   `gpt-4o-mini-transcribe`

2. Optional post-processing
   Uses a chat model to rewrite only the latest message using recent history as context. Default:
   `gpt-5.4-nano`

When `Auto-edit transcript with AI` is enabled:

- Flow2 sends the latest transcript plus a limited number of recent previous messages.
- It expects back only the corrected latest message.
- It does not ask for the whole conversation to be returned.

When `Auto-translate Russian to English` is also enabled:

- Flow2 first checks the raw transcript for Cyrillic characters.
- If Russian text is detected, the AI editing step is instructed to return the corrected latest message in English.
- If no Russian text is detected, it behaves like normal AI editing.

The history context is intentionally limited. Flow2 does not send the full history.

## Main App Flow

1. Press and hold the configured hotkey.
2. Speak.
3. Release the hotkey to stop recording.
4. Flow2 transcribes the audio.
5. If enabled, Flow2 runs AI post-processing.
6. The final text is added to transcript history.
7. Flow2 inserts the final text back into the target app.

## Insertion Behavior

Flow2 tries insertion in this order:

1. Direct Accessibility insertion for native macOS text inputs.
2. Terminal-specific unicode typing for `Terminal` and `iTerm`.
3. Pasteboard + synthetic `Cmd+V` fallback when needed.

This means native apps like Notes can use direct insertion, while terminal windows use a dedicated typing path.

## Menu Bar Extra

The menu bar extra supports:

- Start / stop recording.
- Show the main Flow2 window.
- Open Settings.
- Quit Flow2.
- Quick toggle for `AI Auto-Edit`.
- Quick toggle for `Translate RU -> EN`.

The menu bar no longer shows the last transcript text.

## Transcript History

Transcript history is stored between launches and shown in the main window as one list.

Each item supports:

- `Copy`
- `Delete`

History is saved to:

- `~/Library/Application Support/Flow2/history.json`

Configuration is saved to:

- `~/Library/Application Support/Flow2/config.json`

## Settings

Current settings include:

- OpenAI API key
- Transcription model
- `Auto-edit transcript with AI`
- `Auto-translate Russian to English`
- Push-to-talk hotkey preset
- `Launch Flow2 at login`

## Permissions

Depending on the target app and insertion path, Flow2 may need:

- `Microphone`
- `Accessibility`
- `Input Monitoring`

For direct cross-app insertion, `Accessibility` is the important one.

For synthetic key events and some paste/typing paths, `Input Monitoring` may also be required.

## Build And Run

1. Open `Flow2.xcodeproj` in Xcode.
2. Build and run the `Flow2` scheme.
3. Or launch the built app directly from the build products.
4. Grant required macOS permissions.
5. Open Settings and add your OpenAI API key.
6. Choose your preferred hotkey and AI behavior.

Local build command:

```bash
xcodebuild -project Flow2.xcodeproj -scheme Flow2 -configuration Debug -derivedDataPath .deriveddata build
```

## Project Structure

- `Flow2/Flow2App.swift`
  App entry point, scenes, menu bar extra.
- `Flow2/AppDelegate.swift`
  Global hotkey registration and event handling.
- `Flow2/AppViewModel.swift`
  App state, recording flow, transcription flow, AI post-processing, history persistence.
- `Flow2/AudioRecorder.swift`
  Audio capture and stop/finalization flow.
- `Flow2/OpenAITranscriptionClient.swift`
  Multipart transcription request.
- `Flow2/OpenAIEditingClient.swift`
  AI rewrite / optional translate step.
- `Flow2/TextInsertionService.swift`
  Accessibility insertion, terminal typing, paste fallback.
- `Flow2/SettingsView.swift`
  Settings UI.
- `Flow2/ContentView.swift`
  Main window UI, transcript history, debug/status views.
- `Flow2/AppConfiguration.swift`
  Persistent configuration models and storage paths.

## Git

This project is now initialized as a Git repository and pushed to:

`git@github.com:smalex-als/flow2.git`

The main branch tracks `origin/main`.

## Notes

- `Launch at login` is more reliable when the app is run from a stable location such as `/Applications/Flow2.app`.
- Accessibility trust can appear to break if macOS trusts a different app bundle path than the one currently running.
- Flow2 intentionally keeps debug/status information visible in the main window.
