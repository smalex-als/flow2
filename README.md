# Flow2

> Native macOS push-to-talk dictation with OpenAI transcription, AI cleanup, and fast text insertion back into the app you were using.

## Highlights

- 🎙️ Hold a global hotkey to record, release to transcribe
- ✨ Optional AI auto-editing with recent-message context
- 🌍 Optional Russian-to-English translation when Cyrillic is detected
- 📚 Preferred terms dictionary for names, products, and custom spellings
- 📝 Native insertion for apps like Notes
- 💻 Dedicated typing path for `Terminal` and `iTerm`
- 📋 Paste fallback when direct insertion is not available
- 🕘 Persistent transcript history with `Copy` and `Delete`
- 🍎 Menu bar controls, custom global hotkeys, launch-at-login, and visible debug status

## How It Works

1. Press and hold the configured hotkey.
2. Speak.
3. Release the hotkey.
4. Flow2 transcribes the audio with OpenAI.
5. If enabled, Flow2 runs AI post-processing on only the latest message.
6. The result is saved into transcript history.
7. Flow2 inserts the text back into the target app.

## AI Pipeline

### 1. Transcription

- Endpoint: `POST /v1/audio/transcriptions`
- Default model: `gpt-transcribe`

### 2. Optional AI post-processing

- Default model: `gpt-5.6-luna`
- Uses only the latest message plus a limited recent-history context
- Returns only the corrected latest message
- Translation can run independently of transcript auto-editing
- When enabled, translation forces English output when the raw transcript contains Cyrillic
- Accepts a preferred-terms list so the model gives priority to your spellings

### Preferred Terms Dictionary

Add one preferred term per line in Settings:

```text
ChatGPT
Smalex
iTerm2
Flow2
```

These terms are sent to `gpt-transcribe` as `keywords[]` hints and are also passed into enabled translation or auto-editing as authoritative spellings.

## Insertion Paths

Flow2 tries the most appropriate path for the current app:

1. `Accessibility` insertion for native macOS text fields
2. Terminal typing path for `Terminal` and `iTerm`
3. Pasteboard + synthetic `Cmd+V` fallback

## Menu Bar

The menu bar extra supports:

- Start / stop recording
- Show the main Flow2 window
- Open Settings
- Toggle `AI Auto-Edit`
- Toggle `Translate RU -> EN`
- Quit the app

## Settings

Current settings:

- OpenAI API key
- Post-processing model
- `Auto-edit transcript with AI`
- `Auto-translate Russian to English`
- Preferred terms dictionary
- Custom push-to-talk hotkeys
- `Launch Flow2 at login`

## Permissions

Depending on the insertion path, Flow2 may need:

- `Microphone`
- `Accessibility`
- `Input Monitoring`

For cross-app native insertion, `Accessibility` is the important one. For synthetic key events and some terminal/paste paths, `Input Monitoring` may also be required.

## Build

Open [`Flow2.xcodeproj`](/Users/smalex/jsprojects/flow2tmp/Flow2.xcodeproj) in Xcode and run the `Flow2` scheme, or build locally:

```bash
xcodebuild -project Flow2.xcodeproj -scheme Flow2 -configuration Debug -derivedDataPath .deriveddata build
```

The repository also includes a Makefile with shortcuts for common build tasks:

```bash
make          # Build the Debug configuration
make run      # Build and launch Flow2
make clean    # Remove build products
```

To build another configuration, pass it on the command line:

```bash
make run CONFIGURATION=Release
```

## Project Layout

- `Flow2/Flow2App.swift`: app entry point, scenes, menu bar extra
- `Flow2/AppDelegate.swift`: global hotkey registration
- `Flow2/AppViewModel.swift`: recording/transcription flow, AI logic, history, status
- `Flow2/AudioRecorder.swift`: audio capture and stop finalization
- `Flow2/OpenAITranscriptionClient.swift`: multipart transcription request
- `Flow2/OpenAIEditingClient.swift`: AI rewrite and translation step
- `Flow2/TextInsertionService.swift`: native insertion, terminal typing, paste fallback
- `Flow2/SettingsView.swift`: settings UI
- `Flow2/ContentView.swift`: main window, transcript list, debug/status UI
- `Flow2/AppConfiguration.swift`: persisted config and storage paths

## Data Storage

- Config: `~/Library/Application Support/Flow2/config.json`
- History: `~/Library/Application Support/Flow2/history.json`

## Notes

- `Launch at login` is more reliable when the app is run from `/Applications/Flow2.app`
- Accessibility trust is tied to the exact app bundle path
- Debug and runtime status are intentionally visible in the main window

## Repository

Git remote:

```text
git@github.com:smalex-als/flow2.git
```
