#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
BUILD_DIR="${PROJECT_DIR}/.build"

cd "${PROJECT_DIR}"

export SWIFTPM_MODULECACHE_OVERRIDE="${BUILD_DIR}/ModuleCache"
export CLANG_MODULE_CACHE_PATH="${BUILD_DIR}/ModuleCache"

PYTHON_BIN="${PYTHON_BIN:-python3}"

"${PROJECT_DIR}/scripts/check-version.sh"
"${PROJECT_DIR}/scripts/repo-hygiene.sh"

"${PYTHON_BIN}" -B Tests/qwen_asr_chunking_test.py
"${PYTHON_BIN}" -B Tests/qwen_asr_mlx_runner_test.py

SWIFT_ARGS=(
  --disable-sandbox
  --scratch-path "${BUILD_DIR}"
)

swift build "${SWIFT_ARGS[@]}" --target RecordToTextCore
swift build "${SWIFT_ARGS[@]}" --product record-to-text
swift build "${SWIFT_ARGS[@]}" --product record-to-text-self-test
swift build "${SWIFT_ARGS[@]}" --product record-to-text-mock-helper
swift build "${SWIFT_ARGS[@]}" --product record-to-text-pipeline-self-test

swift run "${SWIFT_ARGS[@]}" record-to-text-self-test

PIPELINE_SELF_TEST="${BUILD_DIR}/debug/record-to-text-pipeline-self-test"
PIPELINE_SCENARIOS=(
  default
  failure
  slow
  segmented
  sliced
  segmented-failure
  segmented-middle-failure
  segmented-blank
  segmented-token-limit
  segmented-no-completed
)

for scenario in "${PIPELINE_SCENARIOS[@]}"; do
  if [[ "${scenario}" == "default" ]]; then
    "${PIPELINE_SELF_TEST}"
  else
    RECORD_TO_TEXT_MOCK_SCENARIO="${scenario}" "${PIPELINE_SELF_TEST}"
  fi
done

if xcodebuild -version >/dev/null 2>&1; then
  swift test "${SWIFT_ARGS[@]}"
elif [[ "${REQUIRE_XCTEST:-0}" == "1" ]]; then
  print -u2 "FAIL swift test: full Xcode is required when REQUIRE_XCTEST=1."
  exit 1
else
  print "SKIP swift test: full Xcode is not available; Python, executable, and pipeline tests passed."
fi

if [[ "${SKIP_APP_BUNDLE:-0}" == "1" ]]; then
  print "SKIP App bundle build: SKIP_APP_BUNDLE=1"
else
  "${PROJECT_DIR}/scripts/build-app.sh"
fi

git diff --check

print "✅ 全部驗證通過！"
