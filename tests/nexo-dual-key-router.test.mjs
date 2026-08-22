import test from 'node:test';
import assert from 'node:assert/strict';
import {chooseNexoRoute,failoverNexoRoute} from '../supabase/functions/_shared/nexo-key-router.mjs';

test('splits four consecutive run ids two and two',()=>{
  const routes=[100,101,102,103].map(runId=>chooseNexoRoute({runId,primaryPresent:true,secondaryPresent:true}).route);
  assert.deepEqual(routes,['primary','secondary','primary','secondary']);
});

test('fails closed when no key is healthy',()=>{
  assert.equal(chooseNexoRoute({runId:1}).route,null);
});

test('uses the remaining healthy key',()=>{
  assert.equal(chooseNexoRoute({runId:2,primaryPresent:true,secondaryPresent:true,primaryHealthy:false}).route,'secondary');
});

test('failover switches route without exposing secret material',()=>{
  assert.equal(failoverNexoRoute('primary',{primaryPresent:true,secondaryPresent:true}),'secondary');
  assert.equal(failoverNexoRoute('secondary',{primaryPresent:true,secondaryPresent:true}),'primary');
});
