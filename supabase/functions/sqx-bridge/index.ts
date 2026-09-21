import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const cors={"Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type","Access-Control-Allow-Methods":"POST, OPTIONS"};
const json=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{...cors,"Content-Type":"application/json"}});
async function sha256Hex(value:string){const bytes=new TextEncoder().encode(value);const digest=await crypto.subtle.digest("SHA-256",bytes);return Array.from(new Uint8Array(digest)).map(b=>b.toString(16).padStart(2,"0")).join("");}
function randomToken(bytes=32){const data=crypto.getRandomValues(new Uint8Array(bytes));return Array.from(data).map(b=>b.toString(16).padStart(2,"0")).join("");}

const CANONICAL_ALLOWLIST=[
  "cli_help",
  "list_projects",
  "list_databanks",
  "status_project",
  "list_symbols",
  "list_instruments",
  "list_timezones",
  "count_databank",
  "export_databank",
  "list_strategies",
  "get_strategy_stats",
  "save_project_config",
  "run_vibe_nq6_smoke",
  "run_vibe_asset_research",
  "run_project",
  "stop_project",
  "pause_project",
  "resume_project",
  "load_project_config",
  "update_data",
  "add_instrument",
  "add_symbol",
  "create_databank",
  "copy_databank",
  "move_databank",
  "freeze_databank",
  "live_project_control"
] as const;

const canonicalCapabilities=(effective:string[]=CANONICAL_ALLOWLIST.slice())=>({
  transport:"sqcli_process",
  sqx_build:"142.2396",
  bridge_profile:"research_autonomy_v6_vibe_multi_asset",
  allowlist:effective,
  read_only_default:true,
  no_arbitrary_shell:true,
  no_broker_execution:true
});

