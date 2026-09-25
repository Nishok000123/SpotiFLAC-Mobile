# Contributing to SpotiFLAC Mobile

Thank you for helping improve SpotiFLAC Mobile. Bug reports, focused pull
requests, documentation, and translations are all welcome.

Please follow the [Code of Conduct](CODE_OF_CONDUCT.md) when participating in
the project.

## Before You Start

- Search the [existing issues](https://github.com/spotiflacapp/SpotiFLAC-Mobile/issues)
  before opening a new one.
- Use the issue template that best matches the problem.
- Keep pull requests focused. Separate unrelated fixes into separate PRs.
- Never commit credentials, signing files, downloaded media, or generated build
  artifacts.

Translations are managed through the
[SpotiFLAC Mobile Crowdin project](https://crowdin.com/project/spotiflac-mobile).
The English source strings live in `lib/l10n/arb/app_en.arb`.

## Toolchain

The repository is the source of truth for tool versions:

- Flutter: `.fvmrc`
- Dart: bundled with the pinned Flutter SDK
- Rust: `rust_backend/rust-toolchain.toml` and `rust_backend/Cargo.lock`
- Android SDK, NDK, and Java: `.github/workflows/ci.yml`
- Xcode: required only for iOS builds

[FVM](https://fvm.app/) is recommended. If you do not use FVM, install the
exact Flutter version declared in `.fvmrc` and replace `fvm flutter` with
`flutter` (and `fvm dart` with `dart`) in the commands below.

## Development Setup

1. Fork and clone the repository:

   ```bash
   git clone https://github.com/YOUR_USERNAME/SpotiFLAC-Mobile.git
   cd SpotiFLAC-Mobile
   git remote add upstream https://github.com/spotiflacapp/SpotiFLAC-Mobile.git
   ```

2. Install the pinned Flutter SDK and Dart dependencies:

   ```bash
   fvm install
   fvm flutter pub get
   ```

3. Install Rust with rustup, then run `(cd rust_backend && rustup show)` to
   activate the pinned toolchain. Install Clang/libclang for the native bindings
   (`libclang-dev` on Ubuntu, Xcode command-line tools on macOS). Android Gradle
   builds the Rust libraries and bindings automatically. For a manual host build,
   run `bash scripts/build_rust_backend.sh host`.

4. Run the app:

   ```bash
   fvm flutter run --dart-define="GIT_COMMIT=$(git rev-parse --short=8 HEAD)"
   ```

For iOS, run `bash scripts/build_ios.sh` on macOS, then `(cd ios && pod install)`
before opening `ios/Runner.xcworkspace`. The application uses the Rust backend.

The About footer shows the short commit supplied through `GIT_COMMIT` at
compile time. The Android build script and iOS release workflow supply it
automatically. Include the same `--dart-define` when running Flutter build
commands directly; without it, the footer shows only the copyright.

Android release builds also require the pinned Discord Social SDK. See
[Discord build setup](DISCORD.md) for local staging and the CI decryption secret.
`bash scripts/build_android.sh` verifies that every release APK contains the
native integration; debug builds can run without the SDK.

## Project Boundaries

```text
lib/          Flutter UI, state, models, and platform orchestration
rust_backend/ Production backend, native bindings, and unit tests
android/      Android platform bridge and foreground worker
ios/          iOS platform bridge and application project
test/         Flutter unit and widget tests
assets/       Images, fonts, and bundled resources
docs/         Local documentation and migration archives (gitignored)
scripts/      Reproducible project build helpers
```

SpotiFLAC Mobile is extension-driven. Extension-specific behavior must be
declared through a generic manifest field, capability, or reusable app API.
Do not add provider-name checks such as `if source == 'provider-name'` to the
main app. The backend should parse and expose the generic declaration, and Dart
should consume that declaration without knowing which extension uses it.

## Generated Files

- After changing ARB files, run `fvm flutter gen-l10n` and commit the resulting
  localization sources.
- Run `fvm dart run build_runner build --delete-conflicting-outputs` only when a
  model or generator input changes, then commit the relevant generated source.
- Do not commit `build/`, `.dart_tool/`, AAR/XCFramework output, IDE state, or
  local research directories.

## Validation

Run checks that cover the code you changed. Before opening a PR, the relevant
commands should pass.

Cross-language lyric usability cases live in
`android/app/src/test/resources/lyrics_usability_cases.tsv`. Dart and Android
tests read the same cases; add a case there when changing
that policy.

Flutter and Dart:

```bash
fvm dart format --output=none --set-exit-if-changed lib test
fvm flutter analyze
fvm flutter test
```

Rust formatting, Clippy, and unit tests:

```bash
bash scripts/check_rust_backend.sh
```

Android native code (Gradle builds the Rust artifacts automatically):

```bash
cd android
./gradlew :app:compileDebugKotlin :app:testDebugUnitTest
```

For user-facing changes, add or update tests where practical and include
before/after screenshots for UI changes.

## Code and Commit Style

- Follow `analysis_options.yaml`, `.editorconfig`, and existing module patterns.
- Keep user-facing strings in the localization files.
- Prefer small functions and explicit error handling at platform boundaries.
- Use [Conventional Commits](https://www.conventionalcommits.org/), for example:

  ```text
  feat(download): add batch selection
  fix(storage): handle revoked folder access
  docs(contributing): refresh Android setup
  ```

## Pull Requests

1. Create a branch from an up-to-date `main`.
2. Make one focused change and include tests or verification evidence.
3. Complete the pull request template, including any checks that were not run
   and why.
4. Link related issues with `Fixes #123` where appropriate.
5. Respond to review feedback with follow-up commits; maintainers may squash
   commits when merging.

When reporting a crash, include the SpotiFLAC Mobile version, release channel,
device/OS, exact reproduction steps, storage mode, and exported app logs. For a
cold-start Android crash, `adb logcat -b crash -d` is especially useful.
