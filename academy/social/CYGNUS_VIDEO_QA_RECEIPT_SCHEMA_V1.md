# Cygnus Academy AI — Premium Video QA Receipt Schema V1

Status: CANONICAL_QA_RECEIPT_SCHEMA
Date: 2026-09-02
Owner: Social Ops — Cygnus / RARA

Every final social video candidate must generate a structured QA receipt before status may advance to `READY_FOR_DIRECTOR_APPROVAL`.

## Required receipt fields

```json
{
  "schema": "cygnus.social.video.qa.v1",
  "contentId": "F02",
  "cluster": "A",
  "primaryIntent": "",
  "problem": "",
  "promisedResult": "",
  "funnelStage": "",
  "variant": "master|short|authority",
  "publicationState": "NOT_UPLOADED_NOT_PUBLISHED",
  "sourceEvidence": {
    "assetId": "",
    "provenance": "real_screen|real_workflow|real_document|cygnus_runtime|director_runtime|skool_runtime|other_verified",
    "sourceReference": "",
    "sensitiveDataReviewed": true,
    "claimEvidenceMatch": "pass|fail"
  },
  "video": {
    "width": 1080,
    "height": 1920,
    "aspectRatio": "9:16",
    "fps": 30,
    "durationSeconds": 0,
    "codec": "h264|h265",
    "playbackInspection": "pass|fail",
    "visualArtifacts": "pass|fail"
  },
  "captions": {
    "present": true,
    "synchronized": "pass|fail",
    "spelling": "pass|fail",
    "mobileSafe": "pass|fail",
    "sidecar": "srt|vtt|both|none"
  },
  "audio": {
    "voicePresent": true,
    "intelligibility": "pass|fail|na",
    "noiseClippingPops": "pass|fail|na",
    "levelConsistency": "pass|fail|na",
    "pronunciationReview": "pass|fail|na"
  },
  "avatar": {
    "used": false,
    "naturalness": "pass|fail|na",
    "lipsync": "pass|fail|na",
    "temporalFlicker": "pass|fail|na",
    "faceMouthArtifacts": "pass|fail|na"
  },
  "branding": {
    "cygnusIdentity": "pass|fail",
    "typographyHierarchy": "pass|fail",
    "motionRestraint": "pass|fail",
    "ctaSingleNextAction": "pass|fail"
  },
  "production": {
    "method": "cpu|api|vm_gpu|hybrid",
    "gpuUsed": false,
    "gpuPurpose": [],
    "toolchain": [],
    "renderNotes": ""
  },
  "integrity": {
    "unsupportedClaims": "none|found",
    "confidentialData": "none|found",
    "sha256": "",
    "manifestReference": ""
  },
  "rara": {
    "status": "PASS|REJECTED_QUALITY|BLOCKED_EVIDENCE|BLOCKED_EDITORIAL",
    "failedChecks": [],
    "reviewNotes": ""
  },
  "checkedAt": "ISO-8601"
}
```

## Machine acceptance rules

RARA must reject when any of the following is true:
- width/height are below the required vertical delivery or aspect ratio is wrong;
- duration is missing/invalid;
- captions are expected but absent, unsynchronized, misspelled or outside mobile-safe areas;
- audio has clipping/noise/intelligibility failure when voice is present;
- visual-evidence provenance is missing or claim/evidence does not match;
- avatar is used and naturalness/lipsync/artifact review is not PASS;
- unsupported claims or confidential data are found;
- SHA-256 or final manifest reference is missing;
- publication state is anything other than `NOT_UPLOADED_NOT_PUBLISHED` before separate publication authorization.

## Director review packet minimum

The receipt must accompany:
- final MP4 or durable artifact reference;
- representative keyframes/thumbnail references;
- final script and caption;
- subtitle artifact reference when applicable;
- final SHA-256/manifest;
- exact evidence provenance;
- production method and whether Nebius GPU was used;
- blockers and explicit publication state.

This schema does not authorize upload or publication.