# Cygnus Academy AI — Avatar reuse handoff

Date: 2026-09-02
Source project: `investmentsespana-stack/avatar-platform`
Target: Cygnus Academy AI

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

The currently certified GPU-06 technical baseline uses Piper TTS. Higher-quality Cygnus professor voice can be swapped in after the transport contract is preserved and re-certified. Voice quality changes must not replace the already-proven streaming/avatar architecture.

## Execution initiated

A fresh GPU-06 revalidation was triggered on 2026-09-02 specifically for Cygnus reuse. Trigger commit: `5969eb616c092192952dede1a26aaee2c4ead6f4`. GitHub Actions run: `33635108584`.

## Acceptance for Cygnus reuse

Re-use is approved when the fresh run confirms:

- L40S available
- Qwen response generated in same run
- fresh speech generated in same run
- progressive media produced from persistent MuseTalk
- first audio > 0
- first video frame > 0
- at least 10 real video frames transported
- RARA run/SHA/freshness checks all PASS

After that, Cygnus development should focus only on professor identity + course guardrails + voice quality + live-call UI, not rebuilding the avatar runtime.
