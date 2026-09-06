#!/usr/bin/env bash
# Read-only inspection of the Mac's audio configuration.
# Changes nothing. Requires no admin rights. Safe to run at any time.
set -uo pipefail
cd "$(dirname "$0")" && . ./lib.sh
require_macos

say_head "System"
say_info "macOS $(sw_vers -productVersion) (build $(sw_vers -buildVersion))"
say_info "Hardware: $(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown)"
say_info "System Integrity Protection: $(csrutil status 2>/dev/null | sed 's/^System Integrity Protection status: //')"

say_head "Homebrew"
if bp="$(brew_path)"; then
  say_ok "Homebrew found at ${bp}"
else
  say_warn "Homebrew not installed."
  say_info "setup.sh will explain why it is needed and ask before installing anything."
fi

say_head "BlackHole 2ch"
if [ -d "$BLACKHOLE_DRIVER" ]; then
  say_ok "Driver present: ${BLACKHOLE_DRIVER}"
  ver="$(defaults read "${BLACKHOLE_DRIVER}/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo unknown)"
  say_info "Bundle version: ${ver}"
else
  say_warn "Driver not found at ${BLACKHOLE_DRIVER}"
fi
if device_exists "$BLACKHOLE_NAME"; then
  say_ok "Core Audio recognises \"${BLACKHOLE_NAME}\""
else
  say_warn "Core Audio does not currently list \"${BLACKHOLE_NAME}\""
fi

say_head "Multi-Output Device \"${MULTI_OUT_NAME}\""
if device_exists "$MULTI_OUT_NAME"; then
  say_ok "Exists and is visible to Core Audio"
elif ams_contains "$MULTI_OUT_NAME"; then
  say_warn "Referenced in Audio MIDI Setup preferences but not currently active"
else
  say_warn "Does not exist yet (setup.sh will walk you through creating it)"
fi

say_head "Existing aggregate / multi-output devices (left untouched)"
if [ -f "$ams_plist" ]; then
  found="$(plutil -p "$ams_plist" 2>/dev/null | grep -oE '"name" => "[^"]*"' | sed 's/"name" => //' | sort -u)"
  if [ -n "$found" ]; then
    printf '%s\n' "$found" | while IFS= read -r n; do say_info "$n"; done
    say_info "None of these will be modified or deleted by this toolkit."
  else
    say_info "No user-created aggregate or multi-output devices found."
  fi
else
  say_info "No Audio MIDI Setup preferences file yet."
fi

say_head "Current default devices"
if have_switchaudio; then
  say_info "Output: $(current_output)"
  say_info "Input:  $(current_input)"
else
  say_warn "SwitchAudioSource not installed - cannot read defaults from the CLI."
  say_info "macOS ships no supported command for reading or setting the default"
  say_info "audio device. setup.sh will offer to install switchaudio-osx (a small"
  say_info "Homebrew formula) or fall back to System Settings instructions."
fi

say_head "All Core Audio devices"
audio_dump | sed -n 's/^ \{8\}\([A-Za-z0-9].*\):$/  \1/p' | sort -u

say_head "Sample rates"
say_info "BlackHole and your physical output MUST share a sample rate."
say_info "Check both in Audio MIDI Setup > Format (48000 Hz is a good default)."

printf '\n%sInspection complete. Nothing was changed.%s\n' "$BOLD" "$OFF"