Deno.serve(async(req:Request)=>{
  if(req.method==="OPTIONS") return new Response("ok",{headers:cors});
  if(req.method!=="POST") return json({error:"method_not_allowed"},405);
  const supabaseUrl=Deno.env.get("SUPABASE_URL")!;
  const serviceKey=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  if(!supabaseUrl||!serviceKey) return json({error:"server_not_configured"},500);
  const db=createClient(supabaseUrl,serviceKey,{auth:{persistSession:false}});
  let body:any;
  try{body=await req.json();}catch{return json({error:"invalid_json"},400);}
  const action=String(body?.action??"");

  if(action==="pair"){
    const code=String(body?.code??"").trim();
    const deviceName=String(body?.device_name??"StrategyQuant PC").trim().slice(0,120);
    if(!code) return json({error:"missing_pairing_code"},400);
    const codeHash=await sha256Hex(code);
    const {data:pairing,error:pe}=await db.from("trading_sqx_bridge_pairing_codes").select("code_hash,expires_at,used_at,label").eq("code_hash",codeHash).maybeSingle();
    if(pe) return json({error:"pairing_lookup_failed"},500);
    if(!pairing||pairing.used_at||new Date(pairing.expires_at).getTime()<Date.now()) return json({error:"invalid_or_expired_pairing_code"},401);
    const token=randomToken(32);
    const tokenHash=await sha256Hex(token);
    const {data:device,error:de}=await db.from("trading_sqx_bridge_devices").insert({device_name:deviceName||"StrategyQuant PC",token_hash:tokenHash,status:"ACTIVE",capabilities:canonicalCapabilities([]),last_seen_at:new Date().toISOString()}).select("id,device_name").single();
    if(de||!device) return json({error:"device_create_failed",detail:de?.message},500);
    await db.from("trading_sqx_bridge_pairing_codes").update({used_at:new Date().toISOString()}).eq("code_hash",codeHash);
    await db.from("trading_sqx_bridge_events").insert({device_id:device.id,event_type:"PAIRED",payload:{label:pairing.label??null,transport:"sqcli_process",sqx_build:"142.2396",bridge_profile:"research_autonomy_v6_vibe_multi_asset"}});
    return json({ok:true,device_id:device.id,device_name:device.device_name,bridge_token:token});
  }

  const auth=req.headers.get("Authorization")??"";
  const token=auth.startsWith("Bearer ")?auth.slice(7).trim():"";
  if(!token) return json({error:"missing_bridge_token"},401);
  const tokenHash=await sha256Hex(token);
  const {data:device,error:ae}=await db.from("trading_sqx_bridge_devices").select("id,device_name,status,last_health").eq("token_hash",tokenHash).eq("status","ACTIVE").maybeSingle();
  if(ae||!device) return json({error:"unauthorized_bridge"},401);
  const now=new Date().toISOString();
  await db.from("trading_sqx_bridge_devices").update({last_seen_at:now,updated_at:now}).eq("id",device.id);

  if(action==="heartbeat"){
    const health=body?.health&&typeof body.health==="object"?body.health:{};
    const reported=Array.isArray(health?.capabilities)?health.capabilities.map((x:unknown)=>String(x)):[];
    const effective=CANONICAL_ALLOWLIST.filter(x=>reported.includes(x));
    const normalizedHealth={...health,capabilities:effective};
    await db.from("trading_sqx_bridge_devices").update({last_health:normalizedHealth,capabilities:canonicalCapabilities(effective),last_seen_at:now,updated_at:now}).eq("id",device.id);
    return json({ok:true,device_id:device.id,capabilities:canonicalCapabilities(effective)});
  }

  if(action==="claim"){
    const reported=Array.isArray(device?.last_health?.capabilities)?device.last_health.capabilities.map((x:unknown)=>String(x)):[];
    const {data:candidates,error:ce}=await db.from("trading_sqx_bridge_commands").select("id,command_type,payload,created_at").eq("device_id",device.id).eq("state","QUEUED").order("created_at",{ascending:true}).limit(20);
    if(ce) return json({error:"claim_lookup_failed"},500);
    const command=(candidates??[]).find((c:any)=>reported.includes(String(c.command_type)));
    if(!command) return json({ok:true,command:null});
    const nonce=crypto.randomUUID();
    const {data:claimed,error:ue}=await db.from("trading_sqx_bridge_commands").update({state:"CLAIMED",claim_nonce:nonce,claimed_at:now,updated_at:now}).eq("id",command.id).eq("state","QUEUED").select("id,command_type,payload,created_at,claim_nonce").maybeSingle();
    if(ue) return json({error:"claim_update_failed"},500);
    if(!claimed) return json({ok:true,command:null});
    await db.from("trading_sqx_bridge_events").insert({device_id:device.id,command_id:claimed.id,event_type:"CLAIMED",payload:{command_type:claimed.command_type}});
    return json({ok:true,command:claimed});
  }

  if(action==="complete"){
    const commandId=String(body?.command_id??"");
    const claimNonce=String(body?.claim_nonce??"");
    const success=Boolean(body?.success);
    if(!commandId||!claimNonce) return json({error:"missing_completion_identity"},400);
    const patch:any={state:success?"SUCCEEDED":"FAILED",completed_at:now,updated_at:now,result:success?(body?.result??{}):null,error:success?null:String(body?.error??"unknown_error").slice(0,4000)};
    const {data:done,error:de}=await db.from("trading_sqx_bridge_commands").update(patch).eq("id",commandId).eq("device_id",device.id).eq("state","CLAIMED").eq("claim_nonce",claimNonce).select("id,state").maybeSingle();
    if(de) return json({error:"completion_update_failed"},500);
    if(!done) return json({error:"completion_conflict"},409);
    await db.from("trading_sqx_bridge_events").insert({device_id:device.id,command_id:commandId,event_type:success?"SUCCEEDED":"FAILED",payload:success?{}:{error:patch.error}});
    return json({ok:true,command_id:commandId,state:done.state});
  }

  return json({error:"unsupported_action"},400);
});
