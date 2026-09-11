#!/usr/bin/env bash
# Sets up a machine to build Overload. Installs what it safely can with Homebrew,
# checks the rest, and prints the manual steps. Safe to re-run. See req.txt.
set -uo pipefail

cd "$(dirname "$0")/.."
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }

TODO=()

echo "== Toolchain =="

if ! have brew; then
  bad "Homebrew missing. Install from https://brew.sh, then re-run this script."
  exit 1
fi
ok "Homebrew $(brew --version | head -1 | awk '{print $2}')"

if have git; then ok "git $(git --version | awk '{print $3}')"; else
  echo "  installing git..."; brew install git >/dev/null && ok "git installed" || bad "git install failed"
fi
if have node; then ok "node $(node -v | tr -d v) / npm $(npm -v)"; else
  echo "  installing node..."; brew install node >/dev/null && ok "node installed" || bad "node install failed"
fi

if have java; then
  ok "java $(java -version 2>&1 | head -1 | cut -d'"' -f2)"
else
  warn "Java 17 missing (needed for Android builds)"
  TODO+=("brew install --cask temurin@17")
fi

if have flutter; then
  ok "flutter $(flutter --version 2>/dev/null | head -1 | awk '{print $2}')"
else
  bad "Flutter missing"
  TODO+=("Install Flutter 3.41.9+: https://docs.flutter.dev/get-started/install")
fi

echo
echo "== Platforms =="

if [ -d "${ANDROID_HOME:-$HOME/Library/Android/sdk}" ]; then
  ok "Android SDK at ${ANDROID_HOME:-$HOME/Library/Android/sdk}"
  [ -d "${ANDROID_HOME:-$HOME/Library/Android/sdk}/cmdline-tools" ] \
    || { warn "cmdline-tools missing (Android builds fail without it)"
         TODO+=("Android Studio > SDK Manager > SDK Tools > Android SDK Command-line Tools")
         TODO+=("flutter doctor --android-licenses"); }
else
  warn "Android SDK missing"
  TODO+=("brew install --cask android-studio, then install SDK 36 + build-tools 36.0.0 + cmdline-tools + NDK 28.2.13676358")
fi

if xcodebuild -version >/dev/null 2>&1; then
  ok "Xcode $(xcodebuild -version | head -1 | awk '{print $2}')"
  have pod && ok "CocoaPods $(pod --version)" || { warn "CocoaPods missing"; TODO+=("brew install cocoapods"); }
else
  warn "Xcode not fully installed (iOS builds unavailable)"
  TODO+=("Install Xcode from the App Store, then: sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer && sudo xcodebuild -runFirstLaunch")
fi

echo
echo "== Project =="

if [ -f app/config/dev.json ]; then
  ok "app/config/dev.json present"
else
  cp app/config/dev.example.json app/config/dev.json
  warn "created app/config/dev.json from the example — fill in your Supabase values"
  TODO+=("Edit app/config/dev.json: SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY (Supabase > Project Settings > API)")
  TODO+=("Apply the schema: npx supabase login && npx supabase link --project-ref YOUR-REF && npx supabase db push")
fi

if have flutter; then
  echo "  running flutter pub get..."
  (cd app && flutter pub get >/dev/null 2>&1) && ok "packages installed" || bad "flutter pub get failed"
  echo "  generating Drift code..."
  (cd app && dart run build_runner build >/dev/null 2>&1) && ok "code generated" || bad "build_runner failed"
  echo "  running tests..."
  (cd app && flutter test >/dev/null 2>&1) && ok "tests pass" || bad "tests failed — run 'cd app && flutter test' to see why"
fi

echo
if [ ${#TODO[@]} -eq 0 ]; then
  echo "Ready. Run:  cd app && flutter run --dart-define-from-file=config/dev.json"
else
  echo "Still to do by hand:"
  for item in "${TODO[@]}"; do echo "  - $item"; done
  echo
  echo "Details for all of these are in req.txt."
fi
