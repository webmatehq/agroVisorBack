-- Run only against the disposable local database; all fixture writes roll back.
begin;
do $$
<<fixture>>
declare
  user_id uuid := gen_random_uuid();
  org_id uuid := gen_random_uuid();
  farm_id uuid := gen_random_uuid();
  parcel_id uuid := gen_random_uuid();
  job_id uuid := gen_random_uuid();
  lease_id uuid := gen_random_uuid();
  committed boolean;
begin
  insert into auth.users(id,email) values(user_id, 'ndvi-test-' || user_id || '@example.invalid');
  insert into public.organizations(id,name,created_by) values(org_id,'Prueba local',user_id);
  insert into public.farms(id,organization_id,name,latitude,longitude,timezone) values(farm_id,org_id,'Prueba',-0.2,-78.5,'America/Guayaquil');
  insert into public.parcels(id,organization_id,farm_id,name,geometry_geojson) values(parcel_id,org_id,farm_id,'Prueba', '{"type":"Polygon","coordinates":[[[-78.5,-0.2],[-78.499,-0.2],[-78.499,-0.199],[-78.5,-0.199],[-78.5,-0.2]]]}');
  insert into public.processing_jobs(id,organization_id,parcel_id,geometry_version,from_date,to_date,status,lease_token,lease_until) values(job_id,org_id,parcel_id,1,current_date-1,current_date,'processing',lease_id,now()+interval '10 minutes');
  select public.commit_satellite_observation(job_id,lease_id,jsonb_build_object('from_date',current_date-1,'to_date',current_date-1,'ndvi_mean',0.4,'ndvi_min',0.1,'ndvi_max',0.8,'ndvi_stddev',0.12,'ndvi_median',0.39,'ndvi_histogram',jsonb_build_array(jsonb_build_object('low',0.2,'high',0.4,'count',20)),'valid_fraction',0.9,'quality','valid','processing_version','rgb-ndvi-v2')) into committed;
  if committed is distinct from true or not exists (select 1 from public.satellite_observations o where o.parcel_id=fixture.parcel_id and ndvi_stddev=0.12 and ndvi_median=0.39 and ndvi_histogram->0->>'count'='20') then
    raise exception 'Satellite observation statistics were not persisted';
  end if;
  if not exists (select 1 from storage.buckets where id='ndvi-rasters' and 'image/webp'=any(allowed_mime_types)) then
    raise exception 'NDVI storage bucket does not allow WebP';
  end if;
end $$;
rollback;
