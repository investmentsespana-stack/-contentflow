# WhatsApp Business — Cygnus · Truth-First Integration V1

## Canonical channel
- Brand: Cygnus Academy AI
- Phone E.164: `+18433044951`
- Human-readable: `+1 843-304-4951`
- Supersedes erroneous reference: `+18433041495` (do not use)
- Purpose: verified Academy information and human escalation.
- Explicitly **not** a generic chatbot.

## Product rule
The system must never improvise prices, course availability, enrollment links, certification promises, schedules, policies, or any fact that is not present in an approved source.

Response policy:
1. Classify user intent.
2. Resolve only from `academy_whatsapp_knowledge` active/verified entries.
3. Persist source reference and confidence with the message.
4. If the answer is not certified, respond that it cannot be confirmed and create a human handoff.
5. Human handoffs emit a Director help alert without putting the student's phone number or message text in the alert summary.

## Runtime components deployed
### Supabase data plane
Migration `academy_whatsapp_truth_first_core_v1` created:
- `academy_whatsapp_config`
- `academy_whatsapp_knowledge`
- `academy_whatsapp_conversations`
- `academy_whatsapp_messages`
- `academy_whatsapp_outbox`
- `academy_whatsapp_handoffs`
- RPC `academy_whatsapp_resolve_answer(text, language)`

Migration `academy_whatsapp_intent_priority_fix_v1` corrected classifier priority so specific commercial/academic intents win over generic identity/greeting.

Migration `academy_whatsapp_handoff_director_bridge_v1` connects human-required cases to `director_help_alerts`.

All WhatsApp tables have RLS enabled and direct anon/authenticated access revoked.

### Edge Function
Deployed function: `academy-whatsapp-webhook`

Callback URL:
`https://koqpyfvnprmirqviafzq.supabase.co/functions/v1/academy-whatsapp-webhook`

`verify_jwt=false` is intentional because Meta calls this endpoint externally. Authentication is implemented inside the function:
- GET webhook challenge requires `WHATSAPP_VERIFY_TOKEN`.
- POST events require valid `X-Hub-Signature-256` HMAC with `META_APP_SECRET`.
- Invalid/missing signatures fail closed.

Outbound sending is also fail-closed. A reply is not sent unless ALL are true:
- `academy_whatsapp_config.enabled = true`
- `WHATSAPP_ACCESS_TOKEN` is configured
- Phone Number ID is configured
- `META_GRAPH_VERSION` is configured

## Secrets / runtime configuration required
Never store values in GitHub, backlog, screenshots, chat, or knowledge rows.

Required runtime values:
- `WHATSAPP_VERIFY_TOKEN`
- `META_APP_SECRET`
- `WHATSAPP_ACCESS_TOKEN`
- `WHATSAPP_PHONE_NUMBER_ID`
- `META_GRAPH_VERSION`

Non-secret identifiers to persist after Meta binding:
- WABA ID → `academy_whatsapp_config.waba_id`
- Phone Number ID → `academy_whatsapp_config.phone_number_id`
- approved display/verified name → `academy_whatsapp_config.verified_name`

## Meta binding gate
The system MUST remain disabled until the owner completes the real Meta/WhatsApp Business Platform setup:
1. Add/enable WhatsApp product on the correct Cygnus Meta business/app context.
2. Add `+18433044951` to the WhatsApp Business Account.
3. Verify ownership of the phone by the Meta-required SMS/voice flow.
4. Obtain the real WABA ID and Phone Number ID.
5. Register the phone for Cloud API and set the owner-controlled 6-digit two-step verification PIN.
6. Configure a valid access token with the required WhatsApp messaging permission.
7. Configure the callback URL above and an owner-generated verify token.
8. Subscribe the WABA/webhook to message events.
9. Confirm the webhook challenge is accepted.
10. Persist only non-secret identifiers/status in `academy_whatsapp_config`.

Do not set `enabled=true` yet.

## E2E activation canary
After Meta binding:
1. Send one real WhatsApp message from an external phone to `+18433044951`.
2. Verify inbound message persisted with a real `wamid`.
3. Verify a factual query receives the approved knowledge answer.
4. Verify an uncertified question creates a handoff instead of an invented answer.
5. Verify Director receives the handoff alert.
6. Verify outbound WhatsApp message ID and delivery status are persisted.
7. Only after those checks pass, set config status `active` and `enabled=true`.

## Current verified canaries
- Pricing question → `pricing`, `requires_human=true`.
- Course availability question → `courses`, `requires_human=true`.
- Methodology question → verified academic answer.
- Unknown/out-of-scope question → `unknown`, `requires_human=true`.
- Synthetic handoff → Director alert created successfully and canary data removed after verification.

## Director state
Tracked tasks:
- `academy_whatsapp_truth_core_v1` — completed / runtime-proven.
- `academy_whatsapp_webhook_v1` — verification required until real Meta webhook challenge.
- `academy_whatsapp_meta_binding_v1` — blocked only on human Meta/phone ownership prerequisite.
- `academy_whatsapp_e2e_canary_v1` — blocked until Meta binding is complete.

## Non-negotiable guardrails
- Canonical WhatsApp number is `+18433044951`; `+18433041495` is superseded and must not be used.
- No invented WABA ID, Phone Number ID, tokens, Graph version, message IDs, prices, offers or course publication state.
- No token in chat/log/report.
- No auto-enable before E2E canary.
- Duplicate inbound `wamid` must not produce duplicate replies.
- Unknown/non-text content must fail safely to verified fallback/human handling.
- Customer message text stays in the WhatsApp conversation store; Director alert carries only the handoff ID/reason, not phone/message content.
