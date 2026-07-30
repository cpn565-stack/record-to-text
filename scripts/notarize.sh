#!/bin/zsh
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  print "Usage: NOTARY_PROFILE=<notarytool-keychain-profile> $0 <app-or-dmg>"
  exit 0
fi

ARTIFACT="${1:-}"
PROFILE="${NOTARY_PROFILE:-}"

if [[ -z "${ARTIFACT}" || ! -e "${ARTIFACT}" ]]; then
  print -u2 "Provide an existing app or DMG."
  exit 1
fi
if [[ -z "${PROFILE}" ]]; then
  print -u2 "NOTARY_PROFILE is required; configure it with xcrun notarytool store-credentials."
  exit 1
fi

SUBMISSION="${ARTIFACT}"
TEMPORARY_ZIP=""
TEMPORARY_DIR=""
if [[ "${ARTIFACT}" == *.app ]]; then
  TEMPORARY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/record-to-text-notary.XXXXXX")"
  TEMPORARY_ZIP="${TEMPORARY_DIR}/submission.zip"
  trap 'rm -rf "${TEMPORARY_DIR}"' EXIT
  ditto -c -k --keepParent "${ARTIFACT}" "${TEMPORARY_ZIP}"
  SUBMISSION="${TEMPORARY_ZIP}"
fi

xcrun notarytool submit "${SUBMISSION}" \
  --keychain-profile "${PROFILE}" \
  --wait
xcrun stapler staple "${ARTIFACT}"
xcrun stapler validate "${ARTIFACT}"
