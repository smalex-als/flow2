# Flow2

Native macOS speech-to-text app with push-to-talk and text insertion.

Current features:

- real macOS `.app` build from [`Flow2.xcodeproj`](/Users/smalex/jsprojects/flow2tmp/Flow2.xcodeproj)
- push-to-talk recording with a global hotkey
- OpenAI transcription via `POST /v1/audio/transcriptions`
- direct insertion into native text fields through Accessibility
- terminal-specific typing path for `Terminal` and `iTerm`
- transcript history with quick copy / reinsert and persistence across launches
- menu bar control surface
- configurable hotkey presets
- optional launch-at-login toggle
- debug log and runtime status in the main window

Run:

1. Open [`Flow2.xcodeproj`](/Users/smalex/jsprojects/flow2tmp/Flow2.xcodeproj) in Xcode.
2. Build and run the `Flow2` scheme, or launch the built `.app`.
3. Grant `Microphone`, `Accessibility`, and if needed `Input Monitoring`.
4. Open Settings and add your OpenAI API key.
5. Use the configured push-to-talk shortcut.

Notes:

- Default model is `gpt-4o-mini-transcribe`.
- `Launch at login` works more reliably from a stable app bundle path such as `/Applications/Flow2.app`.
