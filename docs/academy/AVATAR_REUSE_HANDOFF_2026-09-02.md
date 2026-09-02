# Cygnus Academy AI — Avatar reuse handoff

Date: 2026-09-02
Source project: `investmentsespana-stack/avatar-platform`
Target: Cygnus Academy AI
Status: APPROVED FOR REUSE

## Decision

Cygnus must reuse the certified Avatar runtime instead of building a separate avatar/video-call stack.

Architecture boundary:

- Avatar provides reusable real-time conversation, streaming, GPU lipsync and audiovisual transport technology.
- Cygnus owns professor identity, course-scoped knowledge, pedagogical rules, student context, voices, curriculum and UI/UX.

## Reusable components already present

1. Persistent conversation service (`app/server.py`)
   - session creation and persistence
   - Qwen-backed chat
   - SSE streaming text responses
   - safe handling of disconnects and retries

2. Continuous conversation endurance (`ops/phase3-continuous-conversation.sh`)
   - multi-turn session continuity
   - persisted state
   - service restart recovery
   - semantic memory verification after restart

3. Persistent MuseTalk worker (`ops/musetalk_persistent_worker.py`)
   - keeps the avatar render runtime warm
   - avoids cold model load for every response

4. Progressive audiovisual transport (`ops/gpu05-av-progressive-transport.sh`)
   - real audio bytes + real MuseTalk JPEG frames
   - progressive delivery before full completion
   - measured first-audio and first-video-frame latency
   - same-run evidence identity

5. Full progressive E2E (`ops/phase2-e2e-avatar.sh` + `.github/workflows/phase2-e2e.yml`)
   - fresh Qwen response
   - fresh TTS
   - persistent MuseTalk
   - progressive audiovisual transport
   - RARA same-run evidence verification

## Fresh Cygnus reuse certification — 2026-09-02

Trigger commit: `5969eb616c092192952dede1a26aaee2c4ead6f4`
GitHub Actions run: `33635108584`
Conclusion: SUCCESS
RARA: `RARA_GPU06_PASS`
GPU: NVIDIA L40S, 46068 MiB

Fresh measured evidence:

- LLM: Qwen/Qwen2.5-7B-Instruct
- lipsync: MuseTalk-1.5
- technical TTS baseline: Piper
- Qwen latency: 246.44 ms
- TTS latency: 997.80 ms
- first audio from full E2E start: 3675.32 ms
- first video frame from full E2E start: 6245.12 ms
- progressive transport first audio: 16.47 ms after transport begins
- progressive transport first video frame: 2586.28 ms after transport begins
- video frames transported: 69
- audio chunks transported: 4
- transport: `ndjson_audio_jpeg_progressive`
- persistent models: true
- server first-frame compute: 2568.39 ms
- full batch wall time: 23856.69 ms
- fresh TTS same run: true
- progressive transport same run: true

All RARA checks passed: result, run identity, commit identity, freshness, first audio, first video, frame count, transport, same-run TTS and same-run progressive transport.

## Important limitation / no overclaim

The existing stack proves the underlying building blocks for a live professor experience, but it is not yet a finished WhatsApp-style Cygnus video-call product. The remaining work is integration of these certified components into a single student-facing professor experience.

## Cygnus adaptations still required

- bind each of the four approved professor portraits to an avatar identity
- bind each professor to a fixed voice and multilingual policy
- replace generic system prompt with strict course/lesson-scoped professor contract
- inject authenticated student/course/lesson context
- connect text streaming -> TTS -> avatar frames as one continuous professor response
- build call-state UI (connect, listening, thinking, speaking, interrupt/end)
- add student microphone/audio input path
- enforce out-of-scope routing to the correct professor/resource
- run mobile + desktop E2E QA

## Voice note

The certified GPU-06 technical baseline uses Piper TTS. Higher-quality Cygnus professor voice can be swapped in after the transport contract is preserved and re-certified. Voice quality changes must not replace the already-proven streaming/avatar architecture.

## Reuse policy

Cygnus development must now focus only on professor identity + course guardrails + voice quality + student context + live-call UI. Do not rebuild the conversation persistence, SSE lifecycle, persistent MuseTalk worker, progressive audiovisual transport or GPU-06 evidence contract unless a verified defect requires repair.
