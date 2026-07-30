#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
CONFIGURATION="${CONFIGURATION:-debug}"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
UNIVERSAL="${UNIVERSAL:-0}"
ADHOC_SIGN="${ADHOC_SIGN:-1}"
BUILD_DIR="${PROJECT_DIR}/.build"
DIST_DIR="${PROJECT_DIR}/dist"
APP_PATH="${DIST_DIR}/record-to-text.app"

cd "${PROJECT_DIR}"

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

for resource_bundle in "${BIN_DIR}"/*RecordToTextApp*.bundle(N); do
  ditto "${resource_bundle}" \
    "${APP_PATH}/Contents/Resources/${resource_bundle:t}"
done

if [[ "${ADHOC_SIGN}" == "1" ]]; then
  codesign --force --sign - "${APP_PATH}"
fi

print "Built ${APP_PATH}"
