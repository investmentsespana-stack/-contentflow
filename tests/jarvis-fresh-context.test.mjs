import test from 'node:test';
import assert from 'node:assert/strict';
import { assessFreshState, freshContextInstruction, wantsFreshContext } from '../src/jarvis/fresh-context.mjs';

test('fresh context intent catches report/current language',()=>{
  assert.equal(wantsFreshContext('dame el último reporte del Director'),true);
  assert.equal(wantsFreshContext('estado actual de SQX'),true);
  assert.equal(wantsFreshContext('hola'),false);
});

test('fresh state is canonical only with live complete coverage and no conflicts',()=>{
  const now=Date.parse('2026-09-20T00:00:30Z');
  const state={
    freshness:'LIVE_RECONCILED',
    stateClass:'CANONICAL',
    observedAt:'2026-09-20T00:00:00Z',
    coverage:{director:true,github:true,evidence:true,telemetry:true},
    conflicts:[]
  };
  const a=assessFreshState(state,{now,maxObservationAgeMs:60_000});
  assert.equal(a.ok,true);
  assert.equal(a.canonical,true);
  assert.equal(a.partial,false);
});

test('fresh state fails closed when stale or partial',()=>{
  const stale=assessFreshState({
    freshness:'LIVE_RECONCILED',
    stateClass:'CANONICAL',
    observedAt:'2026-09-19T23:00:00Z',
    coverage:{director:true,github:true},
    conflicts:[]
  },{now:Date.parse('2026-09-20T00:00:00Z'),maxObservationAgeMs:60_000});
  assert.equal(stale.ok,false);
  assert.equal(stale.canonical,false);

  const partial=assessFreshState({
    freshness:'LIVE_RECONCILED_PARTIAL',
    stateClass:'GLOBAL_PARTIAL_NOT_CANONICAL',
    observedAt:'2026-09-20T00:00:00Z',
    coverage:{director:true,github:false},
    conflicts:[{type:'GITHUB_NOT_LIVE'}]
  },{now:Date.parse('2026-09-20T00:00:10Z')});
  assert.equal(partial.ok,true);
  assert.equal(partial.canonical,false);
  assert.equal(partial.partial,true);
  assert.match(freshContextInstruction({},partial),/PARCIAL/);
});
