#!/bin/zsh
# Local release-machine integration test. Uses cached Parakeet models and system TTS;
# CI does not download the ~650 MB model bundle.
emulate -L zsh
set -euo pipefail

DIR="${0:A:h:h}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

run_probe() {
  local audio="$1" expected="$2" gain="${3:-1}"
  swift run -c release DictationModelProbe "$audio" "$expected" "$gain"
}

FINAL_AUDIO="$TMP_DIR/final-words.aiff"
/usr/bin/say -v Samantha -r 185 -o "$FINAL_AUDIO" \
  "Command dictation must keep every phrase, including the final words bright yellow lantern."

AUDIO_BYTES="$(/usr/bin/afinfo "$FINAL_AUDIO" | awk '/audio bytes:/ { print $3; exit }')"
if [[ -z "$AUDIO_BYTES" || "$AUDIO_BYTES" -le 0 ]]; then
  print -u2 "dictation fixture generation failed: macOS say produced no audio"
  exit 2
fi

PAUSE_AUDIO="$TMP_DIR/pause-final-words.aiff"
/usr/bin/say -v Samantha -r 185 -o "$PAUSE_AUDIO" \
  "Keep everything before this pause. [[slnc 1000]] Then retain the ending cobalt compass."

QUIET_AUDIO="$TMP_DIR/quiet-final-words.aiff"
/usr/bin/say -v Samantha -r 170 -o "$QUIET_AUDIO" \
  "Quiet dictation still needs the final phrase silver shoreline."

cd "$DIR/agent"
run_probe "$FINAL_AUDIO" "bright yellow lantern"
run_probe "$PAUSE_AUDIO" "cobalt compass"
run_probe "$QUIET_AUDIO" "silver shoreline" "0.18"
