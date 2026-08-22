const HEX64=/^[a-f0-9]{64}$/i;

export function normalizeRecoveryReceipt(raw={}){
  const receipt=raw&&typeof raw==='object'?raw:{};
  const snapshot=receipt.snapshot&&typeof receipt.snapshot==='object'?receipt.snapshot:{};
  const restore=receipt.restore&&typeof receipt.restore==='object'?receipt.restore:{};
  return {
    version:String(receipt.version||''),
    projectKey:String(receipt.project_key||''),
    certified:receipt.certified===true,
    verifiedAt:receipt.verified_at||null,
    healthySince:receipt.healthy_since||receipt.verified_at||null,
    runtimeVersion:String(receipt.runtime_version||''),
    snapshot:{
      sha256:String(snapshot.sha256||''),
      artifact:String(snapshot.artifact||''),
      status:String(snapshot.status||'').toUpperCase()
    },
    restore:{
      status:String(restore.status||'').toUpperCase(),
      parity:String(restore.parity||''),
      verifiedAt:restore.verified_at||null
    }
  };
}

export function validateRecoveryReceipt(raw={},options={}){
  const r=normalizeRecoveryReceipt(raw);
  const nowMs=Number(options.nowMs??Date.now());
  const maxAgeMs=Math.max(1,Number(options.maxAgeMs??7*24*60*60*1000));
  const errors=[];
  if(r.version!=='recovery-certification-v1')errors.push('invalid_version');
  if(r.projectKey!=='contentflow')errors.push('wrong_project');
  if(!r.certified)errors.push('not_certified');
  if(!r.verifiedAt||!Number.isFinite(Date.parse(r.verifiedAt)))errors.push('invalid_verified_at');
  if(!r.healthySince||!Number.isFinite(Date.parse(r.healthySince)))errors.push('invalid_healthy_since');
  if(!r.runtimeVersion)errors.push('missing_runtime_version');
  if(r.snapshot.status!=='PASS')errors.push('snapshot_not_pass');
  if(!HEX64.test(r.snapshot.sha256))errors.push('invalid_snapshot_sha256');
  if(!r.snapshot.artifact)errors.push('missing_snapshot_artifact');
  if(r.restore.status!=='PASS')errors.push('restore_not_pass');
  if(r.restore.parity!=='9/9')errors.push('restore_parity_not_9_9');
  if(!r.restore.verifiedAt||!Number.isFinite(Date.parse(r.restore.verifiedAt)))errors.push('invalid_restore_verified_at');
  const ageMs=r.verifiedAt&&Number.isFinite(Date.parse(r.verifiedAt))?Math.max(0,nowMs-Date.parse(r.verifiedAt)):Number.POSITIVE_INFINITY;
  if(ageMs>maxAgeMs)errors.push('receipt_stale');
  return {valid:errors.length===0,errors,receipt:r,ageMs:Number.isFinite(ageMs)?ageMs:null};
}
