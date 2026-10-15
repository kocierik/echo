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
