#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
BUILD_DIR="${PROJECT_DIR}/.build"

cd "${PROJECT_DIR}"

export SWIFTPM_MODULECACHE_OVERRIDE="${BUILD_DIR}/ModuleCache"
export CLANG_MODULE_CACHE_PATH="${BUILD_DIR}/ModuleCache"

SWIFT_ARGS=(
  --disable-sandbox
  --scratch-path "${BUILD_DIR}"
)

swift build "${SWIFT_ARGS[@]}" --target RecordToTextCore
swift build "${SWIFT_ARGS[@]}" --product record-to-text
swift build "${SWIFT_ARGS[@]}" --product record-to-text-mock-helper
swift build "${SWIFT_ARGS[@]}" --product record-to-text-pipeline-self-test

swift run "${SWIFT_ARGS[@]}" record-to-text-self-test
"${BUILD_DIR}/debug/record-to-text-pipeline-self-test"
RECORD_TO_TEXT_MOCK_SCENARIO=failure \
  "${BUILD_DIR}/debug/record-to-text-pipeline-self-test"
RECORD_TO_TEXT_MOCK_SCENARIO=slow \
  "${BUILD_DIR}/debug/record-to-text-pipeline-self-test"

if xcodebuild -version >/dev/null 2>&1; then
  swift test "${SWIFT_ARGS[@]}"
elif [[ "${REQUIRE_XCTEST:-0}" == "1" ]]; then
  print -u2 "FAIL swift test: full Xcode is required when REQUIRE_XCTEST=1."
  exit 1
else
  print "SKIP swift test: full Xcode is not available; executable self-tests passed."
fi
