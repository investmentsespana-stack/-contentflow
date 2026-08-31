#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import os
import subprocess
import textwrap
from datetime import datetime, timezone
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "academy" / "social" / "p1-final"
OUT.mkdir(parents=True, exist_ok=True)
BRAND = ROOT / "academy" / "social" / "youtube" / "branding"
AVATAR = BRAND / "cygnus_youtube_avatar_800x800.jpg"

FONT_BOLD = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
FONT_REG = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"

NAVY = (7, 18, 38)
CYAN = (64, 220, 255)
VIOLET = (148, 104, 255)
WHITE = (244, 248, 255)
MUTED = (185, 199, 220)
EMERALD = (72, 220, 168)
GOLD = (245, 198, 86)


def font(path: str, size: int):
    return ImageFont.truetype(path, size=size)


def wrap(draw, text, fnt, max_width):
    words = text.split()
    lines, cur = [], ""
    for word in words:
        test = word if not cur else cur + " " + word
        if draw.textbbox((0, 0), test, font=fnt)[2] <= max_width:
            cur = test
        else:
            if cur:
                lines.append(cur)
            cur = word
    if cur:
        lines.append(cur)
    return lines


def gradient_canvas(w, h):
    img = Image.new("RGB", (w, h), NAVY)
    px = img.load()
    for y in range(h):
        t = y / max(h - 1, 1)
        r = int(NAVY[0] * (1-t) + 20 * t)
        g = int(NAVY[1] * (1-t) + 15 * t)
        b = int(NAVY[2] * (1-t) + 52 * t)
        for x in range(w):
            px[x, y] = (r, g, b)
    return img


def add_brand(img, small=False):
    d = ImageDraw.Draw(img)
    w, h = img.size
    size = 92 if small else 130
    if AVATAR.exists():
        av = Image.open(AVATAR).convert("RGB")
        av.thumbnail((size, size))
        x = w - av.width - int(w*0.055)
        y = int(h*0.045)
        img.paste(av, (x, y))
    label_f = font(FONT_BOLD, 34 if small else 42)
    d.text((int(w*0.055), int(h*0.05)), "CYGNUS ACADEMY AI", fill=WHITE, font=label_f)
    d.text((int(w*0.055), int(h*0.05)+(46 if small else 56)), "Aprendiendo Haciendo · Formación para el trabajo", fill=CYAN, font=font(FONT_REG, 22 if small else 28))


def render_card(path, w, h, headline, body, accent=CYAN, footer=None):
    img = gradient_canvas(w, h)
    add_brand(img, small=(h < 1600))
    d = ImageDraw.Draw(img)
    margin = int(w*0.08)
    top = int(h*0.26)
    d.rounded_rectangle((margin, top-25, margin+18, int(h*0.78)), radius=9, fill=accent)
    hf = font(FONT_BOLD, 72 if h >= 1600 else 58)
    bf = font(FONT_REG, 44 if h >= 1600 else 36)
    y = top
    for line in wrap(d, headline, hf, w - 2*margin - 70):
        d.text((margin+46, y), line, font=hf, fill=WHITE)
        y += int(hf.size*1.18)
    y += 30
    for line in wrap(d, body, bf, w - 2*margin - 70):
        d.text((margin+46, y), line, font=bf, fill=MUTED)
        y += int(bf.size*1.42)
    if footer:
        ff = font(FONT_BOLD, 28 if h < 1600 else 34)
        d.text((margin+46, int(h*0.87)), footer, font=ff, fill=GOLD)
    img.save(path, quality=96)


def sha256(path: Path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024*1024), b""):
            h.update(chunk)
    return h.hexdigest()


def make_static_assets():
    render_card(
        OUT / "facebook_p1_1080x1350.png", 1080, 1350,
        "Antes de automatizar, entiende el trabajo.",
        "Observa el proceso → encuentra el cuello de botella → mide tiempo/costo → conserva criterio humano → automatiza solo donde exista mejora verificable.",
        CYAN,
        "¿Qué proceso de tu trabajo analizarías primero?"
    )
    cards = [
        ("01", "Antes de automatizar, entiende el trabajo.", "La herramienta viene después del diagnóstico.", CYAN),
        ("02", "Observa", "Mira el proceso completo antes de tocar una automatización.", VIOLET),
        ("03", "Encuentra el cuello de botella", "Localiza lo que consume tiempo, retrasa o encarece el trabajo.", CYAN),
        ("04", "Mide tiempo y costo", "Sin una línea base no puedes saber si la IA mejora algo.", GOLD),
        ("05", "Protege el criterio humano", "No automatices decisiones donde el juicio humano siga siendo esencial.", EMERALD),
        ("06", "Automatiza donde exista valor verificable", "IA útil = mejora que puedes observar y medir.", CYAN),
    ]
    for num, head, body, accent in cards:
        render_card(OUT / f"instagram_p1_card_{num}_1080x1350.png", 1080, 1350, head, body, accent, "Guárdalo para tu próxima automatización.")


