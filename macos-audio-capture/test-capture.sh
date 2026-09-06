#!/usr/bin/env bash
# Functional test: prove Voice Memos is recording the digital system-audio
# stream and not the room through a microphone.
#
# The discriminator: BlackHole receives the stream from the Multi-Output Device
# regardless of how loud the physical speakers are. Silence the speakers and the
# room has nothing to record - so anything that lands in the memo arrived
# digitally. This is what makes the test conclusive rather than suggestive.
set -uo pipefail
cd "$(dirname "$0")" && . ./lib.sh
require_macos

TMP="$(mktemp -d -t vmcapture)"
trap 'rm -rf "$TMP"' EXIT
PHRASE="Digital capture test. If you can hear this in the memo, system audio routing works."
TONE="${TMP}/test-tone.aiff"

say_head "Preparing test audio"
if say -o "$TONE" "$PHRASE" 2>/dev/null && [ -s "$TONE" ]; then
  say_ok "Generated spoken test file (a distinctive phrase, easy to recognise)"
else
  TONE="/System/Library/Sounds/Submarine.aiff"
  say_warn "Falling back to system sound: ${TONE}"
fi

########################################
say_head "Optional: objective check with ffmpeg (no Voice Memos needed)"
########################################
# If ffmpeg is present we can record straight off BlackHole and measure the
# peak level. This isolates the routing from anything Voice Memos does.
if command -v ffmpeg >/dev/null 2>&1; then
  idx="$(ffmpeg -hide_banner -f avfoundation -list_devices true -i "" 2>&1 \
        | awk '/AVFoundation audio devices/{a=1;next} a && /BlackHole 2ch/{gsub(/[^0-9]/,"",$2); print $2; exit}')"
  if [ -n "${idx:-}" ]; then
    say_info "BlackHole is avfoundation audio device index ${idx}. Recording 6s..."
    ( sleep 1; afplay "$TONE"; sleep 1; afplay "$TONE" ) &
    player=$!
    ffmpeg -hide_banner -loglevel error -f avfoundation -i ":${idx}" -t 6 "${TMP}/probe.wav" </dev/null
    wait "$player" 2>/dev/null || true
    peak="$(ffmpeg -hide_banner -i "${TMP}/probe.wav" -af volumedetect -f null - 2>&1 \
            | awk -F': ' '/max_volume/{print $2; exit}')"
    say_info "Peak level captured from BlackHole: ${peak:-unknown}"
    case "${peak:-}" in
      "-91"*|"-inf"*|"") say_bad "BlackHole captured silence - audio is not reaching it. See troubleshooting." ;;
      *)                 say_ok "Signal present on BlackHole. Digital routing is working." ;;
    esac
  else
    say_warn "ffmpeg did not list BlackHole 2ch as an input device."
  fi
else
  say_info "ffmpeg not installed - skipping. (Optional: brew install ffmpeg)"
fi

########################################
say_head "Voice Memos test"
########################################
cat <<EOM

  ${BOLD}Make the room silent first${OFF} - this is what makes the test conclusive.
  Pick one:

    (a) Open Audio MIDI Setup, select "${MULTI_OUT_NAME}", and drag the
        volume slider on your ${BOLD}physical output row${OFF} down to zero.
        BlackHole still receives the full-level stream.
    (b) Wear headphones, so nothing plays into the room at all.

  Then:
    1. Open Voice Memos and press ${BOLD}record${OFF}.
    2. Come back here and press Return - the test phrase will play twice.
    3. Stop the recording in Voice Memos and play it back.

  ${BOLD}Reading the result:${OFF}
    - You hear the phrase clearly, with no room echo or background noise
        -> system audio is being captured digitally. Success.
    - The memo is silent
        -> see "Silent recordings" in README.md.
    - You hear the phrase but muffled, with room tone or handling noise
        -> you are still recording a microphone. Input is not set to
           BlackHole 2ch, or Voice Memos was already open when you changed it
           (quit and reopen it - it binds the input device at launch).

EOM
printf '%sPress Return once Voice Memos is recording...%s ' "$BOLD" "$OFF"
read -r _ </dev/tty || true

say_info "Playing test audio..."
afplay "$TONE"; sleep 0.5; afplay "$TONE"
say_ok "Playback finished. Stop the recording in Voice Memos and listen back."

printf '\n%sRemember to restore the physical output volume in Audio MIDI Setup\nif you zeroed it for this test.%s\n' "$BOLD" "$OFF"
