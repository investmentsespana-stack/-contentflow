-- CONTENTFLOW_CHANGE_PROVENANCE_V1
-- change-class: recovery
-- repair-recipe: seal_rara_review_decision_v2_parity
-- migration-name: seal_rara_review_decision_v2_parity
-- reason: exact production/replay parity after lineage recovery
-- semantic-change: none
-- risk: low

DO $seal$
DECLARE
  f text;
BEGIN
  SELECT pg_get_functiondef(p.oid)
    INTO f
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public'
    AND p.proname='rara_apply_review_decision_v2'
    AND pg_get_function_identity_arguments(p.oid)='p_builder_run_id bigint, p_claim_token text, p_approve boolean, p_reason text';

  IF f IS NULL THEN
    RAISE EXCEPTION 'rara_apply_review_decision_v2_not_found';
  END IF;

  -- Normalize source-format drift only; SQL semantics are unchanged.
  f := regexp_replace(f, '[[:blank:]]+\n', E'\n', 'g');
  EXECUTE f;
END
$seal$;
