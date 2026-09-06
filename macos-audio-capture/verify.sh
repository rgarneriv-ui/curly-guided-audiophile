#!/usr/bin/env bash
# Verify the Voice Memos Audio Capture routing. Read-only; changes nothing.
set -uo pipefail
cd "$(dirname "$0")" && . ./lib.sh
require_macos

fails=0

say_head "1. BlackHole driver installed"
if [ -d "$BLACKHOLE_DRIVER" ]; then
  say_ok "$BLACKHOLE_DRIVER"
else
  say_bad "Driver missing."; fails=$((fails+1))
fi

say_head "2. Core Audio recognises BlackHole 2ch"
if device_exists "$BLACKHOLE_NAME"; then
  say_ok "\"${BLACKHOLE_NAME}\" is enumerated by Core Audio"
else
  say_bad "Not enumerated. Restart coreaudiod or reboot."; fails=$((fails+1))
fi

say_head "3. Multi-Output Device exists"
if device_exists "$MULTI_OUT_NAME"; then
  say_ok "\"${MULTI_OUT_NAME}\" exists"
else
  say_bad "\"${MULTI_OUT_NAME}\" not found."; fails=$((fails+1))
fi

say_head "4. Multi-Output membership, clock and drift correction"
say_info "Core Audio does not expose sub-device membership to the command line,"
say_info "so confirm these four things by eye in Audio MIDI Setup:"
printf '     [ ] Exactly two devices ticked: your physical output + BlackHole 2ch\n'
printf '     [ ] Physical output is the primary/clock device (top of the list)\n'
printf '     [ ] Drift Correction ticked on BlackHole 2ch ONLY\n'
printf '     [ ] Both rows show the same sample rate (e.g. 48000 Hz)\n'
if ams_contains "$MULTI_OUT_NAME"; then
  say_ok "Device is persisted in Audio MIDI Setup preferences (survives reboot)"
else
  say_warn "Not found in Audio MIDI Setup preferences; it may not persist."
fi

say_head "5. Default output device"
if have_switchaudio; then
  out="$(current_output)"
  if [ "$out" = "$MULTI_OUT_NAME" ]; then
    say_ok "Output = ${out}"
  else
    say_bad "Output = ${out:-unknown} (expected \"${MULTI_OUT_NAME}\")"; fails=$((fails+1))
  fi
else
  say_warn "Install switchaudio-osx to check automatically."
  say_info "Manual check: System Settings > Sound > Output = ${MULTI_OUT_NAME}"
fi

say_head "6. Default input device (this is what Voice Memos records)"
if have_switchaudio; then
  in="$(current_input)"
  if [ "$in" = "$BLACKHOLE_NAME" ]; then
    say_ok "Input = ${in}"
  else
    say_bad "Input = ${in:-unknown} (expected \"${BLACKHOLE_NAME}\")"; fails=$((fails+1))
  fi
else
  say_warn "Install switchaudio-osx to check automatically."
  say_info "Manual check: System Settings > Sound > Input = ${BLACKHOLE_NAME}"
fi

say_head "7. Voice Memos microphone permission"
say_info "Voice Memos reaches BlackHole through the microphone privacy gate, even"
say_info "though no real microphone is involved. If its first recording is silent,"
say_info "check System Settings > Privacy & Security > Microphone > Voice Memos."

say_head "Result"
if [ "$fails" -eq 0 ]; then
  say_ok "All automated checks passed."
  printf '\nNow run the functional test - static checks cannot prove audio is\nactually flowing:\n\n    ./test-capture.sh\n\n'
else
  say_bad "${fails} check(s) failed. Fix the above, then re-run ./verify.sh"
  exit 1
fi
