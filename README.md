# MeetRec — local meeting transcripts (POC)

Menu bar app. Starts at login and watches for calls. When any app opens the mic (Meet in Chrome,
Zoom, Slack huddles, Teams…) it records your mic + the Mac's audio, shows live captions, and when the
call ends it writes a transcript with **real names**. Everything runs on this Mac: no audio, text or
voiceprints leave it, and nothing joins the call.

Output: `~/Meetings/<date>_<time>_<app>/transcript.md`. App log: `~/Meetings/meetrec.log`.

## Pieces

| Stage | Engine | When |
|---|---|---|
| Call detection | Core Audio process list (who is using the mic) | always |
| Recording | mic via AVAudioEngine, system audio via Core Audio tap | during call |
| Live captions | Apple SpeechAnalyzer (on-device, macOS 26) | during call |
| Who spoke when | FluidAudio offline diarization (Neural Engine) | after call |
| Names | voice library `~/.meetrec/voices.json` (cosine match < 0.5) | after call |
| Transcript | whisper.cpp large-v3-turbo, one chunk per speaker turn | after call |

## Install / update

```bash
./build-app.sh                      # builds, signs, installs ~/Applications/MeetRec.app
open ~/Applications/MeetRec.app
```

- Signed with the self-signed "MeetRec Local Signing" certificate (`~/.meetrec/signing`), so macOS
  keeps the Microphone / System Audio permissions across rebuilds.
- Needs `brew install whisper-cpp` and the models in `~/.meetrec/models`. FluidAudio and Apple's
  speech models download themselves once.

## Menu

- Start/Stop recording now (manual recordings are never discarded).
- Show/Hide live captions · Live captions on/off · Live captions language (Português / English).
- Name speakers in last meeting… · Open last transcript · Open Meetings folder · Open log.
- Start at login (on by default).

## Claude

- After each transcript (and naming, if there were new voices) a small prompt asks
  **Analyze with Claude?**, which opens a new Claude desktop Code session on the meeting folder with
  the analysis prompt prefilled (`claude://code/new?q=…&folder=…`; Desktop confirms the folder).
- During a call, the captions window has **Ask Claude** (last ~2 minutes) and a ✦ on each line
  (hover) to open a session about something that was just said.
- Only the transcript text goes to Claude; audio and voiceprints stay local.

## Names

After a call with new voices, a **Who's who?** window opens: play a clip of each voice, type the
name once. Next meetings label that person automatically. Correct a wrong name the same way.
Your own voice is always "Me" (it comes from your mic).

## Behaviour and limits

- Starts ~4 s after another app opens the mic; stops 20 s after it's released.
- Auto-recordings under 60 s are discarded; Siri / dictation / accessibility listeners are ignored.
- Without headphones the mic also hears the call. The transcript drops obvious echoes; headphones
  avoid it entirely.
- Live captions use one language at a time (menu). The final transcript auto-detects.
- Problems that would lose a recording turn the menu bar dot **orange**, show a ⚠ line at the top
  of the menu (with **Dismiss warning**) and post a notification:
  - under 2 GB free during a call: warning, recording continues;
  - under 300 MB free, or a failed audio write: recording stops and is finalized, so what was
    recorded so far still transcribes. A new call doesn't start recording until there's space again;
  - a meeting folder left without `meta.json` (MeetRec died mid-call): flagged at the next launch.

## CLI (testing)

```bash
M=~/Applications/MeetRec.app/Contents/MacOS/MeetRec
$M mics                              # which apps hold the mic
$M diarize ~/Meetings/<dir>          # re-run voice separation + names
$M name ~/Meetings/<dir> S1=Ana S2=Bruno
./transcribe.sh ~/Meetings/<dir>     # re-run transcription
```
