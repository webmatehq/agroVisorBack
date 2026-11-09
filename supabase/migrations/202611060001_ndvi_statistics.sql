alter table public.satellite_observations add column if not exists ndvi_stddev double precision;
alter table public.satellite_observations add column if not exists ndvi_median double precision;
alter table public.satellite_observations add column if not exists ndvi_histogram jsonb;
update storage.buckets set allowed_mime_types = array['image/png','image/webp'] where id = 'ndvi-rasters';

create or replace function public.commit_satellite_observation(p_job_id uuid,p_lease_token uuid,p_observation jsonb) returns boolean
language plpgsql security definer set search_path='' as $$
declare j public.processing_jobs; p public.parcels;
begin
 select * into j from public.processing_jobs where id=p_job_id and lease_token=p_lease_token and status='processing' and lease_until>now() for update;
 if j.id is null then return false; end if;
 select * into p from public.parcels where id=j.parcel_id for share;
 if p.geometry_version<>j.geometry_version or p.archived_at is not null or not exists(select 1 from public.farms where id=p.farm_id and archived_at is null) then return false; end if;
 if (p_observation->>'from_date')::date<j.from_date or (p_observation->>'to_date')::date>j.to_date then raise exception 'Observation outside job interval' using errcode='22023'; end if;
 insert into public.satellite_observations(organization_id,parcel_id,geometry_version,from_date,to_date,ndvi_mean,ndvi_min,ndvi_max,ndvi_stddev,ndvi_median,ndvi_histogram,valid_fraction,quality,raster_path,bounds,processing_version)
 values(j.organization_id,j.parcel_id,j.geometry_version,(p_observation->>'from_date')::date,(p_observation->>'to_date')::date,(p_observation->>'ndvi_mean')::double precision,(p_observation->>'ndvi_min')::double precision,(p_observation->>'ndvi_max')::double precision,(p_observation->>'ndvi_stddev')::double precision,(p_observation->>'ndvi_median')::double precision,p_observation->'ndvi_histogram',(p_observation->>'valid_fraction')::double precision,p_observation->>'quality',p_observation->>'raster_path',p_observation->'bounds',coalesce(p_observation->>'processing_version','ndvi-v1'))
 on conflict(parcel_id,geometry_version,from_date,to_date,processing_version) do update set ndvi_mean=excluded.ndvi_mean,ndvi_min=excluded.ndvi_min,ndvi_max=excluded.ndvi_max,ndvi_stddev=excluded.ndvi_stddev,ndvi_median=excluded.ndvi_median,ndvi_histogram=excluded.ndvi_histogram,valid_fraction=excluded.valid_fraction,quality=excluded.quality,raster_path=excluded.raster_path,bounds=excluded.bounds;
 return true;
end $$;
