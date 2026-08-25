-- Historical lineage reconstruction marker.
-- This was a data migration for pre-existing Avatar state. Recovery replay does
-- not copy production rows; the schema/state semantics are restored by V2.
select 'durable_task_state_machine_v2_migrate_existing_avatar_state lineage restored'::text;
