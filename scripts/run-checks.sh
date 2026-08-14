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
swift build "${SWIFT_ARGS[@]}" --product record-to-text-self-test

swift run "${SWIFT_ARGS[@]}" record-to-text-self-test

"${PROJECT_DIR}/scripts/build-app.sh"

print "✅ 全部驗證通過！"
