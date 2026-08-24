#!/usr/bin/env bash
set -euo pipefail

DB_ARGS=("$@")
if [[ ${#DB_ARGS[@]} -eq 0 ]]; then
  echo 'usage: verify-migration-lineage.sh <psql connection args...>' >&2
  exit 2
fi

PREV_HEAD=''
while IFS= read -r manifest; do
  head=$(node -e "const m=require('./${manifest}'); process.stdout.write(m.database_migration_head||'')" 2>/dev/null || true)
  if [[ "$head" =~ ^[0-9]{14}$ ]] && [[ "$head" > "$PREV_HEAD" ]]; then PREV_HEAD="$head"; fi
done < <(find backups -mindepth 2 -maxdepth 2 -name manifest.json -type f 2>/dev/null | LC_ALL=C sort)

CURRENT_HEAD=$(psql "${DB_ARGS[@]}" -Atqc "select coalesce(max(version::text),'') from supabase_migrations.schema_migrations")
[[ "$CURRENT_HEAD" =~ ^[0-9]{14}$ ]] || { echo 'invalid current database migration head' >&2; exit 3; }

if [[ -z "$PREV_HEAD" ]]; then
  echo "migration lineage baseline established at $CURRENT_HEAD"
  exit 0
fi

MISSING=0
while IFS='|' read -r version name; do
  [[ -n "$version" && -n "$name" ]] || continue
  if ! find supabase/migrations -maxdepth 1 -type f -name "*_${name}.sql" -print -quit | grep -q .; then
    echo "UNVERSIONED_PRODUCTION_MIGRATION version=$version name=$name" >&2
    MISSING=$((MISSING+1))
  fi
done < <(psql "${DB_ARGS[@]}" -AtF '|' -c "select version::text,name from supabase_migrations.schema_migrations where version::text > '$PREV_HEAD' order by version")

if (( MISSING > 0 )); then
  echo "migration lineage verification failed: $MISSING production migration(s) newer than snapshot head $PREV_HEAD are absent from supabase/migrations" >&2
  exit 4
fi

echo "migration lineage verified: previous_head=$PREV_HEAD current_head=$CURRENT_HEAD"
