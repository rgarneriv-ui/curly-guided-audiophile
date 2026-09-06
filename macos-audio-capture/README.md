# Voice Memos Audio Capture

Record audio playing from any macOS app directly into **Voice Memos** — digitally,
with no microphone involved — while still hearing it through your speakers or
headphones.

```
Browser / Music / any app
        │
        ▼
┌──────────────────────────────┐
│ "Voice Memos Audio Capture"  │   Multi-Output Device
│      (system output)         │
└───────┬──────────────┬───────┘
        │              │
        ▼              ▼
  Speakers /      BlackHole 2ch  ──►  system default INPUT  ──►  Voice Memos
  headphones                          (a virtual cable)
  (you hear it)                       (records the same stream)
```

> **Scope note.** These scripts must run **on the Mac being configured**. They were
> authored in a Linux cloud container, so they are syntax-checked but have not been
> executed on macOS. Every step verifies itself as it runs and stops on failure, and
> `inspect.sh` changes nothing — start there.

## Quick start

```bash
cd macos-audio-capture
./inspect.sh      # read-only: what's installed, what's routed where
./setup.sh        # the whole thing, asking before anything privileged
./test-capture.sh # prove the recording is digital, not the room
./rollback.sh     # back to normal audio
```

| Script | Changes anything? | Needs admin? |
|---|---|---|
| `inspect.sh` | no | no |
| `verify.sh` | no | no |
| `setup.sh` | yes, with confirmation at each point | only to install BlackHole |
| `test-capture.sh` | no | no |
| `rollback.sh` | yes | only with `--uninstall-blackhole` |

## What gets changed

1. **BlackHole 2ch installed** (`brew install --cask blackhole-2ch`) — a Core Audio
   HAL plug-in at `/Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver`. Not a kernel
   extension. No SIP change, no security setting touched.
2. **A Multi-Output Device named `Voice Memos Audio Capture`** — created by you in
   Audio MIDI Setup (see below), containing your physical output + BlackHole 2ch.
3. **Default output** → `Voice Memos Audio Capture`.
4. **Default input** → `BlackHole 2ch`.
5. **`~/.config/voice-memos-audio-capture/`** — your previous device names, saved
   so rollback can restore them.

Optionally `switchaudio-osx` (to set defaults from the CLI) and `ffmpeg` (for the
objective level test). Both optional; both plain Homebrew formulas.

Nothing else is modified. **Existing aggregate and multi-output devices are never
touched** — `rollback.sh` refuses to delete any device without a marker file
proving `setup.sh` created it.

## The one step that cannot be scripted

**Creating the Multi-Output Device requires Audio MIDI Setup.** macOS ships no
supported command-line tool for this. Audio MIDI Setup builds multi-output devices
through a private Core Audio aggregate-device key; there is no documented CLI, no
`defaults` key that creates one safely, and Audio MIDI Setup has no AppleScript
dictionary. Rather than invent a command that doesn't exist, `setup.sh` opens the
app and walks you through it:

1. **+** button (bottom-left) → **Create Multi-Output Device**
2. Tick **exactly two** devices: your physical output, and **BlackHole 2ch**
3. Make the **physical output** the primary/clock device — drag it to the top of
   the list. The clock must be real hardware, never BlackHole.
4. Tick **Drift Correction** on **BlackHole 2ch only**. Leave it off for the
   primary device — drift-correcting the clock master is what *causes* drift.
5. Confirm both rows show the **same sample rate** (48000 Hz is a safe default)
6. Rename the device to exactly **`Voice Memos Audio Capture`**

Deleting it later is likewise a GUI step (select it, click **−**).

## Voice Memos has no input selector

Voice Memos exposes no microphone or input-device menu on macOS. **It records
whatever the system default input device is.** That is the whole answer:

> **System Settings → Sound → Input → BlackHole 2ch**

Two things that catch people out:

- **Quit and reopen Voice Memos** after changing the input. It binds the device at
  launch and won't pick up a change made while it's running.
- **Voice Memos still needs Microphone permission**, even though no microphone is
  involved — BlackHole is presented to apps as a recording device and goes through
  the same privacy gate. System Settings → Privacy & Security → Microphone.

Also worth setting: **Settings → Voice Memos → Audio Quality → Lossless**. The
default is compressed, which is a waste when the source is a clean digital stream.

## Volume: what actually controls the recorded level

