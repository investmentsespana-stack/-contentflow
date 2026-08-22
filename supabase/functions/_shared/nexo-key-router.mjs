export function chooseNexoRoute({runId=0,primaryPresent=false,secondaryPresent=false,primaryHealthy=true,secondaryHealthy=true}={}){
  const available=[];
  if(primaryPresent&&primaryHealthy)available.push('primary');
  if(secondaryPresent&&secondaryHealthy)available.push('secondary');
  if(available.length===0)return {route:null,reason:'no_healthy_key'};
  if(available.length===1)return {route:available[0],reason:'single_healthy_key'};
  return {route:(Math.abs(Number(runId)||0)%2===0?'primary':'secondary'),reason:'deterministic_50_50'};
}

export function failoverNexoRoute(route,{primaryPresent=false,secondaryPresent=false}={}){
  if(route==='primary'&&secondaryPresent)return 'secondary';
  if(route==='secondary'&&primaryPresent)return 'primary';
  return null;
}

export function sanitizeNexoRoute(route){
  return route==='secondary'?'secondary':'primary';
}
