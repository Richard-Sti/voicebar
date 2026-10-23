#!/usr/bin/env python3
"""
voicebar: Voice-to-text dictation tool for Linux (X11) and macOS

Hold Ctrl+Space to record, release to transcribe and type.
Toggle mode: Press Ctrl+Space to start, press again to stop.

Requires Python 3.11+ for tomllib.
"""

import io
import os
import shutil
import subprocess
import sys
import threading
import time
import unicodedata
import wave
from pathlib import Path

# Ensure platform_support.py is importable regardless of working directory
sys.path.insert(0, str(Path(__file__).parent.resolve()))

import numpy as np
from platform_support import get_platform
import sounddevice as sd
from pynput import keyboard

# Minimum recording duration in seconds (avoid accidental triggers)
MIN_RECORDING_SECONDS = 0.3
# Maximum recording duration in seconds (safety timeout)
MAX_RECORDING_SECONDS = 120
# Load config from ~/.config/voicebar/config.toml if it exists
CONFIG = {}
CONFIG_PATH = Path.home() / ".config" / "voicebar" / "config.toml"
if not CONFIG_PATH.exists():  # ponytail: pre-rename location, drop once nobody uses it
    CONFIG_PATH = Path.home() / ".config" / "linux-voice" / "config.toml"
if CONFIG_PATH.exists():
    try:
        import tomllib
        CONFIG = tomllib.loads(CONFIG_PATH.read_text())
    except Exception as e:
        print(f"\033[91mConfig error in {CONFIG_PATH}: {e}. Using defaults.\033[0m")
        CONFIG = {}

# Grace period (seconds) before stopping on key release — absorbs brief finger slips
RELEASE_GRACE_SECONDS = CONFIG.get("hotkey", {}).get("release_grace", 0.5)

# Configuration with defaults
SAMPLE_RATE = CONFIG.get("audio", {}).get("sample_rate", 16000)  # Whisper native rate
INPUT_DEVICE = CONFIG.get("audio", {}).get("input_device", "MacBook Pro Microphone")  # name or index
CHANNELS = 1
LANGUAGE = CONFIG.get("transcription", {}).get("language", "en")
PROMPT = CONFIG.get("transcription", {}).get("prompt", "")
REPLACEMENTS = CONFIG.get("replacements", {})

# Backend configuration (openai or groq)
BACKEND = CONFIG.get("transcription", {}).get("backend", "openai")
WHISPER_MODEL = CONFIG.get("transcription", {}).get("model", None)
if WHISPER_MODEL is None:
    WHISPER_MODEL = "whisper-large-v3-turbo" if BACKEND == "groq" else "whisper-1"
MODE = os.environ.get(
    "VOICEBAR_MODE",
    CONFIG.get("hotkey", {}).get("mode", "hold"),
)

# Platform-aware hotkey defaults
# macOS: Cmd+Shift+Space (avoids Spotlight and input source switching conflicts)
# Linux: Ctrl+Space
_IS_MACOS = sys.platform == "darwin"
_DEFAULT_RECORD_MODS = ["cmd", "shift"] if _IS_MACOS else ["ctrl"]
_DEFAULT_SUBMIT_MODS = ["cmd", "shift", "ctrl"] if _IS_MACOS else ["ctrl", "shift"]
_DEFAULT_EDIT_MODS = ["cmd", "alt"] if _IS_MACOS else ["ctrl", "alt"]


def _parse_modifiers(modifier_names: list[str]) -> set:
    """Parse modifier name list into pynput key set."""
    mods = set()
    for mod in modifier_names:
        if mod == "ctrl":
            mods.update({keyboard.Key.ctrl_l, keyboard.Key.ctrl_r})
        elif mod == "alt":
            mods.update({keyboard.Key.alt_l, keyboard.Key.alt_r})
        elif mod == "shift":
            mods.update({keyboard.Key.shift_l, keyboard.Key.shift_r})
        elif mod in ("super", "cmd"):
            mods.update({keyboard.Key.cmd_l, keyboard.Key.cmd_r})
    return mods


# macOS virtual keycode map for hotkey suppression and vk-based matching
_VK_MAP = {
    "space": 49, "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5,
    "h": 4, "i": 34, "j": 38, "k": 40, "l": 37, "m": 46, "n": 45, "o": 31,
    "p": 35, "q": 12, "r": 15, "s": 1, "t": 17, "u": 32, "v": 9, "w": 13,
    "x": 7, "y": 16, "z": 6,
    "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61,
    "f7": 0x62, "f8": 0x64, "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,
}


def _make_key(name: str):
    """Create a pynput Key/KeyCode, using vk on macOS for reliable matching."""
    special = getattr(keyboard.Key, name, None)
    if special is not None:
        return special
    if _IS_MACOS:
        vk = _VK_MAP.get(name)
        if vk is not None:
            return keyboard.KeyCode.from_vk(vk, char=name)
    return keyboard.KeyCode.from_char(name)


# Hotkey configuration
_hotkey_cfg = CONFIG.get("hotkey", {})
_key_name = _hotkey_cfg.get("key", "space")
HOTKEY_KEY = _make_key(_key_name)
_modifier_names = _hotkey_cfg.get("modifiers", _DEFAULT_RECORD_MODS)
HOTKEY_MODIFIERS = _parse_modifiers(_modifier_names)
if not HOTKEY_MODIFIERS:
    HOTKEY_MODIFIERS = _parse_modifiers(_DEFAULT_RECORD_MODS)

