"""Transcribe the "others" track turn by turn, using the voice segments in speakers.json.

    turns.py split <dir>    cut others.wav into one chunk per speaker turn (chunks/NNN.wav + index.json)
    turns.py collect <dir>  combine the chunks' whisper output into others.json, tagged with speaker ids

Whole-file whisper sometimes skips a turn when speakers alternate; one chunk per turn cannot.
"""
import json
import sys
import wave
from pathlib import Path

PAD = 0.25       # seconds of context around each turn
JOIN_GAP = 1.0   # same speaker again within this gap = same turn
MIN_LEN = 0.6    # shorter blips are skipped (whisper hallucinates on them)


def read_pcm(path):
    """Return the raw bytes of a RIFF file's data chunk."""
    raw = path.read_bytes()
    i = 12
    while i + 8 <= len(raw):
        cid, size = raw[i:i + 4], int.from_bytes(raw[i + 4:i + 8], "little")
        if cid == b"data":
            return raw[i + 8:i + 8 + size]
        i += 8 + size + (size & 1)
    raise ValueError(f"no data chunk in {path}")


def split(d):
    info = json.loads((d / "speakers.json").read_text())
    segs = sorted(info["segments"], key=lambda s: s["start"])
    turns = []
    for s in segs:
        if turns and turns[-1]["speaker"] == s["speaker"] and s["start"] - turns[-1]["end"] < JOIN_GAP:
            turns[-1]["end"] = max(turns[-1]["end"], s["end"])
        else:
            turns.append(dict(s))

    # afconvert writes WAVE_FORMAT_EXTENSIBLE, which the wave module rejects; we know it's 16 kHz 16-bit mono.
    rate, width, ch = 16000, 2, 1
    pcm = read_pcm(d / "others.wav")
    total = len(pcm) / (rate * width)
    out_dir = d / "chunks"
    out_dir.mkdir(exist_ok=True)
    index = []
    for t in turns:
        if t["end"] - t["start"] < MIN_LEN:
            continue
        start, end = max(0.0, t["start"] - PAD), min(total, t["end"] + PAD)
        frames = pcm[int(start * rate) * width:int(end * rate) * width]
        path = out_dir / f"{len(index):04d}.wav"
        with wave.open(str(path), "wb") as w:
            w.setnchannels(ch)
            w.setsampwidth(width)
            w.setframerate(rate)
            w.writeframes(frames)
        index.append({"file": str(path), "start": start, "end": end, "speaker": t["speaker"]})
    (out_dir / "index.json").write_text(json.dumps(index, indent=1))
    print("\n".join(i["file"] for i in index))


def collect(d):
    index = json.loads((d / "chunks" / "index.json").read_text())
    out = []
    for c in index:
        path = Path(c["file"] + ".json")
        if not path.exists():
            continue
        text = " ".join(s["text"].strip() for s in json.loads(path.read_text()).get("transcription", []))
        if text.strip():
            out.append({"offsets": {"from": int(c["start"] * 1000), "to": int(c["end"] * 1000)},
                        "text": text, "speaker_id": c["speaker"]})
    (d / "others.json").write_text(json.dumps({"transcription": out}, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    {"split": split, "collect": collect}[sys.argv[1]](Path(sys.argv[2]))