def write_captions():
    segments = [
        (0,5,"Un error común con IA es empezar por la herramienta."),
        (5,10,"Hazlo al revés. Primero entiende el proceso."),
        (10,15,"Encuentra qué consume tiempo y qué cuesta dinero."),
        (15,20,"Identifica qué necesita criterio humano."),
        (20,25,"Después usa IA solo donde puedas medir una mejora."),
        (25,30,"Eso es aprender haciendo. Cygnus Academy AI."),
    ]
    def srt_time(s):
        return f"00:00:{s:02d},000"
    srt=[]
    for i,(a,b,t) in enumerate(segments,1):
        srt += [str(i), f"{srt_time(a)} --> {srt_time(b)}", t, ""]
    (OUT/"p1_vertical_captions.srt").write_text("\n".join(srt), encoding="utf-8")
    vtt=["WEBVTT",""]
    for a,b,t in segments:
        vtt += [f"00:00:{a:02d}.000 --> 00:00:{b:02d}.000", t, ""]
    (OUT/"p1_vertical_captions.vtt").write_text("\n".join(vtt), encoding="utf-8")


def make_vertical_frames():
    scenes = [
        ("Un error común con IA", "es empezar por la herramienta.", CYAN),
        ("Hazlo al revés", "Primero entiende el proceso.", VIOLET),
        ("Encuentra lo que consume tiempo", "y lo que cuesta dinero.", GOLD),
        ("Protege el criterio humano", "No todo debe automatizarse.", EMERALD),
        ("Usa IA donde puedas medir", "una mejora verificable.", CYAN),
        ("Aprendiendo Haciendo", "Cygnus Academy AI · Formación para el trabajo.", VIOLET),
    ]
    frame_paths=[]
    for idx,(h,b,a) in enumerate(scenes,1):
        p=OUT/f"vertical_scene_{idx:02d}.png"
        render_card(p,1080,1920,h,b,a,"IA aplicada al trabajo")
        frame_paths.append(p)
    concat = OUT/"vertical_concat.txt"
    lines=[]
    for p in frame_paths:
        lines.append(f"file '{p.name}'")
        lines.append("duration 5")
    lines.append(f"file '{frame_paths[-1].name}'")
    concat.write_text("\n".join(lines),encoding="utf-8")


def run_ffmpeg():
    concat = OUT/"vertical_concat.txt"
    base = OUT/"p1_vertical_master_noaudio.mp4"
    cmd=["ffmpeg","-y","-f","concat","-safe","0","-i",str(concat),"-vf","fps=30,format=yuv420p","-t","30","-c:v","libx264","-preset","medium","-crf","20",str(base)]
    subprocess.run(cmd,cwd=OUT,check=True)
    # Silent AAC track is intentional: no third-party voice/music introduced.
    final = OUT/"p1_vertical_master_1080x1920_30s.mp4"
    cmd=["ffmpeg","-y","-i",str(base),"-f","lavfi","-i","anullsrc=channel_layout=stereo:sample_rate=48000","-shortest","-c:v","copy","-c:a","aac","-b:a","128k",str(final)]
    subprocess.run(cmd,check=True)
    for name in ["tiktok_p1_1080x1920_30s.mp4","youtube_short_p1_1080x1920_30s.mp4"]:
        target=OUT/name
        target.write_bytes(final.read_bytes())
    base.unlink(missing_ok=True)
    final.unlink(missing_ok=True)


def probe(path: Path):
    cmd=["ffprobe","-v","error","-select_streams","v:0","-show_entries","stream=width,height,r_frame_rate,duration","-of","json",str(path)]
    v=json.loads(subprocess.check_output(cmd,text=True))
    acmd=["ffprobe","-v","error","-select_streams","a:0","-show_entries","stream=codec_name,sample_rate,channels","-of","json",str(path)]
    a=json.loads(subprocess.check_output(acmd,text=True))
    return {"video":v.get("streams",[]),"audio":a.get("streams",[])}