# For "all modifiers" check, we need one key per modifier type
# Normalize "cmd" to "super" for consistent checking
_required_modifier_types = set(
    "super" if m == "cmd" else m for m in (_modifier_names or _DEFAULT_RECORD_MODS)
)

# Submit hotkey - same as main hotkey but presses Enter after
_submit_cfg = CONFIG.get("hotkey_submit", {})
SUBMIT_DELAY = _submit_cfg.get("delay", 150)  # ms delay before Enter key
SUBMIT_KEY = _make_key(_submit_cfg.get("key", "space"))
_submit_modifier_names = _submit_cfg.get("modifiers", _DEFAULT_SUBMIT_MODS)
SUBMIT_MODIFIERS = _parse_modifiers(_submit_modifier_names)
if not SUBMIT_MODIFIERS:
    SUBMIT_MODIFIERS = _parse_modifiers(_DEFAULT_SUBMIT_MODS)
_submit_modifier_types = set(
    "super" if m == "cmd" else m for m in (_submit_modifier_names or _DEFAULT_SUBMIT_MODS)
)

# Edit hotkey - corrects last transcription via LLM
_edit_cfg = CONFIG.get("hotkey_edit", {})
EDIT_KEY = _make_key(_edit_cfg.get("key", "space"))
_edit_modifier_names = _edit_cfg.get("modifiers", _DEFAULT_EDIT_MODS)
EDIT_MODIFIERS = _parse_modifiers(_edit_modifier_names)
if not EDIT_MODIFIERS:
    EDIT_MODIFIERS = _parse_modifiers(_DEFAULT_EDIT_MODS)
_edit_modifier_types = set(
    "super" if m == "cmd" else m for m in (_edit_modifier_names or _DEFAULT_EDIT_MODS)
)

# Delete hotkey - deletes last transcription (Cmd+Shift+D / Ctrl+Shift+D)
_DEFAULT_DELETE_MODS = ["cmd", "shift"] if _IS_MACOS else ["ctrl", "shift"]
_delete_cfg = CONFIG.get("hotkey_delete", {})
_delete_key_name = _delete_cfg.get("key", "k")
DELETE_KEY = _make_key(_delete_key_name)
_delete_modifier_names = _delete_cfg.get("modifiers", _DEFAULT_DELETE_MODS)
DELETE_MODIFIERS = _parse_modifiers(_delete_modifier_names)
if not DELETE_MODIFIERS:
    DELETE_MODIFIERS = _parse_modifiers(_DEFAULT_DELETE_MODS)
_delete_modifier_types = set(
    "super" if m == "cmd" else m for m in (_delete_modifier_names or _DEFAULT_DELETE_MODS)
)

# Map modifier type names to CGEvent flag masks
_MOD_FLAG_MAP = {
    "cmd": 0x100000, "super": 0x100000,
    "shift": 0x20000,
    "ctrl": 0x40000,
    "alt": 0x80000,
}


def _mod_flags(modifier_names):
    flags = 0
    for m in modifier_names:
        flags |= _MOD_FLAG_MAP.get(m, 0)
    return flags


# Map vk → required CGEvent modifier flags for each hotkey combo
_SUPPRESS_COMBOS = {}
if _IS_MACOS:
    for kn, mod_names in [
        (_key_name, _modifier_names),
        (_submit_cfg.get("key", "space"), _submit_cfg.get("modifiers", _DEFAULT_SUBMIT_MODS)),
        (_edit_cfg.get("key", "space"), _edit_cfg.get("modifiers", _DEFAULT_EDIT_MODS)),
        (_delete_key_name, _delete_modifier_names),
    ]:
        vk = _VK_MAP.get(kn)
        flags = _mod_flags(mod_names)
        if vk is not None and flags:
            _SUPPRESS_COMBOS[vk] = _SUPPRESS_COMBOS.get(vk, 0) | flags

# LLM model for corrections (per backend)
LLM_MODEL = CONFIG.get("transcription", {}).get("llm_model", None)
if LLM_MODEL is None:
    LLM_MODEL = "llama-3.3-70b-versatile" if BACKEND == "groq" else "gpt-4o-mini"

# Corrections with Claude when an Anthropic API key is configured in [edit]
_edit_llm_cfg = CONFIG.get("edit", {})
ANTHROPIC_API_KEY = (
    _edit_llm_cfg.get("anthropic_api_key") or os.environ.get("ANTHROPIC_API_KEY", "")
)
CLAUDE_MODEL = _edit_llm_cfg.get("model", "claude-opus-5-5")


def apply_replacements(text: str) -> str:
    """Apply user-configured regex replacements."""
    import re
    for pattern, replacement in REPLACEMENTS.items():
        text = re.sub(pattern, replacement, text)
    return text


def grapheme_count(text: str) -> int:
    """Number of Backspace presses needed to delete `text`.

    One Backspace removes a user-perceived character, so combining marks,
    variation selectors and the character after a zero-width joiner do not
    count separately.
    """
    # ponytail: covers accents, emoji variants and ZWJ emoji; flags and other
    # multi-codepoint clusters would need the `regex` module's \X.
    count = 0
    joined = False
    for ch in text:
        if joined:
            joined = False
        elif ch == "‍":
            joined = True
        elif not (unicodedata.combining(ch) or "︀" <= ch <= "️"):
            count += 1
    return count


