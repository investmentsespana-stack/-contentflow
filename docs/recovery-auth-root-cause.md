# Recovery authentication root-cause correction

Canonical recovery no longer depends on embedding, parsing, reconstructing, or double-encoding the PostgreSQL password inside a connection URI.

The supported path is Supavisor Session Pooler over IPv4 using fixed non-secret connection coordinates and `PGPASSWORD` for authentication. `SUPABASE_DB_PASSWORD` is the preferred dedicated secret. `SUPABASE_DB_URL` remains a temporary compatibility source only; its password component is tested as both raw and once percent-decoded without logging either candidate.

This removes URL parser semantics from the authentication boundary and prevents reserved password characters from changing the credential before PostgreSQL receives it.
