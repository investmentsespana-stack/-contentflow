import fs from 'node:fs';
import assert from 'node:assert/strict';

const ledger = JSON.parse(fs.readFileSync('docs/architecture/autonomy/recovery-promotion-ledger.v1.json', 'utf8'));
assert.equal(ledger.mode, 'fail-closed');
assert.deepEqual(ledger.stages, ['canary', 'limited', 'expanded']);
assert.equal(ledger.rules.skip_stage, 'deny');
assert.equal(ledger.rules.missing_evidence, 'deny');
assert.equal(ledger.rules.unknown_fingerprint, 'deny');
assert.equal(ledger.rules.failed_validation, 'demote');
assert.equal(ledger.rules.recurrent_incident, 'demote');
assert.equal(ledger.rules.critical_or_external_effect, 'owner_required');
assert.equal(ledger.rules.automatic_global_promotion, false);
for (const key of ['certified_recovery_fingerprint','trust_chain_admission_pass','correlated_evidence_ids','rollback_available','post_repair_validation_pass','fencing_token','idempotency_key']) assert.ok(ledger.promotion_requires.includes(key));
for (const key of ['incident_fingerprint','from_stage','to_stage','evidence_ids','rollback_id','validation_id','decision_reason']) assert.ok(ledger.ledger_entry_requires.includes(key));
console.log('recovery-promotion-ledger: PASS');
