#!/usr/bin/env bash
set -euo pipefail

SNAPSHOT_DIR=${1:-}
TARGET_DB_URL=${TARGET_DB_URL:-${2:-}}
SOURCE_DB_URL=${SOURCE_DB_URL:-}
CERTIFY_PARITY=${CERTIFY_PARITY:-0}

if [[ -z "$SNAPSHOT_DIR" || -z "$TARGET_DB_URL" ]]; then
  echo 'usage: TARGET_DB_URL=... restore-recovery-with-migration-replay.sh <snapshot-dir>' >&2
  exit 2
fi

for cmd in node psql pg_dump sha256sum python3; do
  command -v "$cmd" >/dev/null || { echo "missing required command: $cmd" >&2; exit 2; }
done

for file in manifest.json SHA256SUMS public-schema.sql runtime-control-data.sql; do
  [[ -s "$SNAPSHOT_DIR/$file" ]] || { echo "missing snapshot artifact: $file" >&2; exit 3; }
done

(
  cd "$SNAPSHOT_DIR"
  sha256sum -c SHA256SUMS
)

CUTOFF=$(node -e "const m=require('./$SNAPSHOT_DIR/manifest.json'); if(m.migration_replay_contract!=='REPLAY_SUPABASE_MIGRATIONS_AFTER_CUTOFF_V1') process.exit(3); process.stdout.write(m.repo_migration_cutoff||'')")
[[ "$CUTOFF" =~ ^[0-9]{14}_.+\.sql$ ]] || { echo 'invalid repo_migration_cutoff' >&2; exit 3; }

PUBLIC_OBJECTS=$(psql "$TARGET_DB_URL" -v ON_ERROR_STOP=1 -Atqc "select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind in ('r','p','v','m','S','f');")
if [[ "$PUBLIC_OBJECTS" != "0" ]]; then
  echo "target public schema is not empty ($PUBLIC_OBJECTS objects); refusing non-clean restore" >&2
  exit 4
fi

psql "$TARGET_DB_URL" -v ON_ERROR_STOP=1 -c 'DROP SCHEMA IF EXISTS public CASCADE;'

# Minimal restore-only Supabase platform shim. These objects live outside public and
# therefore are not included in the public schema fingerprint.
psql "$TARGET_DB_URL" -v ON_ERROR_STOP=1 <<'SQL'
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN CREATE ROLE anon NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN CREATE ROLE authenticated NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN CREATE ROLE service_role NOLOGIN; END IF;
END
$$;
CREATE SCHEMA IF NOT EXISTS auth;
CREATE TABLE IF NOT EXISTS auth.users (id uuid PRIMARY KEY);
CREATE OR REPLACE FUNCTION auth.uid()
RETURNS uuid LANGUAGE sql STABLE
AS $$ SELECT nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
SQL

psql "$TARGET_DB_URL" -v ON_ERROR_STOP=1 -f "$SNAPSHOT_DIR/public-schema.sql"
psql "$TARGET_DB_URL" -v ON_ERROR_STOP=1 -f "$SNAPSHOT_DIR/runtime-control-data.sql"

mapfile -t REPLAY_FILES < <(find supabase/migrations -maxdepth 1 -type f -name '*.sql' -printf '%f\n' | LC_ALL=C sort | awk -v cutoff="$CUTOFF" '$0 > cutoff')
for migration in "${REPLAY_FILES[@]}"; do
  echo "replay: $migration"
  psql "$TARGET_DB_URL" -v ON_ERROR_STOP=1 -f "supabase/migrations/$migration"
done

TARGET_OBJECTS=$(psql "$TARGET_DB_URL" -v ON_ERROR_STOP=1 -Atqc "select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind in ('r','p','v','m','S','f');")

canonicalize_dump() {
  sed -E \
    -e '/^\\restrict /d' \
    -e '/^\\unrestrict /d' \
    -e '/^-- Dumped from database version /d' \
    -e '/^-- Dumped by pg_dump version /d' \
    "$1"
}

report_changed_sections() {
  python3 - "$1" "$2" <<'PY'
import hashlib, re, sys

def sections(path):
    text=open(path,encoding='utf-8').read()
    hits=list(re.finditer(r'^-- Name: (.+)$', text, re.M))
    out={}
    if hits:
        out['<preamble>']=hashlib.sha256(text[:hits[0].start()].encode()).hexdigest()
    for i,m in enumerate(hits):
        end=hits[i+1].start() if i+1 < len(hits) else len(text)
        key=m.group(1).strip()
        out[key]=hashlib.sha256(text[m.start():end].encode()).hexdigest()
    return out

src,tgt=sections(sys.argv[1]),sections(sys.argv[2])
keys=sorted(set(src)|set(tgt))
changed=[k for k in keys if src.get(k)!=tgt.get(k)]
print('schema_parity_changed_sections_count='+str(len(changed)), file=sys.stderr)
for k in changed[:100]:
    side='changed' if k in src and k in tgt else ('source_only' if k in src else 'target_only')
    print(f'schema_parity_section[{side}]={k}', file=sys.stderr)
if len(changed)>100:
    print(f'schema_parity_sections_truncated={len(changed)-100}', file=sys.stderr)
PY
}

PARITY='not_requested'
SOURCE_SHA=''
TARGET_SHA=''
if [[ "$CERTIFY_PARITY" == "1" ]]; then
  [[ -n "$SOURCE_DB_URL" ]] || { echo 'SOURCE_DB_URL is required when CERTIFY_PARITY=1' >&2; exit 5; }
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  pg_dump "$SOURCE_DB_URL" --schema-only --schema=public --no-owner --file "$TMP/source.sql"
  pg_dump "$TARGET_DB_URL" --schema-only --schema=public --no-owner --file "$TMP/target.sql"
  canonicalize_dump "$TMP/source.sql" > "$TMP/source.canonical.sql"
  canonicalize_dump "$TMP/target.sql" > "$TMP/target.canonical.sql"
  SOURCE_SHA=$(sha256sum "$TMP/source.canonical.sql" | awk '{print $1}')
  TARGET_SHA=$(sha256sum "$TMP/target.canonical.sql" | awk '{print $1}')
  if [[ "$SOURCE_SHA" != "$TARGET_SHA" ]]; then
    echo "schema parity failed: source=$SOURCE_SHA target=$TARGET_SHA" >&2
    report_changed_sections "$TMP/source.canonical.sql" "$TMP/target.canonical.sql"
    exit 6
  fi
  PARITY='passed'
fi

node -e "console.log(JSON.stringify({passed:true,architecture:'RECOVERY_SNAPSHOT_MIGRATION_REPLAY_CONTRACT_V2',cutoff:process.argv[1],replayed:Number(process.argv[2]),targetPublicObjects:Number(process.argv[3]),parity:process.argv[4],sourceSchemaSha256:process.argv[5]||null,targetSchemaSha256:process.argv[6]||null}))" "$CUTOFF" "${#REPLAY_FILES[@]}" "$TARGET_OBJECTS" "$PARITY" "$SOURCE_SHA" "$TARGET_SHA"
