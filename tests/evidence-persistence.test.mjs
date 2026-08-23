import test from 'node:test';
import assert from 'node:assert/strict';
import {
  EvidencePersistenceError,
  createEvidencePersistence,
  evidenceDigest,
  evidenceStorageKey,
} from '../src/platform/evidence-persistence.mjs';

test('digest is deterministic across key order', () => {
  assert.equal(evidenceDigest({ b: 2, a: 1 }), evidenceDigest({ a: 1, b: 2 }));
});

test('storage key is content-addressed and correlated', () => {
  const key = evidenceStorageKey({
    projectKey: 'contentflow',
    builderRunId: 2900,
    evidenceKey: 'runtime/proof',
    payload: { passed: true },
  });
  assert.match(key, /^contentflow\/2900\/runtime%2Fproof\/[a-f0-9]{64}\.json$/);
});

test('storage key rejects missing correlation fields', () => {
  assert.throws(
    () => evidenceStorageKey({ projectKey: '', builderRunId: 2900, evidenceKey: 'x', payload: { a: 1 } }),
    EvidencePersistenceError,
  );
});

test('constructor rejects missing adapters', () => {
  assert.throws(() => createEvidencePersistence({ putIfAbsent: null, uriForKey: null }), EvidencePersistenceError);
});

test('successful durable write returns verifiable URI and digest', async () => {
  const writes = new Map();
  const persist = createEvidencePersistence({
    async putIfAbsent(key, body) {
      if (!writes.has(key)) writes.set(key, body);
    },
    async uriForKey(key) {
      return `evidence://runtime-ledger/${key}`;
    },
  });

  const input = {
    projectKey: 'contentflow',
    builderRunId: 2900,
    evidenceKey: 'module-certification',
    evidenceType: 'runtime_test',
    observedAt: '2026-08-23T00:00:00.000Z',
    payload: { branch_coverage: 100, storage_failure_tested: true },
  };
  const first = await persist(input);
  const second = await persist(input);

  assert.equal(first.uri, second.uri);
  assert.equal(first.sha256, evidenceDigest(input.payload));
  assert.equal(writes.size, 1, 'idempotent content-addressed write');
  assert.match(first.uri, /^evidence:\/\//);
});

test('uses default evidence type and observation time when omitted', async () => {
  let stored = '';
  const persist = createEvidencePersistence({
    async putIfAbsent(_key, body) { stored = body; },
    async uriForKey(key) { return `evidence://runtime-ledger/${key}`; },
  });
  await persist({ projectKey: 'contentflow', builderRunId: 1, evidenceKey: 'default', payload: { ok: true } });
  assert.match(stored, /"evidence_type":"runtime"/);
  assert.match(stored, /"observed_at":"\d{4}-\d{2}-\d{2}T/);
});

test('empty payload fails closed', async () => {
  const persist = createEvidencePersistence({
    async putIfAbsent() {},
    async uriForKey() { return 'evidence://x'; },
  });
  await assert.rejects(() => persist({ projectKey: 'contentflow', builderRunId: 1, evidenceKey: 'x', payload: {} }), EvidencePersistenceError);
});

test('storage failure is wrapped as EvidencePersistenceError', async () => {
  const persist = createEvidencePersistence({
    async putIfAbsent() { throw new Error('simulated durable-store outage'); },
    async uriForKey() { return 'evidence://never'; },
  });
  await assert.rejects(
    () => persist({ projectKey: 'contentflow', builderRunId: 1, evidenceKey: 'x', payload: { ok: true } }),
    (err) => err instanceof EvidencePersistenceError && err.cause?.message === 'simulated durable-store outage',
  );
});

test('unverifiable URI fails closed', async () => {
  const persist = createEvidencePersistence({
    async putIfAbsent() {},
    async uriForKey() { return 'local-file-without-scheme'; },
  });
  await assert.rejects(
    () => persist({ projectKey: 'contentflow', builderRunId: 1, evidenceKey: 'x', payload: { ok: true } }),
    /unverifiable URI/,
  );
});
