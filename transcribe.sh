#!/bin/bash
# Usage: transcribe.sh <meeting-dir>
# Turns me.m4a / others.m4a into transcript.md with local whisper.cpp.
# If speakers.json exists (voices separated by the app), "others" is transcribed turn by turn.
set -euo pipefail

DIR="$1"
HERE="$(cd "$(dirname "$0")" && pwd)"
MODELS="${MEETREC_MODELS:-$HOME/.meetrec/models}"
MODEL="${MEETREC_MODEL:-$MODELS/ggml-large-v3-turbo-q5_0.bin}"
VAD="$MODELS/ggml-silero-v5.1.2.bin"
LANGUAGE="${MEETREC_LANG:-auto}"
WHISPER="$(command -v whisper-cli || echo /opt/homebrew/bin/whisper-cli)"

vad_args=()
[ -f "$VAD" ] && vad_args=(--vad --vad-model "$VAD")

to_wav() { afconvert -f WAVE -d LEI16@16000 -c 1 "$DIR/$1.m4a" "$DIR/$1.wav"; }

# Your mic: one speaker, whole file.
if [ -f "$DIR/me.m4a" ]; then
  echo "== me"
  to_wav me
  "$WHISPER" -m "$MODEL" -f "$DIR/me.wav" -l "$LANGUAGE" -oj -of "$DIR/me" -np -ml 120 -sow \
    ${vad_args[@]+"${vad_args[@]}"}
  rm -f "$DIR/me.wav"
fi

if [ -f "$DIR/others.m4a" ]; then
  echo "== others"
  to_wav others
  if [ -f "$DIR/speakers.json" ]; then
    # Short chunks detect language poorly, so pick one language for the whole meeting:
    # the mic track's (it's already transcribed), else detect on the others track.
    lang="$LANGUAGE"
    if [ "$lang" = "auto" ] && [ -f "$DIR/me.json" ]; then
      lang=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['result']['language'])" "$DIR/me.json" 2>/dev/null || true)
    fi
    if [ -z "$lang" ] || [ "$lang" = "auto" ]; then
      lang=$("$WHISPER" -m "$MODEL" -f "$DIR/others.wav" -l auto -dl 2>&1 \
             | sed -n 's/.*auto-detected language: \([a-z]*\).*/\1/p' | head -1)
    fi
    lang="${lang:-auto}"
    echo "meeting language: $lang"
    chunks=()
    while IFS= read -r f; do chunks+=(-f "$f"); done < <(python3 "$HERE/turns.py" split "$DIR")
    if [ ${#chunks[@]} -gt 0 ]; then
      "$WHISPER" -m "$MODEL" -l "$lang" -oj -np "${chunks[@]}"
    fi
    python3 "$HERE/turns.py" collect "$DIR"
    rm -rf "$DIR/chunks"
  else
    "$WHISPER" -m "$MODEL" -f "$DIR/others.wav" -l "$LANGUAGE" -oj -of "$DIR/others" -np -ml 120 -sow \
      ${vad_args[@]+"${vad_args[@]}"}
  fi
  rm -f "$DIR/others.wav"
fi

python3 "$HERE/merge.py" "$DIR"
echo "== done: $DIR/transcript.md"
