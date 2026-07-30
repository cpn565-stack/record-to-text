#!/bin/zsh
set -euo pipefail

APP_PATH="${1:-}"
DMG_PATH="${2:-}"
REQUIRE_UNIVERSAL="${REQUIRE_UNIVERSAL:-0}"
ALLOW_UNSIGNED="${ALLOW_UNSIGNED:-0}"
MAX_APP_BYTES="${MAX_APP_BYTES:-104857600}"

if [[ -z "${APP_PATH}" || ! -d "${APP_PATH}" ]]; then
  print -u2 "Usage: $0 <record-to-text.app> [record-to-text.dmg]"
  exit 1
fi

EXECUTABLE="${APP_PATH}/Contents/MacOS/record-to-text"
if [[ ! -x "${EXECUTABLE}" ]]; then
  print -u2 "Missing App executable: ${EXECUTABLE}"
  exit 1
fi

plutil -lint "${APP_PATH}/Contents/Info.plist"
MINIMUM_OS="$(/usr/libexec/PlistBuddy \
  -c "Print :LSMinimumSystemVersion" \
  "${APP_PATH}/Contents/Info.plist")"
if [[ "${MINIMUM_OS}" != 14.* ]]; then
  print -u2 "Expected LSMinimumSystemVersion 14.x; found ${MINIMUM_OS}."
  exit 1
fi

ARCHS="$(lipo -archs "${EXECUTABLE}")"
print "Architectures: ${ARCHS}"

if [[ "${REQUIRE_UNIVERSAL}" == "1" ]]; then
  if [[ "${ARCHS}" != *arm64* || "${ARCHS}" != *x86_64* ]]; then
    print -u2 "Universal build requires both arm64 and x86_64."
    exit 1
  fi
fi

FORBIDDEN="$(find "${APP_PATH}" \
  \( -name '*.safetensors' -o -name '*.bin' -o -name '*.pt' -o -name '*.pth' \) \
  -print)"
if [[ -n "${FORBIDDEN}" ]]; then
  print -u2 "Model weights must not be inside the App bundle:"
  print -u2 "${FORBIDDEN}"
  exit 1
fi

RESOURCE_BUNDLE="${APP_PATH}/Contents/Resources/record-to-text_RecordToTextApp.bundle"
for helper in qwen_asr_mlx_runner.py qwen_asr_transformers_runner.py; do
  if [[ ! -f "${RESOURCE_BUNDLE}/${helper}" ]]; then
    print -u2 "Missing packaged helper resource: ${RESOURCE_BUNDLE}/${helper}"
    exit 1
  fi
done

APP_BYTES="$(du -sk "${APP_PATH}" | awk '{ print $1 * 1024 }')"
if (( APP_BYTES > MAX_APP_BYTES )); then
  print -u2 "App bundle exceeds ${MAX_APP_BYTES} bytes: ${APP_BYTES}"
  exit 1
fi
du -sh "${APP_PATH}"

if [[ "${ALLOW_UNSIGNED}" == "1" ]]; then
  print "Unsigned verification mode: signature, Gatekeeper and stapler checks skipped."
else
  codesign --verify --deep --strict --verbose=2 "${APP_PATH}"
  spctl --assess --type execute --verbose=4 "${APP_PATH}"
  xcrun stapler validate "${APP_PATH}"
fi

if [[ -n "${DMG_PATH}" ]]; then
  if [[ ! -f "${DMG_PATH}" ]]; then
    print -u2 "DMG does not exist: ${DMG_PATH}"
    exit 1
  fi
  if [[ "${ALLOW_UNSIGNED}" != "1" ]]; then
    codesign --verify --verbose=2 "${DMG_PATH}"
    xcrun stapler validate "${DMG_PATH}"
  fi
  shasum -a 256 "${DMG_PATH}"
fi