def check_environment(platform):
    """Check for required dependencies and environment."""
    errors = []

    # Check for API key: environment variable first, then config.toml fallback
    if BACKEND == "groq":
        api_key = os.environ.get("GROQ_API_KEY") or CONFIG.get("transcription", {}).get("api_key", "")
        if not api_key:
            errors.append("GROQ_API_KEY not set. Set env var or add api_key to [transcription] in config.toml")
        else:
            os.environ["GROQ_API_KEY"] = api_key
    else:
        api_key = os.environ.get("OPENAI_API_KEY") or CONFIG.get("transcription", {}).get("api_key", "")
        if not api_key:
            errors.append("OPENAI_API_KEY not set. Set env var or add api_key to [transcription] in config.toml")
        else:
            os.environ["OPENAI_API_KEY"] = api_key

    # Platform-specific checks (xdotool on Linux, Accessibility on macOS, etc.)
    errors.extend(platform.check_environment())

    if errors:
        for err in errors:
            print(f"\033[91mError: {err}\033[0m")
        sys.exit(1)


def _has_all_modifiers(pressed: set, required_types: set) -> bool:
    """Check if all required modifier types are pressed."""
    for mod_type in required_types:
        if mod_type == "ctrl":
            if keyboard.Key.ctrl_l not in pressed and keyboard.Key.ctrl_r not in pressed:
                return False
        elif mod_type == "alt":
            if keyboard.Key.alt_l not in pressed and keyboard.Key.alt_r not in pressed:
                return False
        elif mod_type == "shift":
            if keyboard.Key.shift_l not in pressed and keyboard.Key.shift_r not in pressed:
                return False
        elif mod_type == "super":
            if keyboard.Key.cmd_l not in pressed and keyboard.Key.cmd_r not in pressed:
                return False
    return True


