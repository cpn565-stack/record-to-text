#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
cd "${PROJECT_DIR}"

REPOSITORY_FILES=()
for repository_file in ${(0)"$(git ls-files -z; git ls-files --others --exclude-standard -z)"}; do
  if [[ -f "${repository_file}" ]]; then
    REPOSITORY_FILES+=("${repository_file}")
  fi
done

FORBIDDEN_TRACKED="$(print -rl -- "${REPOSITORY_FILES[@]}" | rg \
  '(^|/)(__pycache__|DerivedData)(/|$)|\.pyc$|^scripts/(apply|fix)-gemini-3\.7-|^\.github/workflows/apply-gemini-3\.7-hardening\.yml$' \
  || true)"
if [[ -n "${FORBIDDEN_TRACKED}" ]]; then
  print -u2 "Generated or one-off migration files are tracked:"
  print -u2 "${FORBIDDEN_TRACKED}"
  exit 1
fi

TRACKED_BYTES=0
for repository_file in "${REPOSITORY_FILES[@]}"; do
  FILE_BYTES="$(stat -f '%z' "${repository_file}")"
  (( TRACKED_BYTES += FILE_BYTES ))
done
MAX_TRACKED_BYTES="${MAX_TRACKED_BYTES:-10485760}"
if (( TRACKED_BYTES > MAX_TRACKED_BYTES )); then
  print -u2 "Tracked repository payload exceeds ${MAX_TRACKED_BYTES} bytes: ${TRACKED_BYTES}"
  exit 1
fi

print "Repository hygiene OK: ${TRACKED_BYTES} tracked bytes"
