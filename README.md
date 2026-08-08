# Flow2

> Native macOS push-to-talk dictation with OpenAI transcription and fast text insertion back into
> the app you were using. Two shortcuts, two modes: say it, or say it and get it translated.

## Two Modes

Which shortcut you hold decides what comes out. Push-to-talk gives you no chance to state the
intent afterwards, so the mode is the key, not a setting.

| Mode | Default shortcut | Result |
| --- | --- | --- |
| **Dictate** | `⇧⌘Space` | The transcript exactly as recognized, in the language you spoke |
| **Dictate & Translate** | `⌃Space` | The transcript in your target language |

`Dictate` never sends your text to a second model. `Dictate & Translate` always does — you held
that key on purpose.

Both shortcuts are always live and are configurable in `Settings → Shortcuts`.

## Highlights

- 🎙️ Hold a global shortcut to record, release to transcribe
- 🌍 A dedicated shortcut that returns a language of your choosing, from any language or a named one
- 📚 Preferred terms dictionary for names, products, and custom spellings
- 📝 Native insertion for apps like Notes
- 💻 Dedicated typing path for `Terminal` and `iTerm`
- 📋 Paste fallback when direct insertion is not available
- 🕘 Persistent transcript history with `Copy` and `Delete`
- 📊 Words dictated, words per day, and speaking rate
- 🍎 Menu bar controls, launch-at-login, and visible debug status

## How It Works

1. Press and hold the shortcut for the mode you want.
2. Speak.
3. Release the shortcut.
4. Flow2 transcribes the audio with OpenAI.
5. In `Dictate & Translate`, Flow2 translates the transcript into your target language.
6. The result is saved into transcript history.
7. Flow2 inserts the text back into the target app.

A shortcut pressed while a previous recording is still being processed is refused, not queued.
Flow2 beeps and shows what it is busy with, so you find out before speaking rather than after.

## AI Pipeline

### 1. Transcription

- Endpoint: `POST /v1/audio/transcriptions`
- Default model: `gpt-transcribe`
- Runs for every recording, in both modes

### 2. Translation

- Endpoint: `POST /v1/chat/completions`
- Default model: `gpt-5.6-luna`
- Runs on every `Dictate & Translate` recording, and never on plain dictation
- Source language is either a named one or `Any language`, where the model works it out
- With `Any language`, text already in the target language is returned unchanged
- Translates without correcting, rewriting, or summarizing
- Uses a limited recent-history context only to resolve ambiguity
- Accepts a preferred-terms list so the model gives priority to your spellings

### Preferred Terms Dictionary

Add one preferred term per line in Settings:

```text
ChatGPT
Smalex
iTerm2
Flow2
```

These terms are sent to `gpt-transcribe` as `keywords[]` hints in both modes, and are passed into
translation as authoritative spellings.

## Insertion Paths

Flow2 tries the most appropriate path for the current app:

1. `Accessibility` insertion for native macOS text fields
2. Terminal typing path for `Terminal` and `iTerm`
3. Pasteboard + synthetic `Cmd+V` fallback

The paste path restores whatever you had on the clipboard once the target app has read the
transcript, so dictating never costs you the thing you copied. If you copy something new while
the paste is in flight, your new clipboard wins and nothing is put back.

## Recordings on Disk

Audio is temporary. A recording is deleted as soon as transcription succeeds, and is only kept
while a `Failed Recording` entry in history can still retry it — deleting that entry, or letting
it age out of history, removes the file too. Anything left over from a crash or force quit is
swept on the next launch.

## Menu Bar

Flow2 lives in the menu bar. With no window open it stays out of the Dock and out of `⌘Tab`,
and closing its last window puts it back there. While a window *is* open it behaves as an ordinary
app, which is what keeps the menu bar — and with it `⌘V` in the API key field — working.

The menu bar extra supports:

- Current status, and a warning when the system refused one of the shortcuts
- Start recording in either mode, with each mode's shortcut shown next to it
- Stop the recording in flight
- Show the main Flow2 window
- Open Settings
- Quit the app (`⌘Q`, which the menu carries itself since Flow2 usually has no menu bar)

## Settings

Changes apply as you make them — there is no Save button, so the menu bar and the settings window
can never disagree. Typed fields (API key, dictionary) are written once typing settles, or when
you leave the tab.

- **General** — OpenAI API key, translation languages (`From` / `To`) and model, `Launch Flow2 at login`
- **Dictionary** — preferred terms, one per line
- **Shortcuts** — one shortcut per mode; each refuses a combination the other already owns

### Upgrading from an earlier version

Configurations written before the two-mode split are migrated on first launch. Your old main
shortcut keeps the mode it used to produce: if `Auto-translate Russian to English` was on it
becomes `Dictate & Translate`, otherwise it becomes `Dictate`, and the old no-translate shortcut
takes the other mode. `Auto-edit transcript with AI` no longer exists — `Dictate` returns the raw
transcript.

Translation languages start at `Russian → English` for an upgraded configuration, matching what
the app used to do, and at `Any language → English` for a fresh install.

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
make test     # Run the unit tests
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
- `Flow2/OpenAITranslationClient.swift`: translation step for `Dictate & Translate`
- `Flow2/TextInsertionService.swift`: native insertion, terminal typing, paste fallback
- `Flow2/SettingsView.swift`: settings UI
- `Flow2/ContentView.swift`: main window, transcript list, debug/status UI
- `Flow2/AppConfiguration.swift`: persisted config, migrations, and storage paths
- `Flow2/DictationStatistics.swift`: word counting, aggregation, and the append-only stats file
- `Flow2/SecretStore.swift`: the API key's keychain entry
- `Flow2Tests/`: unit tests for configuration migration, pasteboard restore, and level metering

## Data Storage

- Config: `~/Library/Application Support/Flow2/config.json`
- History: `~/Library/Application Support/Flow2/history.json`
- Statistics: `~/Library/Application Support/Flow2/stats.jsonl`
- OpenAI API key: the login keychain, as a generic password under `com.smalex.Flow2`

Statistics are one line of JSON per dictation and hold no transcript text — only a timestamp, a
duration, a word count, and the mode. That is what makes them safe to keep indefinitely, unlike
history, which is capped at 12 entries because it holds what you actually said.

The word count comes from the raw transcript rather than the inserted text, so translating does not
change how many words you are credited with saying. Recordings shorter than three seconds count
towards the totals but not towards the speaking rate: the silence around a two-word reply is most of
its length, and it would drag the figure well below how fast you actually speak.

Versions up to 8 wrote the API key into `config.json` in plain text. It is moved to the keychain on
first launch and the file is rewritten without it — the key only counts as migrated once the
keychain holds it, so a keychain that refuses leaves the file alone rather than losing the key.

Keychain access survives rebuilds for the same reason the Accessibility grant does: the designated
requirement names the signing certificate, not a `cdhash`. The entry is readable by other processes
running as you while the keychain is unlocked; what it buys is that the key is no longer sitting in
a plain file that any tool, sync client, or backup can read.

## Notes

- `About Flow2` reports the marketing version, a build number taken from the commit count, the
  commit it was built from, and that commit's subject — so a running app can be tied to the exact
  set of changes in it. `MARKETING_VERSION` in the project is the only number to bump by hand.
- `Launch at login` is more reliable when the app is run from `/Applications/Flow2.app`
- Accessibility trust is tied to the exact app bundle path
- Debug and runtime status are intentionally visible in the main window

## Repository

Git remote:

```text
git@github.com:smalex-als/flow2.git
```
