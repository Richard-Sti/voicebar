# VoiceBar

Menu-bar dictation for macOS using Whisper (Groq or OpenAI). Press a shortcut, speak, and the text is pasted into the focused window.

Originally a fork of [williamjameshandley/linux-voice](https://github.com/williamjameshandley/linux-voice) by Will Handley; now developed independently.

## Install

Needs only the Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/Richard-Sti/voicebar
cd voicebar
macos/build.sh                 # builds and installs ~/Applications/VoiceBar.app
open ~/Applications/VoiceBar.app
```

Then:

1. Open **Settings** from the menu-bar microphone and enter a Whisper API key: Groq ([free key](https://console.groq.com)) or OpenAI.
2. Allow VoiceBar under System Settings › Privacy & Security › **Accessibility** (needed to paste) and **Microphone**.
3. Optionally turn on **Launch at login**.

### Keeping permissions across rebuilds

macOS ties the Accessibility and Microphone grants to the code signature. `build.sh` signs with a self-signed certificate named "VoiceBar Local Signing" if one is in your login keychain; otherwise it signs ad hoc and the grants are lost on every rebuild. Create the certificate once:

```bash
cat > /tmp/vb.cnf <<'EOF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = VoiceBar Local Signing
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout /tmp/vb.key -out /tmp/vb.pem -days 3650 -config /tmp/vb.cnf
/usr/bin/openssl pkcs12 -export -inkey /tmp/vb.key -in /tmp/vb.pem -out /tmp/vb.p12 -passout pass:vb -name "VoiceBar Local Signing"
security import /tmp/vb.p12 -k ~/Library/Keychains/login.keychain-db -P vb -T /usr/bin/codesign
rm /tmp/vb.key /tmp/vb.p12
```

## Usage

All shortcuts are set in Settings (click a field and press the keys). Defaults:

| Shortcut | Action |
|----------|--------|
| `Cmd+Shift+Space` | Dictate |
| `Cmd+Shift+Ctrl+Space` | Dictate, then press Return |
| `Cmd+Alt+Space` | Speak a correction to the last dictation ("change cash to cache") |
| `Cmd+Shift+K` | Delete the last dictation |
| `Esc` | Stop a recording |

By default a shortcut starts recording and pressing it again stops; Settings can switch to hold-to-talk.

- **Corrections** use Claude if an Anthropic API key is set in Settings, otherwise the transcription provider's chat model.
- **Vocabulary hint** (Settings) helps Whisper with names, jargon and British spelling.
- **Keep microphone ready** keeps the mic open between recordings so the first word is never clipped.
- **Offline recovery:** if a transcription fails for lack of network, the audio is kept and the menu offers to retry it.

API keys live in the Keychain; other settings in the app's preferences.

## Troubleshooting

- **Shortcut does nothing:** check Accessibility permission; remove and re-add VoiceBar after a macOS update or an ad-hoc rebuild. Secure Input (a focused password field, `sudo` in a terminal) blocks global shortcuts.
- **Text not appearing:** text is pasted with `Cmd+V`, so apps that block paste will not receive it.

## Development

```bash
macos/check.sh             # offline self-check
macos/check.sh --mic       # also test recording
macos/check.sh --network   # also test the API key
```

## Python script (legacy)

`voicebar.py` is the original cross-platform script (Linux X11 and macOS) that VoiceBar grew out of. It is configured through `~/.config/voicebar/config.toml`, which VoiceBar also imports once on first launch. Run it with `uv run python voicebar.py`; do not run it alongside the app, or both will react to the same shortcuts.

## License

MIT
