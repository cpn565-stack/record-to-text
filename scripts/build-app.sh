#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
source "${PROJECT_DIR}/Config/version.env"
CONFIGURATION="${CONFIGURATION:-debug}"
VERSION="${VERSION:-${MARKETING_VERSION}}"
BUILD_NUMBER="${BUILD_NUMBER:-${DEFAULT_BUILD_NUMBER}}"
UNIVERSAL="${UNIVERSAL:-0}"
ADHOC_SIGN="${ADHOC_SIGN:-1}"
BUILD_DIR="${PROJECT_DIR}/.build"
DIST_DIR="${PROJECT_DIR}/dist"
APP_PATH="${DIST_DIR}/record-to-text.app"

cd "${PROJECT_DIR}"

"${SCRIPT_DIR}/check-version.sh"

export SWIFTPM_MODULECACHE_OVERRIDE="${BUILD_DIR}/ModuleCache"
export CLANG_MODULE_CACHE_PATH="${BUILD_DIR}/ModuleCache"

SWIFT_ARGS=(
  --disable-sandbox
  --scratch-path "${BUILD_DIR}"
  --configuration "${CONFIGURATION}"
)

if [[ "${UNIVERSAL}" == "1" ]]; then
  SWIFT_ARGS+=(--arch arm64 --arch x86_64)
fi

swift build "${SWIFT_ARGS[@]}" --product record-to-text
BIN_DIR="$(swift build "${SWIFT_ARGS[@]}" --show-bin-path)"
EXECUTABLE="${BIN_DIR}/record-to-text"

if [[ ! -x "${EXECUTABLE}" ]]; then
  print -u2 "Build succeeded but executable is missing: ${EXECUTABLE}"
  exit 1
fi

rm -rf "${APP_PATH}"
mkdir -p "${APP_PATH}/Contents/MacOS" "${APP_PATH}/Contents/Resources"
ditto "${EXECUTABLE}" "${APP_PATH}/Contents/MacOS/record-to-text"
ditto "${PROJECT_DIR}/Config/Info.plist" "${APP_PATH}/Contents/Info.plist"

/usr/libexec/PlistBuddy \
  -c "Set :CFBundleShortVersionString ${VERSION}" \
  "${APP_PATH}/Contents/Info.plist"
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleVersion ${BUILD_NUMBER}" \
  "${APP_PATH}/Contents/Info.plist"

if [[ -f "${PROJECT_DIR}/Config/AppIcon.icns" ]]; then
  ditto "${PROJECT_DIR}/Config/AppIcon.icns" \
    "${APP_PATH}/Contents/Resources/AppIcon.icns"
fi

for resource_bundle in "${BIN_DIR}"/*RecordToTextApp*.bundle(N); do
  ditto "${resource_bundle}" \
    "${APP_PATH}/Contents/Resources/${resource_bundle:t}"
done

"${SCRIPT_DIR}/fetch-bundled-ffmpeg.sh"
HELPERS_DIR="${APP_PATH}/Contents/Helpers"
mkdir -p "${HELPERS_DIR}"
ditto "${PROJECT_DIR}/runtime/macos-arm64/bin/ffmpeg" "${HELPERS_DIR}/ffmpeg"
ditto "${PROJECT_DIR}/runtime/macos-arm64/bin/ffprobe" "${HELPERS_DIR}/ffprobe"
chmod 755 "${HELPERS_DIR}/ffmpeg" "${HELPERS_DIR}/ffprobe"

if [[ "${ADHOC_SIGN}" == "1" ]]; then
  codesign --force --sign - "${HELPERS_DIR}/ffmpeg"
  codesign --force --sign - "${HELPERS_DIR}/ffprobe"
  codesign --force --sign - "${APP_PATH}"
fi

print "Built ${APP_PATH}"
