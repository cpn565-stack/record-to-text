#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
VERSION_FILE="${PROJECT_DIR}/Config/version.env"
INFO_PLIST="${PROJECT_DIR}/Config/Info.plist"

if [[ ! -f "${VERSION_FILE}" ]]; then
  print -u2 "Missing version source: ${VERSION_FILE}"
  exit 1
fi

source "${VERSION_FILE}"

if [[ ! "${MARKETING_VERSION:-}" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  print -u2 "MARKETING_VERSION must use x.y.z: ${MARKETING_VERSION:-missing}"
  exit 1
fi
if [[ ! "${DEFAULT_BUILD_NUMBER:-}" =~ '^[0-9]+$' ]]; then
  print -u2 "DEFAULT_BUILD_NUMBER must be numeric: ${DEFAULT_BUILD_NUMBER:-missing}"
  exit 1
fi

PLIST_VERSION="$(/usr/libexec/PlistBuddy \
  -c 'Print :CFBundleShortVersionString' "${INFO_PLIST}")"
PLIST_BUILD="$(/usr/libexec/PlistBuddy \
  -c 'Print :CFBundleVersion' "${INFO_PLIST}")"

if [[ "${PLIST_VERSION}" != "0.0.0" ]]; then
  print -u2 "Info.plist must keep the build-time version placeholder 0.0.0."
  exit 1
fi
if [[ "${PLIST_BUILD}" != "0" ]]; then
  print -u2 "Info.plist must keep the build-time build placeholder 0."
  exit 1
fi

if [[ -n "${GITHUB_REF_NAME:-}" && "${GITHUB_REF_TYPE:-}" == "tag" ]]; then
  if [[ "${GITHUB_REF_NAME}" != "v${MARKETING_VERSION}" ]]; then
    print -u2 "Tag ${GITHUB_REF_NAME} does not match v${MARKETING_VERSION}."
    exit 1
  fi
fi

print "Version contract OK: ${MARKETING_VERSION} (${DEFAULT_BUILD_NUMBER})"
