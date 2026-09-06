#!/usr/bin/env bash
# Set up "Voice Memos Audio Capture": route app audio to speakers AND BlackHole,
# so Voice Memos records system audio digitally.
#
# Design rules honoured by this script:
#   * Inspect before touching anything.
#   * Never install, never sudo, never restart coreaudiod without asking first.
#   * Never create, modify or delete an audio device that this script did not create.
#   * Every mutation is followed by a verification step.
set -uo pipefail
cd "$(dirname "$0")" && . ./lib.sh
require_macos

printf '%sVoice Memos Audio Capture - setup%s\n' "$BOLD" "$OFF"
printf 'Target: app audio -> "%s" -> speakers (you hear it)\n' "$MULTI_OUT_NAME"
printf '                              -> BlackHole 2ch -> Voice Memos records it\n'

########################################
say_head "Step 1/6 - Inspect current configuration"
########################################
./inspect.sh || true

if ! confirm "Continue with setup?"; then
  echo "Stopped. Nothing was changed."; exit 0
fi

########################################
say_head "Step 2/6 - Record current settings for rollback"
########################################
mkdir -p "$STATE_DIR"
if have_switchaudio; then
  {
    echo "# Saved by setup.sh on $(date)"
    echo "PREV_OUTPUT=$(printf '%q' "$(current_output)")"
    echo "PREV_INPUT=$(printf '%q' "$(current_input)")"
  } > "$STATE_FILE"
  say_ok "Saved previous defaults to ${STATE_FILE}"
  say_info "Output was: $(current_output)"
  say_info "Input was:  $(current_input)"
else
  { echo "# Saved by setup.sh on $(date)"; echo "# SwitchAudioSource absent; defaults not captured."; } > "$STATE_FILE"
  say_warn "Could not capture defaults automatically."
  say_info "Note them yourself now: System Settings > Sound > Output / Input."
fi

########################################
say_head "Step 3/6 - BlackHole 2ch"
########################################
if device_exists "$BLACKHOLE_NAME" || [ -d "$BLACKHOLE_DRIVER" ]; then
  say_ok "BlackHole 2ch is already installed - skipping installation."
else
  say_warn "BlackHole 2ch is not installed."
  if bp="$(brew_path)"; then
    say_info "Homebrew is available; the cask 'blackhole-2ch' is the cleanest route."
    cat <<'WHY'

  Why this needs your administrator password:
    BlackHole is a Core Audio HAL plug-in. It installs to
    /Library/Audio/Plug-Ins/HAL/, a system-wide directory, so the .pkg
    installer requires admin rights. It is NOT a kernel extension, it does
    not require disabling SIP, and it does not lower any security setting.
    Uninstalling is a single brew command (see rollback.sh).

