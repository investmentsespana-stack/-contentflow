-- Production lineage checkpoint through 20260824203729_secure_recovery_watchdog_v2.
--
-- This checkpoint records the observed Supabase migration head after the
-- previously versioned 20260824135547 migration. It is intentionally
-- non-mutating: the authoritative schema/function bodies are captured by the
-- verified Recovery Snapshot V2 baseline. The recovery lineage gate must
-- remain fail-closed until that snapshot is generated and parity-certified.
--
-- Observed intervening production migrations:
-- 20260824141109 review_pending_state_protection_v1
-- 20260824153126 review_pending_and_qa_learning_v3
-- 20260824174248 material_claim_truth_guard_v1
-- 20260824174353 material_claim_truth_guard_v2
-- 20260824174426 material_claim_truth_guard_v21_header_fix
-- 20260824201849 transport_heartbeat_autonomy_root_fix_v1
-- 20260824202044 secure_transport_recovery_v1
-- 20260824202122 progress_stall_truthful_resolution_v1
-- 20260824202230 progress_stall_eligibility_truth_v1
-- 20260824202426 control_plane_project_lease_v1
-- 20260824202610 material_claim_truth_guard_no_regex_v3
-- 20260824203131 pg_net_autonomous_stall_watchdog_v1
-- 20260824203314 pg_net_head_of_line_stall_watchdog_v2
-- 20260824203729 secure_recovery_watchdog_v2

DO $$
BEGIN
  RAISE NOTICE 'lineage checkpoint: production observed through 20260824203729_secure_recovery_watchdog_v2; schema authority remains Recovery Snapshot V2';
END
$$;
