# Second Brain AI Wearable

An open-source wearable device that continuously listens for speech, transcribes it, extracts structured knowledge, and builds a persistent personal memory queryable in natural language.

## Language

### Device & Firmware

**Wearable**:
The physical device worn by the user (pendant form factor) based on Seeed Studio XIAO ESP32-S3 Sense.
_Avoid_: gadget, recorder, microphone

**VAD (Voice Activity Detection)**:
The firmware algorithm that detects human speech in the audio stream using energy threshold analysis. When speech is detected, recording begins.
_Avoid_: wake word, trigger, activation

**Segment**:
A continuous chunk of recorded audio delimited by a silence timeout. The smallest unit of audio sent to the backend.
_Avoid_: clip, recording, chunk (in domain language)

**Mute**:
Hardware-level microphone deactivation via physical button. When muted, no audio is captured regardless of VAD state.
_Avoid_: pause, stop, disable

### Backend & Processing

**Transcription**:
The text output produced by the Speech-to-Text service from a Segment's audio.
_Avoid_: text, caption, subtitle

**Conversation**:
A logical grouping of one or more Segments that belong to the same continuous interaction, determined by timeout heuristics and LLM-based regrouping.
_Avoid_: session, meeting, recording

**Analysis**:
The asynchronous LLM process that extracts structured Entities from a Transcription.
_Avoid_: processing, enrichment, parsing

**Entity**:
A structured piece of knowledge extracted from a Transcription: a person, task, idea, event, or other named concept.
_Avoid_: item, object, note, tag

### Memory & Retrieval

**Memory**:
The persistent knowledge store containing Transcriptions, Entities, and their vector embeddings. The user's "second brain."
_Avoid_: database, knowledge base, archive

**Query**:
A natural language question posed by the user to retrieve information from Memory via RAG.
_Avoid_: search, request, prompt

**Recall**:
The RAG pipeline that retrieves relevant Transcriptions and Entities from Memory, assembles context, and generates an answer via LLM.
_Avoid_: search, retrieval, lookup
