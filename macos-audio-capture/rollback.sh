#!/usr/bin/env bash
# Restore normal Mac audio.
#
# Tiered, least-destructive first:
#   Tier 1 (default)  - put the default output/input back. Nothing is deleted.
#   Tier 2 (--remove-device) - also delete the Multi-Output Device, but ONLY if
#                       setup.sh created it (verified via a marker file).
#   Tier 3 (--uninstall-blackhole) - also uninstall BlackHole via Homebrew.
#
# Tier 1 alone fully restores normal audio. The rest is optional cleanup.
set -uo pipefail
cd "$(dirname "$0")" && . ./lib.sh
require_macos

REMOVE_DEVICE=0
UNINSTALL_BH=0
for arg in "$@"; do
  case "$arg" in
    --remove-device)        REMOVE_DEVICE=1 ;;
    --uninstall-blackhole)  REMOVE_DEVICE=1; UNINSTALL_BH=1 ;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) say_bad "Unknown option: $arg"; exit 2 ;;
  esac
done

########################################
say_head "Tier 1 - Restore default audio devices"
########################################
PREV_OUTPUT=""; PREV_INPUT=""
# shellcheck disable=SC1090
[ -f "$STATE_FILE" ] && . "$STATE_FILE"

if have_switchaudio; then
  if [ -n "$PREV_OUTPUT" ]; then
    SwitchAudioSource -t output -s "$PREV_OUTPUT" >/dev/null 2>&1 \
      && say_ok "Output restored to \"${PREV_OUTPUT}\"" \
      || say_warn "Could not restore \"${PREV_OUTPUT}\" (device may be disconnected)."
  else
    say_warn "No saved output device. Pick one manually:"
    list_outputs | sed 's/^/       /'
  fi

  if [ -n "$PREV_INPUT" ] && [ "$PREV_INPUT" != "$BLACKHOLE_NAME" ]; then
    SwitchAudioSource -t input -s "$PREV_INPUT" >/dev/null 2>&1 \
      && say_ok "Input restored to \"${PREV_INPUT}\"" \
      || say_warn "Could not restore \"${PREV_INPUT}\"."
  else
    for mic in "MacBook Pro Microphone" "MacBook Air Microphone" "MacBook Microphone" "Built-in Microphone"; do
      if SwitchAudioSource -t input -s "$mic" >/dev/null 2>&1; then
        say_ok "Input set to \"${mic}\""; break
      fi
    done
  fi
  say_info "Now: output=$(current_output)  input=$(current_input)"
else
  cat <<EOM

  SwitchAudioSource is not installed, so set these by hand:
    System Settings > Sound > ${BOLD}Output${OFF} -> your speakers or headphones
    System Settings > Sound > ${BOLD}Input${OFF}  -> MacBook Microphone
  (Shortcut: Option-click the sound icon in Control Center.)

EOM
fi

say_ok "Normal audio is restored. Your volume keys work again."

########################################
if [ "$REMOVE_DEVICE" -eq 1 ]; then
say_head "Tier 2 - Remove the Multi-Output Device"
  marker="${STATE_DIR}/created-multi-output"
  if [ ! -f "$marker" ]; then
    say_warn "No marker file - setup.sh did not record creating \"${MULTI_OUT_NAME}\"."
    say_info "Refusing to remove a device this toolkit did not create. Delete it"
    say_info "yourself in Audio MIDI Setup if you are sure it is the right one."
  else
    cat <<EOM

  macOS has no supported command for deleting an aggregate or multi-output
  device, so this is a GUI step (30 seconds):

    1. Open ${BOLD}Audio MIDI Setup${OFF} (/Applications/Utilities).
    2. Select ${BOLD}${MULTI_OUT_NAME}${OFF} in the left sidebar.
       ${BOLD}Check the name carefully${OFF} - do not delete any other device.
    3. Click the ${BOLD}-${OFF} button at the bottom-left.

EOM
    if confirm "Open Audio MIDI Setup now?"; then
      open -a "Audio MIDI Setup" || say_warn "Open it from /Applications/Utilities."
      printf '\n%sPress Return when removed...%s ' "$BOLD" "$OFF"; read -r _ </dev/tty || true
    fi
    if device_exists "$MULTI_OUT_NAME"; then
      say_warn "\"${MULTI_OUT_NAME}\" still exists."
    else
      say_ok "\"${MULTI_OUT_NAME}\" removed."
      rm -f "$marker"
    fi
  fi
fi

########################################
if [ "$UNINSTALL_BH" -eq 1 ]; then
say_head "Tier 3 - Uninstall BlackHole 2ch"
  if bp="$(brew_path)"; then
    cat <<'WHY'

  This runs: brew uninstall --cask blackhole-2ch
  It removes /Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver, which lives in a
  system directory, so it needs your administrator password. Nothing else is
  touched. Any other app configured to use BlackHole will lose that device.

WHY
    if confirm "Uninstall BlackHole 2ch?"; then
      "$bp" uninstall --cask blackhole-2ch && say_ok "BlackHole uninstalled."
      say_info "Reboot (or 'sudo killall coreaudiod') to clear it from Core Audio."
    else
      say_info "Skipped. BlackHole stays installed - it is inert unless selected."
    fi
  else
    say_warn "Homebrew not found. Remove manually with:"
    say_info "sudo rm -rf ${BLACKHOLE_DRIVER}   # then reboot"
  fi
fi

########################################
say_head "Done"
say_info "Re-running ./setup.sh restores the capture configuration at any time."
