# Direct USB audio

Android USB host transport for local FLAC/WAV PCM and uncompressed DSF/DSDIFF.
The existing Android 14 preferred-mixer path remains available. Direct USB is
opt-in under Settings > Library > Playback > USB bit-perfect audio.

## Ownership and playback

- Android asks for USB permission; the engine, not the Activity, owns the
  connection. Permission denial and absent hardware leave PCM on normal output.
- One Rust worker owns libusb, its claimed interfaces, four isochronous output
  transfers, and a separate explicit-feedback transfer. The bounded queue holds
  approximately 200 ms of audio (minimum 256 KiB). There is no resampling or gain.
- UAC1 fixed rates are verified from descriptors; variable UAC1/UAC2 rates are
  read back from the endpoint/clock. Implicit feedback, ambiguous clocks, and
  multiple configurations fail closed. Endpoint capacities bound packet sizes.
- Fractional rates and 10.14/16.16 feedback determine packet lengths. Completed
  data frames advance position; silence inserted during an underrun does not.
- Every native transfer is cancelled and acknowledged before its memory is
  freed. The worker joins before Android closes the original USB descriptor.
  Interfaces are released and the kernel driver reattached automatically.
- Pause/seek discard queued audio and reopen the decoder position at the last
  completed frame. Disconnect pauses playback; it never redirects active USB
  playback to the speaker. Pending permission requests can be cancelled by Next.
- ReplayGain, AutoMix, software volume and playback-rate processing are bypassed
  while USB mode is selected. Volume is controlled at the DAC.

## DSD

`DsdFile.kt` normalizes DSF channel blocks/LSB ordering and DFF byte-interleaved
MSB data without loading the file into memory. Native U32 uses the device's
byte ordering. DoP uses 24-bit words, left-aligned when carried in 32-bit slots.
The transport assigns alternating 05/FA markers across all frames, including
inserted DSD silence. Seeking retains channel/frame alignment.

Native DSD initially recognizes these exact USB identities and alternate
settings; no product-name match or assumption that PCM support implies DSD:

| VID:PID | Alternate | Firmware | Encoding |
| --- | --- | --- | --- |
| 16d0:071a (Amanero Combo384) | 2 | 0199 | U32 LE |
| 16d0:071a (Amanero Combo384) | 2 | 019b, 0203 | U32 BE |
| 2772:0230 (Pro-Ject Pre Box S2 Digital) | 2 | any | U32 BE |
| 20b1:3089 (Mola-Mola) | 2 | any | U32 BE |

DoP is a separate opt-in for a DAC explicitly known to support it; USB audio
descriptors do not announce DoP support. Keep it disabled for ordinary USB
headsets. Unsupported DSD is stopped rather than interpreted as PCM audio.
WavPack DSD, DST compression, DSD-to-PCM conversion and vendor DAP outputs are not
implemented. SAF scanning reads basic DSD format/duration and uses the filename
for metadata; embedded DSD artwork/tags are not yet imported.

## Verification

- Rust descriptor/clock tests: UAC1 and UAC2 fixtures, malformed data, exact
  native-DSD identity matching, precision rejection, fractional rates/feedback.
- JVM tests: DSF padding/bit order, DFF channel order, native LE/BE, DoP layout,
  seeking, truncated containers and compressed-DST rejection.
- Android instrumentation: absent USB fallback, real native FFI error cleanup,
  and integer WAV decode/seek after the original SAF descriptor is closed.
- Flutter tests: opt-in settings, transport options, cancellation, stale replies,
  DSD failure without PCM fallback, existing playback/queue/DSP behavior.

Physical PCM/DoP/native-DSD output, DAC lock indication, hardware volume and long
playback stability still require real USB hardware. Host tests, emulator tests
and successful ARM32/ARM64 builds do not establish DAC compatibility.

## Reference and dependencies

USB identity/format facts were checked against
[Linux USB audio quirks](https://github.com/torvalds/linux/blob/master/sound/usb/quirks.c).
The Android-only `libusb1-sys` dependency builds its unmodified bundled libusb;
license texts and rebuild information are in `assets/licenses/usb.txt` and in
the app's license registry. No additional audio SDK or decoder library is added.
