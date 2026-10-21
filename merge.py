"""Merge whisper JSON for me.json / others.json into a single transcript.md."""
import json
import re
import sys
from datetime import datetime
from pathlib import Path

# Whisper's classic hallucinations on silence/music.
NOISE = re.compile(
    r"^\s*(\[.*\]|\(.*\)|legendas pela comunidade amara\.org|subtitles by the amara\.org community"
    r"|thank you\.?|obrigad[oa]\.?|tchau\.?|\.+|♪+)\s*$",
    re.IGNORECASE,
)


def load(path, speaker):
    if not path.exists():
        return []
    segs = []
    for s in json.loads(path.read_text()).get("transcription", []):
        text = s["text"].strip()
        if text and not NOISE.match(text):
            seg = {"start": s["offsets"]["from"] / 1000, "end": s["offsets"]["to"] / 1000,
                   "speaker": speaker, "text": text}
            if "speaker_id" in s:
                seg["speaker_id"] = s["speaker_id"]
            segs.append(seg)
    return segs


def label_voices(segs, d):
    """Replace "Others" with the voice that overlaps each segment most (speakers.json from the app)."""
    path = d / "speakers.json"
    if not path.exists():
        return
    info = json.loads(path.read_text())
    labels = {s["id"]: s["label"] for s in info["speakers"]}
    voiced = info["segments"]
    for seg in segs:
        if "speaker_id" in seg:  # transcribed turn by turn: already exact
            seg["speaker"] = labels.get(seg["speaker_id"], seg["speaker"])
            continue
        overlap = {}
        for v in voiced:
            o = min(seg["end"], v["end"]) - max(seg["start"], v["start"])
            if o > 0:
                overlap[v["speaker"]] = overlap.get(v["speaker"], 0) + o
        if overlap:
            sid = max(overlap, key=overlap.get)
            seg["speaker_id"] = sid
            seg["speaker"] = labels.get(sid, seg["speaker"])


def words(text):
    return {w for w in re.findall(r"\w+", text.lower()) if len(w) > 2}


def talk_overlap(seg, voiced):
    """Fraction of seg's time during which someone on the call was talking."""
    dur = seg["end"] - seg["start"]
    if dur <= 0:
        return 0
    covered = sum(max(0, min(seg["end"], v["end"]) - max(seg["start"], v["start"])) for v in voiced)
    return min(1, covered / dur)


def is_echo(mine, others, voiced=None):
    """Without headphones the mic hears the call too.

    Calls never play your own voice back, so mic speech while someone on the call is talking is echo.
    Without voice segments, fall back to "most of its words were just said by others".
    """
    if voiced and talk_overlap(mine, voiced) > 0.5:
        return True
    mine_words = words(mine["text"])
    if len(mine_words) < 2:
        return False
    near = set()
    for o in others:
        if o["end"] >= mine["start"] - 3 and o["start"] <= mine["end"] + 3:
            near |= words(o["text"])
    return len(mine_words & near) / len(mine_words) > 0.6


def fmt(t):
    t = int(t)
    return f"{t // 3600}:{t % 3600 // 60:02d}:{t % 60:02d}" if t >= 3600 else f"{t // 60:02d}:{t % 60:02d}"


def main(d):
    d = Path(d)
    others = load(d / "others.json", "Others")
    label_voices(others, d)
    voiced = json.loads((d / "speakers.json").read_text())["segments"] if (d / "speakers.json").exists() else None
    me = [s for s in load(d / "me.json", "Me") if not is_echo(s, others, voiced)]
    segs = sorted(me + others, key=lambda s: s["start"])

    turns = []
    for s in segs:
        if turns and turns[-1]["speaker"] == s["speaker"] and s["start"] - turns[-1]["end"] < 3:
            turns[-1]["text"] += " " + s["text"]
            turns[-1]["end"] = s["end"]
        else:
            turns.append(dict(s))

    # For the app's "who's who" window: what each voice said.
    (d / "turns.json").write_text(json.dumps(
        [{"start": t["start"], "end": t["end"], "speaker_id": t.get("speaker_id", t["speaker"]), "text": t["text"]}
         for t in turns], ensure_ascii=False, indent=1))

    meta = json.loads((d / "meta.json").read_text()) if (d / "meta.json").exists() else {}
    started = meta.get("started")
    when = datetime.fromisoformat(started.replace("Z", "+00:00")).astimezone().strftime("%Y-%m-%d %H:%M") if started else d.name
    header = [f"# Meeting {when}", ""]
    if meta:
        header += [f"- App: `{meta.get('app', '?')}`", f"- Duration: {fmt(meta.get('seconds', 0))}"]
    body = [f"**[{fmt(t['start'])}] {t['speaker']}:** {t['text']}" for t in turns] or ["_(no speech detected)_"]
    (d / "transcript.md").write_text("\n".join(header) + "\n\n" + "\n\n".join(body) + "\n")


if __name__ == "__main__":
    main(sys.argv[1])