WHY
    if confirm "Run: brew install --cask blackhole-2ch  (will prompt for your password)"; then
      "$bp" install --cask blackhole-2ch || { say_bad "Installation failed."; exit 1; }
    else
      echo "Declined. Cannot continue without BlackHole."; exit 0
    fi
  else
    cat <<'NOBREW'

  Homebrew is not installed on this Mac.

  You do NOT need it. Either option below works; pick on other grounds.

    1. Install BlackHole directly from the signed installer  [simplest]
         https://github.com/ExistentialAudio/BlackHole/releases
       Download the latest BlackHole2ch-X.X.X.pkg, open it, then re-run this
       script. Uninstalling later is one command, because BlackHole is a
       single bundle in a single directory:
         sudo rm -rf /Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver

    2. Install Homebrew first (https://brew.sh), then re-run this script.
       Worth it only if you want Homebrew anyway. It is a large install
       (it pulls in Xcode Command Line Tools) for one small driver. What it
       buys here: 'brew uninstall --cask blackhole-2ch' instead of the rm
       above, and the optional switchaudio-osx helper that lets these
       scripts set the default devices for you instead of you clicking
       through System Settings.

  This script will NOT install Homebrew for you without you asking.

NOBREW
    exit 0
  fi

  say_info "Verifying installation..."
  if [ -d "$BLACKHOLE_DRIVER" ]; then
    say_ok "Driver installed at ${BLACKHOLE_DRIVER}"
  else
    say_bad "Driver not found after install. Stopping."; exit 1
  fi
fi

# The driver is on disk. Core Audio only loads HAL plug-ins when its daemon
# starts, so a freshly installed driver may not be enumerated yet. This applies
# equally to a .pkg install done outside this script, so it lives out here
# rather than inside the install branch above.
if ! device_exists "$BLACKHOLE_NAME"; then
  say_warn "Core Audio has not picked up the driver yet."
  cat <<'CAD'

  Core Audio loads HAL plug-ins when its daemon starts. To make BlackHole
  appear without rebooting, the daemon must be restarted:

      sudo killall coreaudiod

  What this does: stops the Core Audio daemon; launchd restarts it within a
  second. All audio cuts out briefly and playing apps may need to be
  restarted. It needs sudo because coreaudiod runs as root. It is not
  destructive and changes no settings. Rebooting achieves the same thing.

CAD
  if confirm "Restart coreaudiod now?"; then
    sudo killall coreaudiod || say_warn "killall returned non-zero (daemon may have already restarted)."
    sleep 3
  else
    say_warn "Skipped. Reboot before continuing, then re-run this script."; exit 0
  fi
fi

if device_exists "$BLACKHOLE_NAME"; then
  say_ok "VERIFIED: Core Audio recognises \"${BLACKHOLE_NAME}\""
else
  say_bad "Core Audio still does not list BlackHole 2ch. Reboot and re-run."; exit 1
fi

########################################
say_head "Step 4/6 - Multi-Output Device"
########################################
if device_exists "$MULTI_OUT_NAME"; then
  say_ok "\"${MULTI_OUT_NAME}\" already exists - not recreating or modifying it."
else
  cat <<EOSTEP

  ${BOLD}This step genuinely cannot be done from the command line.${OFF}

  macOS ships no supported command-line tool for creating a Multi-Output
  Device. Audio MIDI Setup builds them through a private Core Audio
  aggregate-device key; there is no documented CLI, no 'defaults' key that
  creates one safely, and no AppleScript dictionary for Audio MIDI Setup.
  Rather than invent an unsupported command, here are the minimum GUI steps.

  ${BOLD}In Audio MIDI Setup (opening for you now):${OFF}

   1. Click the ${BOLD}+${OFF} button at the bottom-left, choose
      ${BOLD}Create Multi-Output Device${OFF}.
   2. In the device list on the right, tick ${BOLD}exactly two${OFF} boxes:
        - your normal physical output (MacBook Speakers, AirPods, headphones)
        - ${BOLD}BlackHole 2ch${OFF}
   3. Set your ${BOLD}physical output${OFF} as the primary/clock device: drag it to the
      ${BOLD}top${OFF} of the list, or select it in the "Primary Device" (a.k.a. Master
      Device) menu. The clock should be real hardware, not BlackHole.
   4. Tick ${BOLD}Drift Correction${OFF} on the ${BOLD}BlackHole 2ch${OFF} row only. Leave it OFF for
      the primary device - correcting the clock master is what causes drift.
   5. Confirm both rows show the ${BOLD}same sample rate${OFF} (48000 Hz is a safe choice).
      Fix any mismatch under each device's Format menu first.
   6. Double-click the new device's name in the left sidebar and rename it to
      exactly:  ${BOLD}${MULTI_OUT_NAME}${OFF}

  Existing aggregate or multi-output devices: leave them alone. This script
  will not touch them.

EOSTEP
  if confirm "Open Audio MIDI Setup now?"; then
    open -a "Audio MIDI Setup" || say_warn "Could not launch Audio MIDI Setup; open it from /Applications/Utilities."
  fi
  printf '\n%sPress Return once you have created and renamed the device...%s ' "$BOLD" "$OFF"
  read -r _ </dev/tty || true
fi

say_info "Verifying..."
if device_exists "$MULTI_OUT_NAME"; then
  say_ok "VERIFIED: Core Audio recognises \"${MULTI_OUT_NAME}\""
  : > "${STATE_DIR}/created-multi-output"   # marker: rollback may delete this device
  echo "$MULTI_OUT_NAME" > "${STATE_DIR}/created-multi-output"
else
  say_bad "\"${MULTI_OUT_NAME}\" not found. Check the exact spelling of the name."
  say_info "Names are case- and space-sensitive. Re-run when it is correct."
  exit 1
fi

########################################
say_head "Step 5/6 - Route system audio and recording input"
########################################
if ! have_switchaudio; then
  say_warn "SwitchAudioSource is not installed."
  cat <<'SW'

  macOS provides no supported command for setting the default audio device.
  'switchaudio-osx' is a small, widely used Homebrew formula that does it
  (and makes rollback a single command). It is optional - you can set both
  devices by hand in System Settings instead.

SW
  if bp="$(brew_path)" && confirm "Install it? (brew install switchaudio-osx)"; then
    "$bp" install switchaudio-osx || say_warn "Install failed; falling back to manual steps."
  fi
fi

if have_switchaudio; then
  SwitchAudioSource -t output -s "$MULTI_OUT_NAME" >/dev/null 2>&1 \
    && say_ok "Default OUTPUT set to \"${MULTI_OUT_NAME}\"" \
    || say_bad "Could not set default output."
  SwitchAudioSource -t input  -s "$BLACKHOLE_NAME" >/dev/null 2>&1 \
    && say_ok "Default INPUT set to \"${BLACKHOLE_NAME}\"" \
    || say_bad "Could not set default input."
else
  cat <<EOM

  ${BOLD}Set these two by hand:${OFF}
    System Settings > Sound > ${BOLD}Output${OFF} -> ${MULTI_OUT_NAME}
    System Settings > Sound > ${BOLD}Input${OFF}  -> ${BLACKHOLE_NAME}
  (Shortcut: Option-click the sound icon in the menu bar / Control Center.)

EOM
  printf '%sPress Return when done...%s ' "$BOLD" "$OFF"; read -r _ </dev/tty || true
fi

########################################
say_head "Step 6/6 - Verify"
########################################
./verify.sh
