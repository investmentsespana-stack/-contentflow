-- Historical lineage reconstruction marker.
-- The live typed finalizer is preserved in the runtime catalog and will be
-- parity-checked during recovery certification before merge.
select 'durable_task_state_machine_v2_typed_finalizer lineage restored'::text;
