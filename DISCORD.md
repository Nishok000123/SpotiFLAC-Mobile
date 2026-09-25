# Discord Rich Presence builds

SpotiFLAC uses the official Discord Social SDK **1.10.19337** on Android.
The integration was inspired by [@itsmegaaa's contribution](https://github.com/spotiflacapp/SpotiFLAC-Mobile/pull/576)
and [issue #575](https://github.com/spotiflacapp/SpotiFLAC-Mobile/issues/575).
It publishes through the installed, signed-in Discord Android client. It does
not collect a Discord user token. iOS support is not implemented.

## Local release builds

Download the standalone C++ archive from the
[Discord Developer Portal](https://discord.com/developers/applications/select/social-sdk/downloads)
for your SDK-enabled application, then stage it once:

```bash
python3 scripts/prepare_discord_sdk.py --archive /path/to/DiscordSocialSdk-1.10.19337.zip
```

An already extracted SDK works too:

```bash
python3 scripts/prepare_discord_sdk.py --source-dir /path/to/discord_social_sdk
```

The helper verifies pinned SHA-256 checksums and stages only the Android release
AAR and license notices under `.dart_tool/discord-sdk/1.10.19337`. Do not commit
unencrypted SDK binaries or the decryption key. Use the repository's pinned
Flutter, Java, NDK and CMake versions:

```bash
fvm exec bash scripts/build_android.sh --target lib/main.dart
```

Both split APKs and the universal APK are checked for the Discord JNI library,
SDK library, surviving JNI/SDK classes in DEX, correct ARM ELF architectures,
and license notices. Release builds fail if the SDK is missing. Debug builds
without the SDK remain available for contributor development.

## CI and releases

The Android-only archive is stored at
`third_party/discord/discord-android-1.10.19337.zip.gpg`, encrypted with GnuPG
AES-256. Set the repository Actions secret **`DISCORD_SDK_PASSPHRASE`** to its
decryption key. This follows GitHub's documented
[large-secret storage pattern](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-secrets#storing-large-secrets),
so releases need no external hosting or expiring portal download URL.

CI and Release use the same preparation action to decrypt the archive with
GnuPG (included on Ubuntu runners), verify both pinned file checksums, and
export `SPOTIFLAC_DISCORD_SDK_DIR` before Gradle runs. The key is passed over
standard input to GnuPG and is never printed or put in its command arguments.
Missing keys, failed decryption, and checksum failures stop the build.
Gradle caches are limited to public dependency downloads; transformed SDK
binaries are not saved in the shared Actions cache.
The release workflow rechecks the final signed APKs before uploading them.
Fork PRs, which cannot access repository secrets, run debug/native validation
without generating release APKs.

The archive contains only `lib/release/discord_partner_sdk.aar` and
`License-Notices.txt`. To update the SDK, obtain the official archive, update
the pinned version/checksums in the preparation helper and Gradle cache path,
and encrypt a new Android-only ZIP using `gpg --symmetric --cipher-algo AES256`.
Keep the passphrase outside the checkout and save it in Actions secrets;
never add it to Git, workflow logs, or build artifacts.

## Verification

```bash
python3 -m unittest discover -s scripts -p 'test_prepare_discord_sdk.py'
python3 -m unittest discover -s scripts -p 'test_check_backend_apk.py'
fvm flutter test test/discord_presence_service_test.dart
```

`DiscordPresenceTest` exercises the real SDK lifecycle on an Android emulator
without Discord installed. This proves native loading and callback handling;
visible presence still needs testing on a device with a signed-in Discord
client, including playback, seeking, pausing, and disabling the feature.
