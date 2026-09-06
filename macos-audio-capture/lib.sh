#!/usr/bin/env bash
# Shared helpers for the Voice Memos Audio Capture toolkit.
# Sourced by inspect.sh / setup.sh / verify.sh / rollback.sh / test-capture.sh
# Read-only unless a caller explicitly invokes a mutating function.

MULTI_OUT_NAME="${MULTI_OUT_NAME:-Voice Memos Audio Capture}"
BLACKHOLE_NAME="BlackHole 2ch"
BLACKHOLE_DRIVER="/Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver"
STATE_DIR="${HOME}/.config/voice-memos-audio-capture"
STATE_FILE="${STATE_DIR}/previous-devices.env"

if [ -t 1 ]; then
  BOLD=$'\033[1m'; RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; DIM=$'\033[2m'; OFF=$'\033[0m'
else
  BOLD=""; RED=""; GRN=""; YLW=""; DIM=""; OFF=""
fi

say_head() { printf '\n%s== %s ==%s\n' "$BOLD" "$*" "$OFF"; }
say_ok()   { printf '%s  OK  %s %s\n' "$GRN" "$OFF" "$*"; }
say_warn() { printf '%s WARN %s %s\n' "$YLW" "$OFF" "$*"; }
say_bad()  { printf '%s FAIL %s %s\n' "$RED" "$OFF" "$*"; }
say_info() { printf '%s  ..  %s %s\n' "$DIM" "$OFF" "$*"; }

require_macos() {
  if [ "$(uname -s)" != "Darwin" ]; then
    say_bad "This script only runs on macOS. Detected: $(uname -s)."
    exit 1
  fi
}

# Ask a yes/no question. Returns 0 for yes. Defaults to NO on empty input.
confirm() {
  local prompt="$1" reply=""
  printf '\n%s%s%s [y/N] ' "$BOLD" "$prompt" "$OFF"
  read -r reply </dev/tty || return 1
  case "$reply" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

brew_path() {
  if command -v brew >/dev/null 2>&1; then command -v brew; return 0; fi
  for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [ -x "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
  done
  return 1
}

# Plain-text Core Audio device dump. Read-only, no admin rights needed.
audio_dump() { system_profiler SPAudioDataType 2>/dev/null; }

# Is a device with this exact name known to Core Audio?
device_exists() {
  local name="$1"
  audio_dump | grep -qF "${name}:"
}

have_switchaudio() { command -v SwitchAudioSource >/dev/null 2>&1; }

current_output() { have_switchaudio && SwitchAudioSource -c -t output 2>/dev/null; }
current_input()  { have_switchaudio && SwitchAudioSource -c -t input  2>/dev/null; }

list_outputs() { have_switchaudio && SwitchAudioSource -a -t output 2>/dev/null; }
list_inputs()  { have_switchaudio && SwitchAudioSource -a -t input  2>/dev/null; }

# The Audio MIDI Setup preferences file is where aggregate / multi-output
# devices are persisted. Reading it is harmless; we never write to it.
ams_plist="${HOME}/Library/Preferences/com.apple.audio.AudioMIDISetup.plist"
ams_contains() {
  [ -f "$ams_plist" ] || return 1
  plutil -p "$ams_plist" 2>/dev/null | grep -qF "$1"
}
