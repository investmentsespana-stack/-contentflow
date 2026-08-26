import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const H = {
  "content-type": "application/json",
  "cache-control": "no-store",
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "authorization, apikey, content-type",
  "access-control-allow-methods": "GET,POST,PUT,OPTIONS",
};
const out = (status:number, body:unknown) => new Response(JSON.stringify(body), { status, headers:H });

Deno.serve(async (req:Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers:H });
  const auth = req.headers.get("Authorization") || "";
  if (!auth.startsWith("Bearer ")) return out(401,{ok:false,error:"AUTH_REQUIRED"});
  const supabaseUrl = Deno.env.get("SUPABASE_URL") || "";
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") || "";
  if (!supabaseUrl || !anonKey) return out(500,{ok:false,error:"RUNTIME_CONFIG_MISSING"});
  const sb = createClient(supabaseUrl, anonKey, {
    global:{headers:{Authorization:auth}},
    auth:{persistSession:false,autoRefreshToken:false},
  });
  const { data:{user}, error:userErr } = await sb.auth.getUser();
  if (userErr || !user) return out(401,{ok:false,error:"INVALID_SESSION"});

  const url = new URL(req.url);
  const parts = url.pathname.split("/").filter(Boolean);
  const i = parts.indexOf("academy-learning-api");
  const route = i >= 0 ? parts.slice(i+1).join("/") : "";

  try {
    if (req.method === "GET" && route === "courses") {
      const {data,error}=await sb.from("academy_courses")
        .select("id,course_code,title,status,created_at")
        .in("status",["certified","published"]).order("created_at",{ascending:false});
      if(error) return out(400,{ok:false,error:"COURSE_QUERY_FAILED",detail:error.message});
      return out(200,{ok:true,courses:data||[]});
    }

    if (req.method === "GET" && route === "enrollments") {
      const {data,error}=await sb.from("academy_enrollments")
        .select("id,tenant_id,course_id,status,enrolled_at,completed_at")
        .eq("user_id",user.id).order("enrolled_at",{ascending:false});
      if(error) return out(400,{ok:false,error:"ENROLLMENT_QUERY_FAILED",detail:error.message});
      return out(200,{ok:true,enrollments:data||[]});
    }

    if (req.method === "GET" && route === "certifications") {
      const {data,error}=await sb.from("academy_certifications")
        .select("id,course_id,course_version_id,status,issued_at,expires_at,evidence")
        .eq("user_id",user.id).order("issued_at",{ascending:false});
      if(error) return out(400,{ok:false,error:"CERTIFICATION_QUERY_FAILED",detail:error.message});
      return out(200,{ok:true,certifications:data||[]});
    }

    if (req.method === "GET" && route === "tutor-context") {
      const courseId=url.searchParams.get("course_id");
      const maxChars=Math.max(500,Math.min(20000,Number(url.searchParams.get("max_chars")||8000)));
      const {data,error}=await sb.rpc("academy_tutor_get_context",{
        p_course_id: courseId || null,
        p_include_lesson_content: true,
        p_max_context_chars: maxChars,
      });
      if(error) return out(400,{ok:false,error:"TUTOR_CONTEXT_FAILED",detail:error.message});
      return out(200,data);
    }

    if (req.method === "POST" && route === "enroll") {
      const body=await req.json().catch(()=>({}));
      const courseId=String(body.course_id||"");
      if(!courseId) return out(400,{ok:false,error:"COURSE_ID_REQUIRED"});
      const {data:course,error:courseErr}=await sb.from("academy_courses")
        .select("id,tenant_id,status").eq("id",courseId).maybeSingle();
      if(courseErr || !course) return out(404,{ok:false,error:"COURSE_NOT_VISIBLE"});
      if(!["certified","published"].includes(String(course.status))) return out(409,{ok:false,error:"COURSE_NOT_ENROLLABLE"});
      const {data,error}=await sb.from("academy_enrollments").upsert({
        tenant_id:course.tenant_id,user_id:user.id,course_id:course.id,status:"active"
      },{onConflict:"tenant_id,user_id,course_id"}).select("id,tenant_id,course_id,status,enrolled_at").single();
      if(error) return out(400,{ok:false,error:"ENROLL_FAILED",detail:error.message});
      return out(201,{ok:true,enrollment:data});
    }

    if ((req.method === "POST" || req.method === "PUT") && route === "progress") {
      const body=await req.json().catch(()=>({}));
      const lessonId=String(body.lesson_id||"");
      const progressStatus=String(body.status||"");
      if(!lessonId || !["not_started","in_progress","completed"].includes(progressStatus)) return out(400,{ok:false,error:"INVALID_PROGRESS_INPUT"});
      const {data:lesson,error:lessonErr}=await sb.from("academy_lessons").select("id,tenant_id,module_id").eq("id",lessonId).maybeSingle();
      if(lessonErr || !lesson) return out(404,{ok:false,error:"LESSON_NOT_VISIBLE"});
      const {data:module,error:moduleErr}=await sb.from("academy_modules").select("course_version_id").eq("tenant_id",lesson.tenant_id).eq("id",lesson.module_id).maybeSingle();
      if(moduleErr || !module) return out(404,{ok:false,error:"MODULE_NOT_VISIBLE"});
      const {data:version,error:versionErr}=await sb.from("academy_course_versions").select("course_id").eq("tenant_id",lesson.tenant_id).eq("id",module.course_version_id).maybeSingle();
      if(versionErr || !version) return out(404,{ok:false,error:"VERSION_NOT_VISIBLE"});
      const {data:enrollment}=await sb.from("academy_enrollments").select("id").eq("tenant_id",lesson.tenant_id).eq("user_id",user.id).eq("course_id",version.course_id).eq("status","active").maybeSingle();
      if(!enrollment) return out(403,{ok:false,error:"ACTIVE_ENROLLMENT_REQUIRED"});
      const now=new Date().toISOString();
      const row:any={tenant_id:lesson.tenant_id,user_id:user.id,lesson_id:lesson.id,status:progressStatus,updated_at:now};
      if(progressStatus==="in_progress") row.started_at=now;
      if(progressStatus==="completed") row.completed_at=now;
      const {data,error}=await sb.from("academy_progress").upsert(row,{onConflict:"tenant_id,user_id,lesson_id"}).select("tenant_id,lesson_id,status,started_at,completed_at,updated_at").single();
      if(error) return out(400,{ok:false,error:"PROGRESS_WRITE_FAILED",detail:error.message});
      return out(200,{ok:true,progress:data});
    }

    if (req.method === "POST" && route === "assessment-submit") {
      const body=await req.json().catch(()=>({}));
      const assessmentId=String(body.assessment_id||"");
      if(!assessmentId || typeof body.payload !== "object") return out(400,{ok:false,error:"INVALID_ASSESSMENT_INPUT"});
      const {data:assessment,error:aErr}=await sb.from("academy_assessments").select("id,tenant_id,course_version_id").eq("id",assessmentId).maybeSingle();
      if(aErr || !assessment) return out(404,{ok:false,error:"ASSESSMENT_NOT_VISIBLE"});
      const {data:version}=await sb.from("academy_course_versions").select("course_id").eq("tenant_id",assessment.tenant_id).eq("id",assessment.course_version_id).maybeSingle();
      if(!version) return out(404,{ok:false,error:"VERSION_NOT_VISIBLE"});
      const {data:enrollment}=await sb.from("academy_enrollments").select("id").eq("tenant_id",assessment.tenant_id).eq("user_id",user.id).eq("course_id",version.course_id).eq("status","active").maybeSingle();
      if(!enrollment) return out(403,{ok:false,error:"ACTIVE_ENROLLMENT_REQUIRED"});
      const {data,error}=await sb.from("academy_assessment_submissions").insert({tenant_id:assessment.tenant_id,assessment_id:assessment.id,user_id:user.id,payload:body.payload,status:"submitted"}).select("id,assessment_id,status,submitted_at").single();
      if(error) return out(400,{ok:false,error:"ASSESSMENT_SUBMIT_FAILED",detail:error.message});
      return out(201,{ok:true,submission:data});
    }

    return out(404,{ok:false,error:"ROUTE_NOT_FOUND",route,method:req.method});
  } catch (e) {
    return out(500,{ok:false,error:"UNHANDLED",detail:String(e)});
  }
});
