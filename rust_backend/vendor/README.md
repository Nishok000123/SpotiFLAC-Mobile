# Rustix Android compatibility patch

`rustix-1.1.4` is vendored from the pinned crates.io package using `cargo vendor`.
Its upstream license files are retained. Cargo's workspace patch applies to both
direct users and transitive dependencies such as `cap-std`.
The original package checksum is
`b6fe4565b9518b83ef4f91bb47ce29620ca828bd32cb7e408f0062e9930ba190`.

The sole upstream source change is in `src/backend/libc/fs/syscalls.rs`: Android
uses `weakcall!` for `statx`, rather than `weak_or_syscall!`. Bionic exports this
function from API 30. On earlier releases, probing the raw syscall can terminate
the app with `SIGSYS/SYS_SECCOMP` instead of returning an error (observed on
Android 10 ARM32, syscall 397 during `read_audio_metadata`). Missing symbols now
return `ENOSYS`, allowing the existing `fstat64`/`fstatat64` fallback. Newer Android
continues to use Bionic's `statx`; non-Android targets retain upstream behavior.

References:
- [Bionic stat.h](https://android.googlesource.com/platform/bionic/+/refs/heads/main/libc/include/sys/stat.h)
- [Upstream Rustix](https://github.com/bytecodealliance/rustix)

When upgrading Rustix, check whether upstream has fixed this path before removing
the patch. Keep the Android metadata smoke test and verify both APK ABIs.

Run `bash scripts/check_android_statx.sh arm64-v8a` (or `armeabi-v7a`) with
`ANDROID_NDK_HOME` set and a matching Android device connected through `adb`.
The isolated test executable checks regular metadata access, then hides the libc
symbol and blocks the raw syscall to exercise the legacy fallback. A final probe
deliberately exits with `SIGSYS` to verify that the filter is active. Neither the
symbol wrapper nor the filter is included in the application. This simulated
sandbox check complements testing the APK on an actual older ARM32 device.