This trips up nearly everyone, so it's worth being precise.

**The Input Volume slider does nothing here.** BlackHole is a pass-through virtual
cable, not a mic preamp — it hands over the exact samples it was given. Under
System Settings → Sound → Input the slider will be greyed out or simply have no
audible effect. There is no gain to adjust, and nothing to fix by dragging it.

**Your volume keys stop working**, and that's expected. macOS provides no master
volume control for a Multi-Output Device, so F11/F12 show the "no entry" symbol
while one is selected. This is the main day-to-day cost of the setup.

So the level that lands in the recording comes from:

| Control | Affects what you hear | Affects the recording |
|---|---|---|
| System volume keys | inert (multi-output) | no |
| Input Volume slider | — | **no** |
| Physical output slider in Audio MIDI Setup | **yes** | no |
| BlackHole slider in Audio MIDI Setup | no | **yes** — leave at max |
| The source app's own volume (YouTube, Spotify…) | yes | **yes** |

**In practice: set the source app's volume to ~100% and control your listening
level with the physical output's slider in Audio MIDI Setup.** That gives a
full-scale recording and comfortable speakers, independently.

This independence is also what makes the test in `test-capture.sh` conclusive:
zero the physical output, and the room falls silent while BlackHole still receives
the full-level stream. Anything that reaches the memo got there digitally.

## Rollback

```bash
./rollback.sh                          # restore normal output/input — that's it
./rollback.sh --remove-device          # also delete the Multi-Output Device
./rollback.sh --uninstall-blackhole    # also uninstall BlackHole
```

Plain `./rollback.sh` is the one that matters — it restores your saved devices and
your volume keys. Everything else is optional cleanup: an unselected BlackHole and
an unused Multi-Output Device sit inert and cost nothing. Re-run `./setup.sh` to
switch back to capture mode any time.

No-scripts version: **System Settings → Sound → Output →** your speakers;
**Input →** MacBook Microphone.

## Troubleshooting

**No audio at all.** Almost always a sample-rate mismatch. Open Audio MIDI Setup
and set BlackHole and your physical output to the *same* rate (48000 Hz), then
re-select the Multi-Output Device. If it persists, `sudo killall coreaudiod` —
this stops the Core Audio daemon, which launchd restarts within a second; audio
cuts out briefly and playing apps may need restarting. It changes no settings.

**Voice Memos records silence.**
- Input isn't BlackHole → System Settings → Sound → Input → BlackHole 2ch
- Voice Memos was open when you changed it → quit and reopen it
- Missing permission → Privacy & Security → Microphone → Voice Memos
- Output isn't the Multi-Output Device → audio never reaches BlackHole
- BlackHole's slider in Audio MIDI Setup is down → set it to maximum

**The memo has room noise / echo.** You're recording a real microphone. The input
device didn't take — recheck it, and reopen Voice Memos.

**Doubled or echoing audio.** Something is monitoring BlackHole back to your
speakers. Check that no other app (Loopback, OBS, a DAW, Music's audio device) is
playing BlackHole's input through an output. Also confirm the Multi-Output Device
contains *exactly two* devices — a third, or your physical output listed twice,
produces a phasey doubling.

**Drift: audio slowly desynchronising, clicks, glitches.**
- Drift Correction must be **on for BlackHole, off for the primary device**
- The primary/clock device must be **physical hardware**, not BlackHole
- On Bluetooth (AirPods): Bluetooth clocks drift badly and can't be the reliable
  master. Prefer built-in speakers or wired headphones as the primary device while
  recording; add AirPods as an extra sub-device with drift correction on.

**Volume keys don't work.** Expected — see the volume section above. Adjust the
physical output's slider in Audio MIDI Setup, or run `./rollback.sh` when you're
done recording.

**BlackHole doesn't appear after installing.** Core Audio loads HAL plug-ins at
daemon start: `sudo killall coreaudiod`, or reboot.

## Safety

- No kernel extensions, no SIP changes, no security settings reduced.
- `sudo` is used in exactly two places — installing and uninstalling BlackHole,
  both of which write to the system-wide `/Library/Audio/Plug-Ins/HAL/`. Each is
  explained before it runs and requires confirmation.
- Homebrew is never installed automatically; if it's missing, `setup.sh` explains
  why it helps and offers a direct-installer alternative instead.
- Nothing is deleted that the toolkit didn't create.
