# ContentFlow / Director Maestro — Legal & Governance Pack v1.0

Effective baseline: 2026-08-23
Status: INTERNAL GOVERNANCE BASELINE — counsel review required before public/commercial launch in a regulated or high-risk use case.

## 1. Purpose and scope

This pack governs ContentFlow, the Director Orchestrator, RARA, workers, judges, evidence producers, recovery memory, and projects generated or operated through them. It is a governance and compliance engineering baseline, not a substitute for advice from licensed counsel.

## 2. Governing principles

1. Human ownership and accountability remain outside the AI system. The Director and RARA are electronic agents/software components, not legal persons and not independent contracting parties.
2. Least authority: autonomous actions are limited by explicit authority envelopes. High-risk, irreversible, regulated, financial, legal, employment, health, safety, identity, contractual, or external-commitment actions require an applicable project policy and, where designated, human approval.
3. Evidence before promotion: implementation, execution, review, certification, and production promotion are distinct states.
4. Fail closed: missing authority, provenance, evidence, rollback capability, or required review blocks autonomous promotion.
5. Traceability: material autonomous decisions must retain actor/model, task, inputs or input references, output/artifact, evidence references, review result, authority decision, timestamps, and recovery lineage subject to minimization and retention rules.
6. No fabricated evidence: simulated, mocked, hardcoded, or unverifiable evidence may not be represented as real-world execution evidence.
7. Data minimization: collect, transmit, and retain only data reasonably necessary for the declared purpose.
8. Vendor boundary: secrets and personal/confidential data may be sent to a processor/model provider only when the project's data classification and vendor policy permit it.

## 3. Legal authority and electronic transactions

South Carolina's Uniform Electronic Transactions Act recognizes electronic records/signatures and defines electronic agents and automated transactions. ContentFlow therefore must preserve clear attribution, consent/authority, record retention, and an audit trail when automation participates in a transaction. The system must not infer that technical ability equals legal authority.

Policy: the Director may prepare, route, recommend, validate, and execute reversible technical actions within its authority envelope. It may not autonomously bind the owner/company to a new material contract, waive rights, make regulated representations, submit sworn/legal filings, transfer material funds/assets, or make a high-impact decision about a person unless a project-specific policy expressly authorizes that action and all required human/legal gates are satisfied.

## 4. Privacy and data governance

Every project must maintain a data inventory covering: category, source, purpose, legal/business basis, processors/subprocessors, retention, deletion method, sensitivity, and whether data is used for model training or evaluation.

Minimum controls:
- purpose limitation and data minimization;
- role-based/least-privilege access;
- encryption in transit and at rest where supported;
- secrets outside source code and prompts;
- retention schedule and deletion workflow;
- data-subject request workflow when applicable;
- processor/subprocessor inventory and contract/DPA review;
- incident and breach response;
- special review before processing health, financial, precise location, biometric, children's, employment, legal-client, authentication, or other sensitive data.

Public privacy statements must accurately reflect actual collection, use, sharing, retention, deletion, AI processing, and vendor practices. Product behavior must not contradict published privacy promises.

## 5. Security and breach response

ContentFlow adopts security-by-design and least privilege. South Carolina Code §39-1-90 is included in the incident-response legal matrix for breaches involving covered personal identifying information of South Carolina residents. Applicability, risk-of-harm analysis, notice recipients, timing, and other jurisdictional duties must be evaluated for each incident.

Incident workflow: detect → contain → preserve evidence → classify data/jurisdictions → assess legal notification duties → eradicate/recover → validate → document → learn. RARA may contain and recover technical systems within its authority envelope but may not decide alone that a legally required breach notification is unnecessary.

## 6. AI governance

Governance aligns operationally with NIST AI RMF and the NIST Generative AI Profile: GOVERN, MAP, MEASURE, MANAGE. Each project receives a risk profile before production.

Required AI controls:
- intended use and prohibited use;
- model/provider provenance;
- evaluation criteria and acceptance thresholds;
- hallucination/evidence controls;
- prompt/data injection boundaries;
- human escalation criteria;
- monitoring and incident reporting;
- change/version control;
- recovery/rollback;
- bias/fairness review where decisions affect people;
- disclosure/consent where required by law or product context.