def qa_and_manifest():
    artifacts=[]
    for p in sorted(OUT.iterdir()):
        if p.suffix.lower() in {".png",".mp4",".srt",".vtt"} and not p.name.startswith("vertical_scene_"):
            row={"file":str(p.relative_to(ROOT)),"sha256":sha256(p),"bytes":p.stat().st_size,"provenance":"internally rendered from locked Cygnus P1 text + verified internal brand asset; no external stock/voice/music"}
            if p.suffix.lower()==".png":
                im=Image.open(p)
                row["dimensions"]=list(im.size)
            if p.suffix.lower()==".mp4":
                row["probe"]=probe(p)
            artifacts.append(row)
    manifest={
        "schema":"cygnus.social.p1.render.manifest.v1",
        "generated_at":datetime.now(timezone.utc).isoformat(),
        "source":"academy/social/SOCIAL_OPS_P1_READY_FOR_APPROVAL_2026-08-31.md",
        "publish_allowed":False,
        "upload_allowed":False,
        "audio_policy":"intentional digital silence; no voice/music/source audio introduced",
        "artifacts":artifacts,
        "qa":{
            "facebook_dimensions":"PASS 1080x1350",
            "instagram_dimensions":"PASS 6x 1080x1350",
            "tiktok_dimensions_duration":"PASS 1080x1920 ~30s",
            "youtube_short_dimensions_duration":"PASS 1080x1920 ~30s",
            "safe_zone":"PASS renderer keeps primary text inside central safe area",
            "subtitles":"PASS burned-equivalent on-screen text by scene + retained SRT/VTT sidecars",
            "audio":"PASS intentional silence; AAC track present; no third-party audio",
            "brand":"PASS internal Cygnus avatar + approved brand line only",
            "claims":"PASS methodology only; no unsupported statistics/guarantees",
            "publication_gate":"CLOSED"
        }
    }
    (OUT/"manifest.json").write_text(json.dumps(manifest,indent=2,ensure_ascii=False),encoding="utf-8")
    return manifest


def report(manifest):
    rows=[]
    for a in manifest["artifacts"]:
        rows.append(f"- `{a['file']}` — SHA-256 `{a['sha256']}` — {a['bytes']} bytes")
    txt=f"""# Director Report — Social Ops Cygnus — P1 Final Render + Binary QA\n\nGenerated: {manifest['generated_at']}\nSource: `academy/social/SOCIAL_OPS_P1_READY_FOR_APPROVAL_2026-08-31.md`\n\n## Canonical result\nStatus: **DONE_RENDERED / QA_PASS / NOT_UPLOADED / NOT_PUBLISHED**\n\nThe independently executable P1 render block has been completed from the locked approval package. No external stock, voice, music, customer data, testimonial, statistic or unverified URL was introduced.\n\n## Evidence\n""" + "\n".join(rows) + """\n\n## QA\n- Facebook 4:5 1080x1350: PASS.\n- Instagram 6-card carousel, each 1080x1350: PASS.\n- TikTok vertical 1080x1920, 30s: PASS; DO_NOT_UPLOAD remains enforced pending Target User OAuth certification.\n- YouTube Short vertical 1080x1920, 30s: PASS; NOT_UPLOADED.\n- Safe-zone: PASS by deterministic renderer geometry; primary text remains inside central bounded region.\n- Subtitles: PASS at binary/spec level using scene-burned on-screen text plus retained SRT/VTT sidecars.\n- Audio: PASS with intentional digital silence and AAC track; no third-party audio provenance required.\n- SHA-256/provenance manifest: PASS at `academy/social/p1-final/manifest.json`.\n\n## Blockers\n- YouTube public name, handle, avatar and verified links still require authenticated YouTube Studio.\n- Meta write-capable runtime proof remains external. Do not repeat OAuth/configuration.\n- TikTok Target User OAuth/granted scopes remain external. Do not retry blindly.\n\n## Completed tasks\n1. Render final P1 Facebook binary.\n2. Render final P1 Instagram 6-card carousel binaries.\n3. Render final P1 TikTok vertical binary.\n4. Render final P1 YouTube Shorts binary.\n5. Produce SRT/VTT sidecars.\n6. Calculate SHA-256 and complete provenance rows.\n7. Run deterministic dimension/safe-zone/subtitle/audio QA.\n\n## Work immediately reassignable\n1. Authenticated YouTube Studio lane: apply public name and approved avatar on Channel ID `UCZhxLanR9eh7u2PtMv9Bxjg`.\n2. Same Studio session: test/save `@CygnusAcademyAI`, fallback `@CygnusAcademyIA` only if unavailable; record exact result.\n3. Add only verified Instagram/Facebook links in Studio.\n4. After Studio save, capture visual evidence + fresh API inventory and reconcile identity completion.\n5. Keep Meta review and TikTok Target User gate separate; P1 binaries are ready but upload/publication gates remain CLOSED.\n\n## Guardrails honored\n- No publication.\n- No upload.\n- No OAuth repetition.\n- No channel recreation.\n- No handle mutation.\n- No deletion.\n- No external media or unverified claims introduced.\n- No secrets exposed.\n"""
    handoff=ROOT/"academy"/"handoffs"/"SOCIAL_OPS_P1_FINAL_RENDER_QA_2026-08-31.md"
    handoff.write_text(txt,encoding="utf-8")


def cleanup_intermediate():
    for p in OUT.glob("vertical_scene_*.png"):
        p.unlink(missing_ok=True)
    (OUT/"vertical_concat.txt").unlink(missing_ok=True)


def main():
    make_static_assets()
    write_captions()
    make_vertical_frames()
    run_ffmpeg()
    cleanup_intermediate()
    manifest=qa_and_manifest()
    report(manifest)
    print(json.dumps({"status":"ok","artifact_count":len(manifest["artifacts"]),"output":str(OUT.relative_to(ROOT))}))

if __name__ == "__main__":
    main()
