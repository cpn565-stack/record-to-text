#!/bin/zsh
set -euo pipefail

# Pin: FFmpeg 9.0 static arm64 from ffmpeg.martin-riedl.de (includes libmp3lame).
# These builds also enable GPL codecs (x264/x265). Suitable for friend / Developer
# Mode distribution, not a notarized LGPL-only official runtime.

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
RUNTIME_DIR="${PROJECT_DIR}/runtime/macos-arm64"
BIN_DIR="${RUNTIME_DIR}/bin"
DOWNLOAD_DIR="${RUNTIME_DIR}/downloads"

FFMPEG_URL="https://ffmpeg.martin-riedl.de/download/macos/arm64/1785863997_9.0/ffmpeg.zip"
FFPROBE_URL="https://ffmpeg.martin-riedl.de/download/macos/arm64/1785863997_9.0/ffprobe.zip"
FFMPEG_SHA256="5267ef149ee0d208057a1b316aac079b661b0476574dee5da7d225769773c603"
FFPROBE_SHA256="7778fbb533fb60d3336cbd9a9e51eced71658f020b570c7203590c1c41d42f50"

mkdir -p "${BIN_DIR}" "${DOWNLOAD_DIR}"

if [[ -x "${BIN_DIR}/ffmpeg" && -x "${BIN_DIR}/ffprobe" ]]; then
  if "${BIN_DIR}/ffmpeg" -hide_banner -encoders 2>/dev/null | grep -q "libmp3lame"; then
    print "Bundled ffmpeg already present at ${BIN_DIR}"
    exit 0
  fi
fi

download_and_verify() {
  local url="$1"
  local sha="$2"
  local dest="$3"
  if [[ ! -f "${dest}" ]]; then
    curl -fL --retry 3 --retry-delay 2 -o "${dest}" "${url}"
  fi
  local actual
  actual="$(shasum -a 256 "${dest}" | awk '{print $1}')"
  if [[ "${actual}" != "${sha}" ]]; then
    print -u2 "Checksum mismatch for ${dest}"
    print -u2 "expected ${sha}"
    print -u2 "actual   ${actual}"
    exit 1
  fi
}

download_and_verify "${FFMPEG_URL}" "${FFMPEG_SHA256}" "${DOWNLOAD_DIR}/ffmpeg.zip"
download_and_verify "${FFPROBE_URL}" "${FFPROBE_SHA256}" "${DOWNLOAD_DIR}/ffprobe.zip"

unzip -o "${DOWNLOAD_DIR}/ffmpeg.zip" -d "${BIN_DIR}"
unzip -o "${DOWNLOAD_DIR}/ffprobe.zip" -d "${BIN_DIR}"
chmod 755 "${BIN_DIR}/ffmpeg" "${BIN_DIR}/ffprobe"

if ! "${BIN_DIR}/ffmpeg" -hide_banner -encoders 2>/dev/null | grep -q "libmp3lame"; then
  print -u2 "Bundled ffmpeg is missing libmp3lame"
  exit 1
fi

print "Fetched bundled ffmpeg/ffprobe into ${BIN_DIR}"
