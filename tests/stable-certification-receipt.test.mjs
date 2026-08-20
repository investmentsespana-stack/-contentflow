import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const workflow = fs.readFileSync(new URL('../.github/workflows/panel-qa.yml', import.meta.url), 'utf8');

test('Stable certification receipt is limited to green push-to-main runs', () => {
  assert.match(workflow, /stable-certification-receipt:/);
  assert.match(workflow, /github\.event_name == 'push'/);
  assert.match(workflow, /github\.ref == 'refs\/heads\/main'/);
  assert.match(workflow, /needs: \[director-certification, browser-matrix\]/);
  assert.match(workflow, /context: 'contentflow\/stable-recertification'/);
  assert.match(workflow, /state: 'success'/);
});

test('Stable certification receipt requires explicit status write permission', () => {
  assert.match(workflow, /statuses: write/);
});
