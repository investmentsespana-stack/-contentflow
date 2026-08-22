#!/usr/bin/env python3
import os, subprocess, urllib.parse, pathlib, sys

HOST='aws-0-us-east-1.pooler.supabase.com'
PORT='5432'
USER='postgres.koqpyfvnprmirqviafzq'
DB='postgres'
OUT=pathlib.Path('/tmp/contentflow-recovery-db-password')
SRC=pathlib.Path('/tmp/contentflow-recovery-password-source')

def test_password(password: str) -> bool:
    if not password:
        return False
    env=os.environ.copy()
    env['PGPASSWORD']=password
    env['PGSSLMODE']='require'
    p=subprocess.run(['psql','-h',HOST,'-p',PORT,'-U',USER,'-d',DB,'-Atqc','select 1'],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=12)
    return p.returncode==0

candidates=[]
dedicated=os.environ.get('SUPABASE_DB_PASSWORD','')
if dedicated:
    candidates.append(('dedicated_secret',dedicated))
legacy=os.environ.get('SUPABASE_DB_URL','').strip()
for prefix in ('postgresql://postgres:','postgres://postgres:'):
    marker='@db.koqpyfvnprmirqviafzq.supabase.co:5432/'
    if legacy.startswith(prefix) and marker in legacy:
        raw=legacy[len(prefix):legacy.rfind(marker)]
        if raw:
            candidates.append(('legacy_raw',raw))
            decoded=urllib.parse.unquote(raw)
            if decoded != raw:
                candidates.append(('legacy_percent_decoded',decoded))
        break

seen=set()
for source,password in candidates:
    if password in seen:
        continue
    seen.add(password)
    try:
        if test_password(password):
            OUT.write_text(password)
            OUT.chmod(0o600)
            SRC.write_text(source)
            SRC.chmod(0o600)
            sys.exit(0)
    except Exception:
        pass

SRC.write_text('none_valid')
SRC.chmod(0o600)
sys.exit(2)