class VoiceRecorder:
    def __init__(self, platform):
        if BACKEND == "groq":
            from groq import APIConnectionError, Groq
            self.client = Groq()
        else:
            from openai import APIConnectionError, OpenAI
            self.client = OpenAI()
        # Raised when the API cannot be reached (APITimeoutError subclasses it)
        self.connection_error = APIConnectionError
        self.claude = None
        if ANTHROPIC_API_KEY:
            import anthropic
            self.claude = anthropic.Anthropic(api_key=ANTHROPIC_API_KEY)
        self.platform = platform
        self.recording = False
        self.audio_data = []
        self.stream = None
        self.pressed_modifiers = set()
        self.hotkey_pressed = False
        self.has_ffmpeg = shutil.which("ffmpeg") is not None
        self.submit_mode = False  # Whether to press Enter after typing
        self.edit_mode = False  # Whether to correct last transcription
        self.last_typed_text = ""  # Store for edit mode corrections
        self.all_typed_text = ""  # All text typed so far (for spacing logic)
        self.active_app = None  # App/window to type into
        self.delete_pressed = False  # Suppress key repeat for delete
        self.stray_key_count = 0  # Count of leaked hotkey chars during recording
        self._state_lock = threading.Lock()  # Guards recording state transitions
        self._debounce_generation = 0  # Incremented on re-press to cancel pending stops

    def _convert_to_mp3(self, audio: np.ndarray) -> io.BytesIO:
        """Convert numpy audio to MP3 using ffmpeg."""
        command = [
            "ffmpeg",
            "-f", "s16le",
            "-ar", str(SAMPLE_RATE),
            "-ac", str(CHANNELS),
            "-i", "pipe:0",
            "-codec:a", "libmp3lame",
            "-b:a", "32k",
            "-f", "mp3",
            "pipe:1",
        ]
        process = subprocess.Popen(
            command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        mp3_data, _ = process.communicate(input=audio.tobytes())
        mp3_buffer = io.BytesIO(mp3_data)
        mp3_buffer.name = "audio.mp3"
        return mp3_buffer

    def _correct_with_llm(self, original: str, instruction: str) -> str:
        """Use LLM to correct text based on instruction."""
        system_prompt = """You are an intelligent text editing assistant for a voice dictation tool used by a programmer in a Unix terminal environment. Your goal is to apply user correction instructions to the provided text.

Context about the user:
- Working in Unix/Linux terminal, often typing shell commands and code
- Programming languages: Python, shell scripts, and related tools
- Voice recognition often mishears technical terms (e.g., "cash" for "cache", "bite" for "byte", "get" for "git", "pie" for "py", "boss" for "bash")

Follow these rules:
1. GLOBAL APPLICATION: Apply the instruction to the ENTIRE text. Do not stop after the first few instances. Scan from start to finish.
2. BROAD INTENT: Interpret instructions generously. If the user asks to change "numbers", apply it to digits, written words, and mixed formats. If they ask to "remove filler words", remove all types.
3. CONSISTENCY: Ensure the corrected text is stylistically consistent. If a change is applied to one part, apply it to matching patterns elsewhere.
4. INTEGRITY: Do not change the meaning of the content, only the form/style as requested.
5. TECHNICAL AWARENESS: Consider programming/Unix context when interpreting corrections.
6. STRICT OUTPUT: Output ONLY the corrected text. No preamble, no explanation, no quotes."""

        # Include domain context from Whisper prompt if available
        context_note = ""
        if PROMPT:
            context_note = f"\n\nDomain context: {PROMPT}"

        user_prompt = f"""Original text: {original}

Instruction: {instruction}{context_note}"""

        if self.claude is not None:
            try:
                response = self.claude.beta.messages.create(
                    model=CLAUDE_MODEL,
                    max_tokens=4096,
                    system=system_prompt,
                    messages=[{"role": "user", "content": user_prompt}],
                    output_config={"effort": "low"},
                    betas=["server-side-fallback-2026-07-01"],
                    fallbacks="default",
                )
            except Exception as e:
                print(f"\033[91mClaude error: {e}\033[0m")
                return original
            if response.stop_reason == "refusal":
                print("\033[91mClaude declined the edit\033[0m")
                return original
            return "".join(b.text for b in response.content if b.type == "text").strip()

        try:
            response = self.client.chat.completions.create(
                model=LLM_MODEL,
                messages=[
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": user_prompt},
                ],
                temperature=0.0,
            )
            return response.choices[0].message.content.strip()
        except Exception as e:
            print(f"\033[91mLLM error: {e}\033[0m")
            return original  # Return original on error

    def start_recording(self, submit=False, edit=False) -> bool:
        """Start recording. Returns True if recording actually started."""
        with self._state_lock:
            if self.recording:
                return False
            if edit and not self.last_typed_text:
                print("\033[91mNo previous text to edit\033[0m", flush=True)
                return False
            # Set recording=True optimistically so debounce/release logic works
            # even while the stream is being opened in the background.
            self.recording = True
            self.audio_data = []
            self.submit_mode = submit
            self.edit_mode = edit
            # Capture active window/app for later focus restoration
            try:
                self.active_app = self.platform.get_active_app()
                if self.active_app:
                    print(f"  [focus] captured: {self.active_app}", flush=True)
            except Exception:
                self.active_app = None
            if edit:
                indicator = "● Recording edit instruction..."
            elif submit:
                indicator = "● Recording (submit)..."
            else:
                indicator = "● Recording..."
            print(f"\033[92m{indicator}\033[0m", flush=True)

        # Open audio stream and run watchdog in a BACKGROUND THREAD — PortAudio
        # can hang if a previous stream didn't close cleanly.  Running this off
        # the pynput listener thread keeps keyboard events (including panic
        # reset) responsive.
        def _open_and_watch():
            import time as _time

            def callback(indata, frames, time, status):
                if status:
                    print(f"Audio status: {status}", flush=True)
                if self.recording:
                    self.audio_data.append(indata.copy())

            stream = None
            for attempt in range(2):
                try:
                    stream = sd.InputStream(
                        samplerate=SAMPLE_RATE,
                        channels=CHANNELS,
                        dtype=np.int16,
                        device=INPUT_DEVICE,
                        callback=callback,
                    )
                    stream.start()
                    break
                except Exception as e:
                    if attempt == 0:
                        print(f"\033[93m⚠ Audio open failed ({e}), resetting PortAudio...\033[0m", flush=True)
                        try:
                            sd.abort()
                        except Exception:
                            pass
                        _time.sleep(0.5)
                    else:
                        print(f"\033[91mAudio error after retry: {e}\033[0m", flush=True)
                        self._force_reset_state()
                        return

            # Assign stream under lock — if recording was already stopped
            # while we were opening, close the stream to avoid leaking it.
            with self._state_lock:
                if not self.recording:
                    try:
                        stream.stop()
                        stream.close()
                    except Exception:
                        pass
                    return
                self.stream = stream

            # Watchdog: safety timeout
            deadline = _time.monotonic() + MAX_RECORDING_SECONDS
            while self.recording:
                if _time.monotonic() >= deadline:
                    try:
                        app = self.platform.get_active_app() or "unknown"
                    except Exception:
                        app = "unknown"
                    print(f"\033[91m⚠ Recording timeout ({MAX_RECORDING_SECONDS}s) — auto-stopping (foreground: {app})\033[0m", flush=True)
                    self.stop_recording()
                    return
                _time.sleep(1)

        threading.Thread(target=_open_and_watch, daemon=True).start()
        return True

    def _force_reset_state(self):
        """Unconditionally reset all recording state. Call when things go wrong."""
        self.recording = False
        self.hotkey_pressed = False
        self.pressed_modifiers.clear()
        if self.stream:
            try:
                self.stream.stop()
            except Exception:
                pass
            try:
                self.stream.close()
            except Exception:
                pass
            self.stream = None

    def _debounced_stop(self, key):
        """Schedule a stop after a grace period; cancelled if the key is re-pressed."""
        self._debounce_generation += 1
        gen = self._debounce_generation
        try:
            app = self.platform.get_active_app() or "unknown"
        except Exception:
            app = "unknown"
        print(f"  [debounce] release detected, waiting {RELEASE_GRACE_SECONDS}s... (foreground: {app})", flush=True)

        def _check():
            import time as _time
            _time.sleep(RELEASE_GRACE_SECONDS)
            # If generation changed, the key was re-pressed — cancel this stop
            if self._debounce_generation != gen:
                print(f"  [debounce] cancelled — key re-pressed, kept recording", flush=True)
                return
            # On macOS, verify the key is actually released at the hardware level.
            # The repeat-suppressor CGEventTap swallows repeat key-downs, which
            # means pynput can miss re-presses and fire spurious on_release events.
            if _IS_MACOS:
                try:
                    import Quartz
                    vk = getattr(key, 'vk', None) or _VK_MAP.get(_key_name)
                    if vk is not None and Quartz.CGEventSourceKeyState(
                        Quartz.kCGEventSourceStateCombinedSessionState, vk
                    ):
                        print(f"  [debounce] key still held (CGEventSource) — ignoring spurious release", flush=True)
                        return
                except Exception:
                    pass  # fall through to normal stop
            # Key is still released — actually stop
            if self.recording:
                print(f"  [debounce] confirmed release — stopping (foreground: {app})", flush=True)
                self.stop_recording()

        threading.Thread(target=_check, daemon=True).start()

    def stop_recording(self):
        with self._state_lock:
            if not self.recording:
                return
            self.recording = False
            self.hotkey_pressed = False  # Always reset so next press works
            stream = self.stream
            self.stream = None
            audio_chunks = self.audio_data  # Capture before next start_recording clears it
            self.audio_data = []
            submit_mode = self.submit_mode
            edit_mode = self.edit_mode
            active_app = self.active_app

        # Close stream outside lock — fire-and-forget in a daemon thread so a
        # hung PortAudio close never blocks transcription or future recordings.
        # If PortAudio is truly stuck, the next start_recording will retry with
        # sd.abort() to force-reset the audio subsystem.
        if stream:
            def _close_stream():
                try:
                    stream.stop()
                except Exception:
                    pass
                try:
                    stream.close()
                except Exception:
                    pass
            threading.Thread(target=_close_stream, daemon=True).start()

        if not audio_chunks:
            print("No audio recorded")
            print("\a\033[1;92m✓ Listening\033[0m", flush=True)
            return

        # Combine audio chunks
        audio = np.concatenate(audio_chunks, axis=0)

        # Check minimum duration
        duration = len(audio) / SAMPLE_RATE
        if duration < MIN_RECORDING_SECONDS:
            print(f"(recording too short: {duration:.1f}s)")
            print("\a\033[1;92m✓ Listening\033[0m", flush=True)
            return

        print("\033[93m◌ Processing...\033[0m", flush=True)

        # Transcribe in background to not block hotkey listener
        threading.Thread(
            target=self._transcribe_and_type, args=(audio, submit_mode, edit_mode, active_app),
            daemon=True,
        ).start()

    def _save_for_recovery(self, audio: np.ndarray):
        """Keep audio that could not be sent, and say so in the focused window."""
        print("\033[91mNo internet connection\033[0m")
        recovery_path = Path("/tmp/voicebar-recovery.wav")
        if recovery_path.exists():
            # Don't overwrite - just remind user to recover first
            msg = "(no internet - say 'recover' first)"
        else:
            with wave.open(str(recovery_path), "wb") as wf:
                wf.setnchannels(CHANNELS)
                wf.setsampwidth(2)
                wf.setframerate(SAMPLE_RATE)
                wf.writeframes(audio.tobytes())
            print(f"Audio saved to {recovery_path}")
            msg = "(no internet - say 'recover' to retry)"
        try:
            self.platform.type_text(msg)
            self.last_typed_text = msg
        except Exception:
            pass

    def _transcribe_and_type(self, audio: np.ndarray, submit: bool = False, edit: bool = False, active_app=None):
        t0 = time.time()
        try:
            # Convert to MP3 if ffmpeg available, otherwise WAV
            if self.has_ffmpeg:
                file_buffer = self._convert_to_mp3(audio)
            else:
                file_buffer = io.BytesIO()
                with wave.open(file_buffer, "wb") as wf:
                    wf.setnchannels(CHANNELS)
                    wf.setsampwidth(2)  # 16-bit
                    wf.setframerate(SAMPLE_RATE)
                    wf.writeframes(audio.tobytes())
                file_buffer.seek(0)
                file_buffer.name = "audio.wav"

            # Transcribe; no connectivity pre-check, a failed request is the check
            try:
                transcript = self.client.audio.transcriptions.create(
                    model=WHISPER_MODEL,
                    file=file_buffer,
                    language=LANGUAGE,
                    prompt=PROMPT,
                    response_format="text",
                    temperature=0.0,
                )
            except self.connection_error:
                self._save_for_recovery(audio)
                return
            t1 = time.time()

            text = transcript.strip()
            if not text:
                print("(no speech detected)")
                return

            # Check for voice commands
            if text.lower() in ("recover", "recover.", "recovery", "recovery."):
                print("Voice command: recover")
                self.recover_audio()
                return

            # Release any stuck modifiers before typing
            self.platform.release_modifiers()

            # Restore focus to the original window (may have changed during API call)
            if active_app:
                print(f"  [focus] restoring: {active_app}", flush=True)
            self.platform.restore_focus(active_app)

            # Clean up stray hotkey characters (e.g. 'j' leaked during hold)
            if _key_name and len(_key_name) == 1:
                self.platform.clear_text(self.stray_key_count)
            self.stray_key_count = 0

            if edit:
                # Edit mode: use transcription as instruction to correct previous text
                instruction = text
                print(f"\033[93m◌ Correcting: {instruction}\033[0m", flush=True)

                corrected = self._correct_with_llm(self.last_typed_text, instruction)
                print(f"\033[94m→ {corrected}\033[0m ({time.time()-t0:.1f}s)", flush=True)

                # Delete the previously typed text
                self.platform.clear_text(grapheme_count(self.last_typed_text))

                # Type corrected text
                self.platform.type_text(corrected)
                self.last_typed_text = corrected
            else:
                # Normal mode: apply replacements and type
                text = apply_replacements(text)

                # Auto-add space if continuing after previous text
                if self.all_typed_text and text:
                    text = " " + text

                print(f"\033[94m→ {text}\033[0m ({t1-t0:.1f}s)", flush=True)

                self.platform.type_text(text)
                self.last_typed_text = text
                self.all_typed_text += text

                # Press Enter if submit mode
                if submit:
                    time.sleep(SUBMIT_DELAY / 1000)
                    self.platform.press_key("Return")
                    self.all_typed_text = ""
        except Exception as e:
            print(f"\033[91mError: {e}\033[0m")
        finally:
            print("\a\033[1;92m✓ Listening\033[0m", flush=True)

    def recover_audio(self):
        """Recover and transcribe audio from a failed attempt."""
        recovery_path = Path("/tmp/voicebar-recovery.wav")
        if not recovery_path.exists():
            print("No recovery file found")
            try:
                self.platform.type_text("(no recovery file)")
            except Exception:
                pass
            return

        # Load audio from recovery file
        with wave.open(str(recovery_path), "rb") as wf:
            audio = np.frombuffer(wf.readframes(wf.getnframes()), dtype=np.int16)

        print(f"Recovering audio from {recovery_path}...")

        # Clear the "no internet" message first
        self.platform.clear_text(grapheme_count(self.last_typed_text))

        # Transcribe in background
        threading.Thread(
            target=self._transcribe_and_type, args=(audio, False, False),
            daemon=True,
        ).start()

        # Remove recovery file
        recovery_path.unlink()

    def on_press(self, key):
        # Track modifier keys (include all hotkey modifiers)
        all_modifiers = HOTKEY_MODIFIERS | SUBMIT_MODIFIERS | EDIT_MODIFIERS | DELETE_MODIFIERS
        if key in all_modifiers:
            self.pressed_modifiers.add(key)

        # Check if delete hotkey is pressed (Cmd+Shift+K)
        if key == DELETE_KEY and _has_all_modifiers(
            self.pressed_modifiers, _delete_modifier_types
        ):
            if self.delete_pressed:
                return  # suppress key repeat
            self.delete_pressed = True
            if self.last_typed_text:
                text_to_delete = self.last_typed_text
                self.last_typed_text = ""
                self.all_typed_text = ""
                print(f"\033[93m✕ Deleting: {text_to_delete}\033[0m", flush=True)
                def _do_delete():
                    import time as _time
                    # Wait for user to release modifier keys
                    _time.sleep(0.3)
                    self.platform.release_modifiers()
                    _time.sleep(0.05)
                    self.platform.clear_text(grapheme_count(text_to_delete))
                threading.Thread(target=_do_delete, daemon=True).start()
            else:
                print("\033[91mNothing to delete\033[0m", flush=True)
            return

        # Panic reset: Cmd+Shift+Esc (macOS) or Ctrl+Shift+Esc (Linux)
        # Restarts the entire process to recover from broken PortAudio state.
        if key == keyboard.Key.esc and _has_all_modifiers(
            self.pressed_modifiers,
            {"super", "shift"} if _IS_MACOS else {"ctrl", "shift"},
        ):
            print("\033[93m⚠ Panic reset — restarting process\033[0m", flush=True)
            sys.stdout.flush()
            sys.stderr.flush()
            os.execv(sys.executable, [sys.executable] + sys.argv)
            os._exit(1)  # fallback if execv fails

        # Check if edit hotkey is pressed (Ctrl+Alt+Space or configured)
        if key == EDIT_KEY and _has_all_modifiers(
            self.pressed_modifiers, _edit_modifier_types
        ):
            if MODE == "toggle":
                if self.recording:
                    self.stop_recording()
                else:
                    self.start_recording(edit=True)
            else:  # hold mode
                self._debounce_generation += 1  # cancel any pending debounced stop
                if not self.hotkey_pressed:
                    if self.start_recording(edit=True):
                        self.hotkey_pressed = True
            return

        # Check if submit hotkey is pressed (Ctrl+Shift+Space or configured)
        if key == SUBMIT_KEY and _has_all_modifiers(
            self.pressed_modifiers, _submit_modifier_types
        ):
            if MODE == "toggle":
                if self.recording:
                    self.stop_recording()
                else:
                    self.start_recording(submit=True)
            else:  # hold mode
                self._debounce_generation += 1  # cancel any pending debounced stop
                if not self.hotkey_pressed:
                    if self.start_recording(submit=True):
                        self.hotkey_pressed = True
            return

        # Check if hotkey combo is pressed (all required modifiers)
        if key == HOTKEY_KEY and _has_all_modifiers(
            self.pressed_modifiers, _required_modifier_types
        ):
            if MODE == "toggle":
                if self.recording:
                    self.stop_recording()
                else:
                    self.start_recording()
            else:  # hold mode
                self._debounce_generation += 1  # cancel any pending debounced stop
                if not self.hotkey_pressed:
                    if self.start_recording():
                        self.hotkey_pressed = True
            return

        # Track stray hotkey characters leaked while recording
        if self.recording and _key_name and len(_key_name) == 1:
            if key == HOTKEY_KEY:
                self.stray_key_count += 1

    def on_release(self, key):
        # Track modifier release
        all_modifiers = HOTKEY_MODIFIERS | SUBMIT_MODIFIERS | EDIT_MODIFIERS | DELETE_MODIFIERS
        if key in all_modifiers:
            self.pressed_modifiers.discard(key)

        # Reset delete key repeat suppression
        if key == DELETE_KEY:
            self.delete_pressed = False

        # In hold mode, stop when hotkey is released — with grace period for finger slips
        if MODE == "hold" and key in (HOTKEY_KEY, SUBMIT_KEY, EDIT_KEY):
            if self.recording:
                self._debounced_stop(key)

    def _setup_repeat_suppressor(self):
        """Suppress auto-repeat key events for hotkey keys on macOS.

        When holding a hotkey (e.g. Cmd+J), the OS generates key repeat events
        that leak characters into terminal apps. This CGEventTap suppresses
        only the repeat events — the initial press and the release pass through
        normally so pynput can still detect them.
        """
        if not _IS_MACOS or not _SUPPRESS_COMBOS:
            return
        try:
            import Quartz
        except ImportError:
            return

        def _run_tap():
            tap_ref = [None]

            def _tap_callback(proxy, event_type, event, refcon):
                if event_type == Quartz.kCGEventTapDisabledByTimeout:
                    if tap_ref[0] is not None:
                        Quartz.CGEventTapEnable(tap_ref[0], True)
                    return event
                keycode = Quartz.CGEventGetIntegerValueField(
                    event, Quartz.kCGKeyboardEventKeycode
                )
                required_flags = _SUPPRESS_COMBOS.get(keycode)
                if required_flags is not None:
                    flags = Quartz.CGEventGetFlags(event)
                    if (flags & required_flags) == required_flags:
                        is_repeat = Quartz.CGEventGetIntegerValueField(
                            event, Quartz.kCGKeyboardEventAutorepeat
                        )
                        if is_repeat:
                            return None  # Suppress repeat — prevents jjjjj
                        # First press: strip Unicode so no character leaks,
                        # but pass the event through so pynput sees the vk.
                        Quartz.CGEventKeyboardSetUnicodeString(event, 0, "")
                        return event
                return event

            tap = Quartz.CGEventTapCreate(
                Quartz.kCGSessionEventTap,
                Quartz.kCGHeadInsertEventTap,
                Quartz.kCGEventTapOptionDefault,
                Quartz.CGEventMaskBit(Quartz.kCGEventKeyDown),
                _tap_callback,
                None,
            )
            if tap is None:
                print("  [suppressor] failed to create event tap", flush=True)
                return
            tap_ref[0] = tap

            source = Quartz.CFMachPortCreateRunLoopSource(None, tap, 0)
            loop = Quartz.CFRunLoopGetCurrent()
            Quartz.CFRunLoopAddSource(loop, source, Quartz.kCFRunLoopCommonModes)
            Quartz.CGEventTapEnable(tap, True)
            print("  [suppressor] hotkey repeat suppression active", flush=True)
            Quartz.CFRunLoopRun()

        threading.Thread(target=_run_tap, daemon=True).start()

    def _setup_wake_listener(self):
        """On macOS, exit on wake from sleep so launchd restarts us.

        This is needed because macOS invalidates Accessibility trust
        tokens after sleep, causing CGEvents to silently fail.
        A fresh process gets a new valid token.
        """
        if sys.platform != "darwin":
            return
        try:
            from AppKit import NSWorkspace, NSWorkspaceDidWakeNotification

            def on_wake(_notification):
                print("System wake detected, waiting for Accessibility restore...", flush=True)
                time.sleep(10)  # wait for macOS to restore Accessibility trust
                print("Restarting...", flush=True)
                os._exit(0)  # launchd KeepAlive will restart us

            center = NSWorkspace.sharedWorkspace().notificationCenter()
            center.addObserverForName_object_queue_usingBlock_(
                NSWorkspaceDidWakeNotification, None, None, on_wake,
            )

            # Pump CFRunLoop on a background thread to receive notifications
            def run_loop():
                from CoreFoundation import CFRunLoopRun
                CFRunLoopRun()  # blocks, no CPU spin

            threading.Thread(target=run_loop, daemon=True).start()
            print("Wake listener active", flush=True)
        except Exception as e:
            print(f"Warning: could not set up wake listener: {e}", flush=True)

    def run(self):
        # Format hotkey names for display
        _key_label = _key_name.capitalize()
        hotkey_str = "+".join(m.capitalize() for m in _required_modifier_types) + f"+{_key_label}"
        submit_str = "+".join(m.capitalize() for m in _submit_modifier_types) + f"+{_key_label}"
        edit_str = "+".join(m.capitalize() for m in _edit_modifier_types) + f"+{_key_label}"
        delete_str = "+".join(m.capitalize() for m in _delete_modifier_types) + f"+{_delete_key_name.upper()}"

        print(f"voicebar started (mode: {MODE}, backend: {BACKEND})")
        print(f"  {hotkey_str}: {'toggle' if MODE == 'toggle' else 'hold to'} record")
        print(f"  {submit_str}: record and submit (press Enter)")
        print(f"  {edit_str}: record correction instruction")
        panic_str = "Cmd+Shift+Esc" if _IS_MACOS else "Ctrl+Shift+Esc"
        print(f"  {delete_str}: delete last transcription")
        print(f"  {panic_str}: panic reset (unstick)")
        print("Press Ctrl+C to exit\n")

        self._setup_wake_listener()
        self._setup_repeat_suppressor()

        listener = keyboard.Listener(
            on_press=self.on_press,
            on_release=self.on_release,
        )
        try:
            listener.start()
        except Exception as e:
            print(f"\033[91mKeyboard listener error: {e}\033[0m")
            if sys.platform == "darwin":
                print("Make sure Accessibility permissions are granted in System Settings.")
            else:
                print("Make sure you're running on X11 with proper permissions.")
            sys.exit(1)

        print("\a\033[1;92m✓ Listening\033[0m", flush=True)

        # First Ctrl+C exits gracefully; second one force-quits
        import signal
        def _force_exit(signum, frame):
            print("\n\033[91mForce quit\033[0m")
            os._exit(1)
        def _graceful_exit(signum, frame):
            signal.signal(signal.SIGINT, _force_exit)
            raise KeyboardInterrupt
        signal.signal(signal.SIGINT, _graceful_exit)

        try:
            while listener.is_alive():
                listener.join(timeout=1)
        except KeyboardInterrupt:
            pass
        finally:
            listener.stop()


def recover():
    """Transcribe the recovery audio file from a failed attempt."""
    recovery_path = Path("/tmp/voicebar-recovery.wav")
    if not recovery_path.exists():
        print("No recovery file found")
        return

    platform = get_platform()
    check_environment(platform)

    # Load audio from recovery file
    with wave.open(str(recovery_path), "rb") as wf:
        audio = np.frombuffer(wf.readframes(wf.getnframes()), dtype=np.int16)

    print(f"Recovering audio from {recovery_path}...")
    recorder = VoiceRecorder(platform)
    recorder._transcribe_and_type(audio, submit=False, edit=False)

    # Remove recovery file after successful transcription
    recovery_path.unlink()
    print("Recovery file removed")


def install_agent():
    """Generate and install macOS LaunchAgent."""
    if sys.platform != "darwin":
        print("LaunchAgent installation is only for macOS.")
        return

    plist_dir = Path.home() / "Library" / "LaunchAgents"
    plist_path = plist_dir / "com.voicebar.agent.plist"
    log_dir = Path.home() / "Library" / "Logs"

    python_path = sys.executable
    script_path = Path(__file__).resolve()

    # The agent reads the API key from config.toml at startup, so the key is
    # never copied into the plist.
    if not CONFIG.get("transcription", {}).get("api_key"):
        print(f"Warning: add api_key to [transcription] in {CONFIG_PATH}; "
              "the agent does not see your shell's environment variables.")

    env_block = """        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>"""

    # Run through /bin/zsh so the process inherits Accessibility permissions
    # (macOS grants permissions to /bin/zsh, not the Python binary)
    plist_content = f"""\
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.voicebar.agent</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/zsh</string>
        <string>-c</string>
        <string>exec {python_path} -u {script_path}</string>
    </array>
    <key>WorkingDirectory</key>
    <string>{script_path.parent}</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>{log_dir}/voicebar.log</string>
    <key>StandardErrorPath</key>
    <string>{log_dir}/voicebar.err</string>
    <key>EnvironmentVariables</key>
    <dict>
{env_block}
    </dict>
</dict>
</plist>
"""
    plist_dir.mkdir(parents=True, exist_ok=True)
    plist_path.write_text(plist_content)
    print(f"Wrote {plist_path}")
    print()
    print("To start now and on every login:")
    print(f"  launchctl bootstrap gui/$(id -u) {plist_path}")
    print()
    print("To restart after changes:")
    print(f"  launchctl kickstart -k gui/$(id -u)/com.voicebar.agent")
    print()
    print("To stop and remove:")
    print(f"  launchctl bootout gui/$(id -u)/com.voicebar.agent")


def uninstall_agent():
    """Remove macOS LaunchAgent."""
    if sys.platform != "darwin":
        print("LaunchAgent uninstallation is only for macOS.")
        return

    plist_path = Path.home() / "Library" / "LaunchAgents" / "com.voicebar.agent.plist"

    # Try to unload first
    uid = os.getuid()
    subprocess.run(
        ["launchctl", "bootout", f"gui/{uid}/com.voicebar.agent"],
        check=False,
        capture_output=True,
    )

    if plist_path.exists():
        plist_path.unlink()
        print(f"Removed {plist_path}")
    else:
        print("LaunchAgent not installed.")


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--install-agent":
        install_agent()
        return

    if len(sys.argv) > 1 and sys.argv[1] == "--uninstall-agent":
        uninstall_agent()
        return

    if len(sys.argv) > 1 and sys.argv[1] == "--recover":
        recover()
        return

    platform = get_platform()
    check_environment(platform)
    recorder = VoiceRecorder(platform)
    try:
        recorder.run()
    except KeyboardInterrupt:
        print("\nExiting...")


if __name__ == "__main__":
    main()
