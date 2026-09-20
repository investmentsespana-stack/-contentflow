export const FRESH_TERMS=/\b(últim[oa]s?|actual(?:es)?|ahora|hoy|tiempo real|real[ -]?time|reporte|reporta|estado|status|avance|trabajando|haciendo|bloqueos?|pendientes?|terminad[oa]s?)\b/i;

export function wantsFreshContext(text=''){
  return FRESH_TERMS.test(String(text||''));
}

export function sourceAgeMs(observedAt,now=Date.now()){
  const t=Date.parse(String(observedAt||''));
  return Number.isFinite(t)?Math.max(0,now-t):Number.POSITIVE_INFINITY;
}

export function assessFreshState(state,{maxObservationAgeMs=60_000,now=Date.now()}={}){
  const observedAt=state?.observedAt||state?.observed_at||null;
  const ageMs=sourceAgeMs(observedAt,now);
  const coverage=state?.coverage||{};
  const conflicts=Array.isArray(state?.conflicts)?state.conflicts:[];
  const sourceFresh=state?.freshness==='LIVE_RECONCILED'||state?.freshness==='LIVE_RECONCILED_PARTIAL';
  const observationFresh=ageMs<=maxObservationAgeMs;
  const canonical=state?.stateClass==='CANONICAL'||state?.canonical===true;
  const complete=Object.values(coverage).length?Object.values(coverage).every(Boolean):canonical;
  const ok=Boolean(sourceFresh&&observationFresh);
  const canonicalNow=Boolean(ok&&canonical&&complete&&conflicts.length===0);
  return {
    ok,
    canonical:canonicalNow,
    partial:Boolean(ok&&!canonicalNow),
    observedAt,
    ageMs:Number.isFinite(ageMs)?ageMs:null,
    conflicts,
    coverage
  };
}

export function freshContextInstruction(state,assessment=assessFreshState(state)){
  const status=assessment.canonical?'CANONICAL':assessment.ok?'PARCIAL':'NO_VERIFICADO';
  return [
    'FRESH CONTEXT GATE ACTIVO.',
    'Los datos operativos presentes en el estado adjunto fueron consultados para esta respuesta y tienen prioridad sobre memoria, conversación previa o inferencias.',
    'No uses memoria para afirmar un estado actual.',
    'Si una fuente está ausente, parcial, en conflicto o fuera de frescura, indícalo explícitamente.',
    'No conviertas actividad histórica en actividad actual.',
    `CLASIFICACION_FRESCURA=${status}`,
    `OBSERVED_AT=${assessment.observedAt||'unknown'}`,
    `AGE_MS=${assessment.ageMs??'unknown'}`
  ].join(' ');
}

export function normalizeProjectState(state){
  const assessment=assessFreshState(state);
  return {state,assessment};
}
