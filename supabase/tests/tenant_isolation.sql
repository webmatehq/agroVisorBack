-- Execute against a disposable Supabase local database: psql ... -v ON_ERROR_STOP=1 -f supabase/tests/tenant_isolation.sql
begin;
create function pg_temp.assert_true(ok boolean,label text) returns void language plpgsql as $$ begin if ok is distinct from true then raise exception 'FAIL: %',label; end if; raise notice 'PASS: %',label; end $$;
create function pg_temp.must_fail(statement text,label text) returns void language plpgsql as $$
begin
 begin execute statement; exception when others then raise notice 'PASS: % (%)',label,sqlstate; return; end;
 raise exception 'FAIL: % did not reject',label;
end $$;
insert into auth.users(id,email) values('00000000-0000-0000-0000-000000000001','test-a@example.invalid'),('00000000-0000-0000-0000-000000000002','test-b@example.invalid'),('00000000-0000-0000-0000-000000000003','test-viewer@example.invalid');
set local role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',true);
select id as org_a from public.create_organization('A') \gset
insert into public.farms(organization_id,name,latitude,longitude) values(:'org_a','Finca A',-0.2,-78.5) returning id as farm_a \gset
select id as parcel_a from public.save_parcel(null,:'org_a',:'farm_a','Parcela A','{"type":"Polygon","coordinates":[[[-78.5,-0.2],[-78.499,-0.2],[-78.499,-0.199],[-78.5,-0.199],[-78.5,-0.2]]]}') \gset
select pg_temp.assert_true((select area_ha>0 and geometry_version=1 from public.parcels where id=:'parcel_a'),'Geodetic area and initial version');
select public.save_parcel(:'parcel_a',:'org_a',:'farm_a','Renamed','{"type":"Polygon","coordinates":[[[-78.5,-0.2],[-78.499,-0.2],[-78.499,-0.199],[-78.5,-0.199],[-78.5,-0.2]]]}');
select pg_temp.assert_true((select geometry_version=1 from public.parcels where id=:'parcel_a'),'Rename keeps geometry version');
select pg_temp.must_fail(format('select public.save_parcel(null,%L,%L,''Bad'',%L)',:'org_a',:'farm_a','{"type":"Polygon","coordinates":[[[-78.5,-0.2],[-78.499,-0.199],[-78.5,-0.199],[-78.499,-0.2],[-78.5,-0.2]]]}'),'Self-intersecting geometry');
select pg_temp.must_fail(format('select public.save_parcel(null,%L,%L,''Bad'',%L)',:'org_a',:'farm_a','{"type":"Polygon","coordinates":[[[190,0],[191,0],[191,1],[190,0]]]}'),'Out-of-range coordinates');
insert into public.seasons(organization_id,parcel_id,crop,start_date) values(:'org_a',:'parcel_a','Cacao','2026-01-01') returning id as season_a \gset
insert into public.field_events(organization_id,parcel_id,season_id,type,event_date) values(:'org_a',:'parcel_a',:'season_a','inspection','2026-10-03') returning id as event_a \gset
select gen_random_uuid() as attachment_a \gset
insert into public.attachments(id,organization_id,event_id,object_path,mime_type,size_bytes) values(:'attachment_a',:'org_a',:'event_a',:'org_a'||'/'||:'event_a'||'/'||:'attachment_a','image/png',100);
update public.attachments set status='completed' where id=:'attachment_a';
select pg_temp.assert_true((select status='pending' from public.attachments where id=:'attachment_a'),'Client cannot finalize unverified photo');
select pg_temp.must_fail(format('insert into public.attachments(organization_id,event_id,object_path,mime_type,size_bytes,status) values(%L,%L,''bad'',''image/png'',100,''completed'')',:'org_a',:'event_a'),'Client cannot insert completed photo');
select id as job_a from public.enqueue_ndvi(:'parcel_a',current_date-90,current_date) \gset
select pg_temp.assert_true((select id=:'job_a' from public.enqueue_ndvi(:'parcel_a',current_date-90,current_date)),'Jobs deduplicate');
select pg_temp.must_fail('select public.claim_processing_job()','User cannot claim jobs');
select pg_temp.must_fail(format('update public.memberships set role=''owner'' where organization_id=%L',:'org_a'),'No membership write policy');
-- UPDATE without a policy affects zero rows; explicit insertion must throw.