## 7. Risk tiers and authority

LOW: reversible internal technical work with no sensitive external consequence. Director may act autonomously with logging.

MEDIUM: production-affecting but reversible actions, non-sensitive external integrations, or meaningful data operations. Canary, evidence and rollback required; RARA/independent review as configured.

HIGH: sensitive personal data, material customer impact, security boundary changes, consequential decisions, regulated-domain output, contractual commitments, payments, public legal/compliance representations. Human approval required unless counsel-approved project policy provides a narrower automated authority.

PROHIBITED WITHOUT SPECIFIC LEGAL/OWNER AUTHORIZATION: signing/accepting material contracts; legal filings or sworn statements; irreversible deletion of protected records; unauthorized disclosure of confidential/personal data; autonomous employment/credit/housing/insurance or similarly consequential final decisions; bypassing security/consent controls; representing AI output as professional legal/medical/financial advice where applicable rules prohibit or constrain it.

## 8. Intellectual property and licensing

For every generated project, maintain: repository ownership, contributor/contractor IP assignments where applicable, dependency/license inventory, model/provider terms, dataset/source provenance, third-party notices, and restrictions on generated or imported assets.

AI-generated material must not be assumed to have exclusive copyright protection merely because it was generated. Human-authored selection, arrangement, editing, software authorship, documentation, branding, and other protectable contributions should be documented. Third-party material must not be copied merely because a model can reproduce it.

## 9. Vendor governance

Before a provider may receive confidential/personal data, record: service purpose, data categories, retention, training/use policy, security posture, DPA/contract availability, subprocessors, transfer/residency considerations, deletion/export ability, incident terms, and exit plan.

Current architecture providers requiring maintained review include Supabase, Vercel, GitHub, and each model/gateway provider. Provider terms and DPAs are external contracts and can change; the Director must treat their review date/version as mutable compliance evidence, not permanent truth.

## 10. Customer-facing legal documents required before commercial launch

A commercial project must not be promoted to public production until the applicable package exists and is approved: Terms of Service/Terms of Use; Privacy Notice; Acceptable Use Policy; AI disclosure/limitations where appropriate; cookie/tracking notice and consent controls where applicable; DPA/business terms for B2B processing where applicable; refund/billing terms if paid; IP/DMCA contact/process where applicable; accessibility and sector-specific notices where applicable.

## 11. Records, retention and evidence

Retention is purpose- and law-based, not indefinite by default. Audit evidence should be immutable/tamper-evident where feasible and should use semantic IDs/hashes and lineage. Secrets must not be retained in evidence. Legal holds override ordinary deletion only when properly authorized.

## 12. Project legal admission gate

Before a Director-generated project reaches production, it must answer and evidence:
- Who owns/operates it?
- Who are the users and jurisdictions?
- What data is collected and why?
- What sensitive/regulated data or decisions exist?
- Which vendors receive data?
- What licenses/IP inputs exist?
- What consumer claims are made?
- What actions can AI take autonomously?
- Which actions require human approval?
- What are retention/deletion rules?
- What incident/breach workflow applies?
- What customer-facing legal documents are required?
- Has the risk tier been assigned and approved?

Missing required answers produce LEGAL_HOLD, not production promotion.

## 13. Mandatory human/legal escalation

Escalate when: law is ambiguous or jurisdiction-dependent; a regulator/court/law-enforcement request arrives; a breach may trigger notice; a contract materially changes rights/liability; a project enters a regulated sector; a high-impact decision about a person is proposed; intellectual-property ownership/licensing is uncertain; or the system would make a legally consequential representation.

## 14. Sources / legal baseline

- South Carolina Uniform Electronic Transactions Act, S.C. Code Title 26, Chapter 6.
- South Carolina business data breach law, S.C. Code §39-1-90.
- Federal Trade Commission privacy and data-security business guidance.
- NIST AI Risk Management Framework 1.0 and NIST AI 600-1 Generative AI Profile.
- Applicable provider agreements/DPAs, including current Supabase and Vercel data-processing terms.

## 15. Release rule

This pack is a minimum baseline. A project's sector, users, geography, data, claims, or autonomous authority may require stricter controls. The Director must never downgrade a project-specific legal requirement to this generic baseline.
