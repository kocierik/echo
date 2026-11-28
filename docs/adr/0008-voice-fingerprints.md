# Voice fingerprints on the server to tell speakers apart

Echo used to call a segment "You" or "Others" from its loudness (the wearer is closest to the
microphone), which often failed. Every segment now gets a voice fingerprint (a 256-number
speaker embedding) while its audio exists, and the user can teach Echo their own voice and the
voices of the people around them.

## Decision

- **Model**: WeSpeaker ResNet34 trained on VoxCeleb (multilingual), run on the CPU through
  sherpa-onnx (~43 MB library, ~26 MB model, ~2 s for a 5 s segment beside the transcription).
  The model is downloaded into the Docker image and checked against its SHA-256; without it
  fingerprints are off and the energy rule stays.
- **Own voice**: recorded in Settings → Voices (the user reads a text aloud wearing Echo; the
  segments recorded meanwhile become the profile) and refined by every transcript correction
  to "You".
- **Other voices**: named in a transcript ("Who is speaking?": me, one of the People, or a new
  name). The profile is created or refined from that segment and the conversation's other
  segments with the same voice are labelled too.
- **Recognition**: cosine similarity to the profiles. From `VOICE_MATCH_THRESHOLD` (0.6) the
  voice is that profile's; from `VOICE_SUGGEST_THRESHOLD` (0.45) the transcript asks "Marco?"
  with ✓/✗. With the user's own profile, anything else is "Others"; without it, the energy
  rule decides.
- **Text format unchanged**: transcripts keep the `[You]`/`[Others]` tags (the voice-command
  parser and the app rely on them); names live in `segments.voice_profile_id` and are returned
  as `speaker_name` by the conversation endpoint.

## Considered Options

- **OpenAI `gpt-4o-transcribe-diarize`** with reference clips: at most 4 known people per
  request, no prompt with known names, and the reference voices sent with every request.
- **Deepgram diarization**: speakers separated within a request only, no persistent voices.
- **PyTorch models (SpeechBrain ECAPA)**: same idea, but hundreds of MB more in the image.

## Consequences

- Fingerprints are biometric data (a special category under GDPR) of people who did not
  consent. They stay on the user's server, profiles exist only when the user records or names
  a voice, and every profile can be deleted from the app; segment fingerprints go with their
  conversation.
- Thresholds were set on synthetic voices; they must be calibrated on real recordings.
- A segment (up to 6 s) can hold more than one voice; it gets the voice that dominates it.

## Update (2026-11-22)

Real recordings showed that through the pendant's one microphone every voice scores about
0.75–0.8 against every other: the newest profile won whole days of segments. Since then:

- **The pendant's sound is taken away.** Fingerprints are compared after subtracting the mean
  of the user's last 300 segment fingerprints (`voice_context`); the user's and another voice
  went from 0.75 to −0.20. Thresholds for centered fingerprints: `voice_centered_*` in
  `core/config.py`.
- **Loudness.** A segment among the user's loudest 15% is never given automatically to someone
  else; with no sure voice, it is the user's.
- **No mass renaming.** Naming one segment renames the others of the conversation only when
  they sound clearly more like that voice than any other.
- **Two voices in one segment** (segments now last up to 25 s). Deepgram's diarization splits
  a segment into turns when it can; when it hears one voice, a segment with at least three
  4 s windows is split in two when its windows fall into two groups whose average voices are
  less alike than `voice_split_below` (−0.10). Measured on real audio: 11 of 15 joined pairs of
  two people split, 7 of 55 long one-voice segments. Each turn can be named.

Thresholds are still set on few corrections and two voices; corrections by hand on
conversations with more people are what will tune them.
