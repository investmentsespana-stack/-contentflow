import { validateClaimVerifiability, type VerifiableClaim } from './output-claim-verifiability';

export type ReviewDecision = { reviewApproved: boolean; evidenceRefs: readonly string[]; claims: readonly VerifiableClaim[] };
export function enforceOutputCompletion(input: ReviewDecision): { allowed: true } | { allowed: false; reason: string } {
  if (!input.reviewApproved) return { allowed:false, reason:'VALID_REVIEW_REQUIRED' };
  if (!input.evidenceRefs.some(x => x.trim())) return { allowed:false, reason:'PERSISTED_EVIDENCE_REQUIRED' };
  const claims = validateClaimVerifiability(input.claims);
  if (!claims.ok) return { allowed:false, reason:'NON_VERIFIABLE_CLAIMS' };
  return { allowed:true };
}

function tokens(text: string): string[] {
  return text.toLowerCase().match(/[a-z0-9]+/g) ?? [];
}
function tf(text: string): Map<string,number> {
  const out = new Map<string,number>();
  for (const t of tokens(text)) out.set(t,(out.get(t)??0)+1);
  return out;
}
function cosine(a: string,b: string): number {
  const av=tf(a),bv=tf(b); const keys=new Set([...av.keys(),...bv.keys()]);
  let dot=0,an=0,bn=0;
  for(const k of keys){const x=av.get(k)??0,y=bv.get(k)??0;dot+=x*y;an+=x*x;bn+=y*y;}
  return an&&bn?dot/(Math.sqrt(an)*Math.sqrt(bn)):0;
}
export function computeCoherenceScore(sentences: readonly string[]): number {
  if (sentences.length < 2) return sentences.length === 1 ? 1 : 0;
  const adjacent = sentences.slice(1).map((s,i)=>cosine(sentences[i],s));
  const discourse = sentences.slice(1).filter(s=>/\b(therefore|however|because|then|thus|also|instead|so)\b/i.test(s)).length / (sentences.length-1);
  const score = adjacent.reduce((a,b)=>a+b,0)/adjacent.length * 0.8 + discourse * 0.2;
  return Math.max(0,Math.min(1,Number(score.toFixed(6))));
}

export type EvidenceRecorder = { record(event: Record<string,unknown>): Promise<string> };
export type RollbackSchema = { required: readonly string[] };
export async function verifyRollbackPlan(plan: Record<string,unknown>, schema: RollbackSchema, recorder: EvidenceRecorder): Promise<{ok:true}|{ok:false;missing:string[];evidenceId:string}> {
  const missing=schema.required.filter(k=>plan[k]===undefined||plan[k]===null||plan[k]==='');
  if (!missing.length) return {ok:true};
  const evidenceId=await recorder.record({event:'rollback_schema_violation',missing,plan_fields:Object.keys(plan).sort()});
  if (!evidenceId.trim()) throw new Error('DURABLE_EVIDENCE_ID_REQUIRED');
  return {ok:false,missing,evidenceId};
}

export class CorrelatedEvidenceRecorder implements EvidenceRecorder {
  readonly events: Record<string,unknown>[]=[];
  constructor(private readonly builderRunId:number, private readonly sink:(event:Record<string,unknown>)=>Promise<string>){if(!Number.isInteger(builderRunId)||builderRunId<=0)throw new Error('BUILDER_RUN_ID_REQUIRED');}
  async record(event:Record<string,unknown>):Promise<string>{
    const id=await this.sink({...event,builder_run_id:this.builderRunId});
    if(!id.trim())throw new Error('DURABLE_EVIDENCE_ID_REQUIRED');
    this.events.push({...event,builder_run_id:this.builderRunId,evidence_id:id});
    return id;
  }
}
