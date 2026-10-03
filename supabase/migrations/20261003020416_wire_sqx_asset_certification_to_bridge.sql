-- Reconciled from supabase_migrations.schema_migrations by recovery automation.
-- Source: canonical production migration history; no credentials are emitted.

create or replace function public.trading_sqx_sync_asset_certification()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_asset text; v_count integer; v_project text; v_db text;
begin
 if new.state not in ('SUCCEEDED','FAILED') or old.state=new.state then return new; end if;
 v_project := nullif(trim(coalesce(new.payload->>'project','')),'');
 v_db := nullif(trim(coalesce(new.payload->>'databank','')),'');
 select asset_key into v_asset from public.trading_sqx_asset_certification where project_name=v_project limit 1;
 if v_asset is null then return new; end if;
 if new.state='FAILED' then
   update public.trading_sqx_asset_certification set status='BLOCKED',last_error=coalesce(new.error,'SQX_COMMAND_FAILED'),evidence_command_id=new.id,updated_at=now() where asset_key=v_asset;
   return new;
 end if;
 if new.command_type='run_project' then
   update public.trading_sqx_asset_certification set status='RUNNING',last_error=null,evidence_command_id=new.id,updated_at=now() where asset_key=v_asset;
 elsif new.command_type='count_databank' and v_db=(select final_databank from public.trading_sqx_asset_certification where asset_key=v_asset) then
   begin
     v_count := coalesce((new.result->>'records')::integer,(new.result->>'count')::integer,0);
   exception when others then v_count := 0; end;
   update public.trading_sqx_asset_certification set final_count=v_count,status=case when v_count>0 then 'VERIFYING' else 'PENDING' end,last_error=null,evidence_command_id=new.id,updated_at=now() where asset_key=v_asset;
 end if;
 return new;
end $$;
drop trigger if exists trg_trading_sqx_sync_asset_certification on public.trading_sqx_bridge_commands;
create trigger trg_trading_sqx_sync_asset_certification after update of state on public.trading_sqx_bridge_commands for each row execute function public.trading_sqx_sync_asset_certification();
