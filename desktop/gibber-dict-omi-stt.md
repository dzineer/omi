# Gibber Project Dictionary Extension: `omi-stt`

Domain-specific symbols for the Omi Desktop local speech-to-text integration.

## Audio pipeline

| Symbol | Meaning |
|---|---|
| `§audio-capture` | The AudioCaptureService that captures microphone/system audio. |
| `§audio-mixer` | The AudioMixer that produces stereo PCM (mic L, system R). |
| `§vad-gate` | The VADGateService running Silero ONNX for voice activity detection. |
| `§pcm16` | 16-bit signed integer PCM audio format. |
| `§16khz` | 16,000 Hz sample rate. |
| `§mono` | Single audio channel. |
| `§stereo` | Two audio channels (mic + system). |
| `§wav` | WAV container format for audio chunks. |

## STT engines

| Symbol | Meaning |
|---|---|
| `§deepgram` | The Deepgram cloud STT service (current, being replaced). |
| `§mlx-whisper` | MLX Whisper — local STT engine optimized for Apple Silicon via Metal GPU. |
| `§whisper-turbo` | The `whisper-large-v3-turbo` model (~1.6 GB, fastest accurate model). |
| `§local-stt` | The new LocalSTTService that runs STT on-device. |
| `§cloud-stt` | The existing TranscriptionService that uses Deepgram cloud. |
| `§stt-toggle` | Feature flag to switch between local and cloud STT. |

## Transcription pipeline

| Symbol | Meaning |
|---|---|
| `§transcript-segment` | A segment of transcribed text with speaker, timestamps, confidence. |
| `§speaker-segment` | A SpeakerSegment: speaker ID, text, start time, end time. |
| `§interim-result` | Partial transcription result (not yet finalized). |
| `§final-result` | Finalized transcription result. |
| `§hallucination-filter` | Post-processing that removes common Whisper hallucination artifacts. |
| `§conversation-pipeline` | The existing handleTranscriptSegment → SQLite → API upload flow. |

## Infrastructure

| Symbol | Meaning |
|---|---|
| `§python-subprocess` | A Python process spawned and managed by the Swift app. |
| `§fastapi-server` | A FastAPI HTTP server running locally for inference. |
| `§localhost-8787` | The local endpoint `http://localhost:8787` for the MLX Whisper server. |
| `§openai-compat` | OpenAI-compatible API format (`/v1/audio/transcriptions`). |
| `§metal-gpu` | Apple Metal GPU acceleration for ML inference. |
| `§onnx-runtime` | The ONNX Runtime already used for Silero VAD. |

## Swift types

| Symbol | Meaning |
|---|---|
| `§LocalSTTService` | The new Swift actor/class replacing TranscriptionService for local STT. |
| `§TranscriptionService` | The existing Deepgram WebSocket-based transcription service. |
| `§AppState` | The master state object that orchestrates transcription start/stop. |
| `§handleTranscriptSegment` | The callback method in AppState that processes transcript segments. |
