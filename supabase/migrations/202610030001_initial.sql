create extension if not exists postgis with schema extensions;
create extension if not exists pgcrypto with schema extensions;

create table public.profiles (
 id uuid primary key references auth.users(id) on delete cascade,
 display_name text not null default '', language text not null default 'es',
 created_at timestamptz not null default now()
);
create table public.organizations (
 id uuid primary key default gen_random_uuid(), name text not null check(length(trim(name)) between 1 and 120),
 created_by uuid not null references auth.users(id), created_at timestamptz not null default now()
);
create table public.memberships (
 organization_id uuid not null references public.organizations(id), user_id uuid not null references auth.users(id),
 role text not null check(role in ('owner','editor','viewer')), created_at timestamptz not null default now(),
 primary key(organization_id,user_id)
);
create function public.has_org_access(org uuid, write_access boolean default false) returns boolean
language sql stable security definer set search_path = '' as $$
 select exists(select 1 from public.memberships m where m.organization_id=org and m.user_id=auth.uid()
 and (not write_access or m.role in ('owner','editor')))
$$;
create function public.is_org_owner(org uuid) returns boolean
language sql stable security definer set search_path = '' as $$
 select exists(select 1 from public.memberships m where m.organization_id=org and m.user_id=auth.uid() and m.role='owner')
$$;
create function public.create_organization(name text) returns public.organizations
language plpgsql security definer set search_path = '' as $$
declare result public.organizations;
begin
 if auth.uid() is null then raise exception 'Authentication required' using errcode='42501'; end if;
 insert into public.organizations(name,created_by) values(name,auth.uid()) returning * into result;
 insert into public.memberships(organization_id,user_id,role) values(result.id,auth.uid(),'owner');
 insert into public.profiles(id) values(auth.uid()) on conflict do nothing;
 return result;
end $$;
create table public.farms (
 id uuid primary key default gen_random_uuid(), organization_id uuid not null references public.organizations(id),
 name text not null check(length(trim(name)) between 1 and 120), latitude double precision not null check(latitude between -90 and 90),
 longitude double precision not null check(longitude between -180 and 180),
 timezone text not null default 'America/Guayaquil' check(timezone in ('America/Guayaquil','Pacific/Galapagos')),
 archived_at timestamptz, created_at timestamptz not null default now(), updated_at timestamptz not null default now(), unique(id,organization_id)
);
create table public.parcels (
 id uuid primary key default gen_random_uuid(), organization_id uuid not null references public.organizations(id), farm_id uuid not null,
 name text not null check(length(trim(name)) between 1 and 120), geom extensions.geometry(MultiPolygon,4326) not null,
 geometry_geojson jsonb not null, area_ha double precision not null check(area_ha>0), geometry_version integer not null default 1,
 archived_at timestamptz, created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 unique(id,organization_id), foreign key(farm_id,organization_id) references public.farms(id,organization_id)
);
create index parcels_geom_idx on public.parcels using gist(geom);
create table public.seasons (
 id uuid primary key default gen_random_uuid(), organization_id uuid not null references public.organizations(id), parcel_id uuid not null,
 crop text not null check(length(trim(crop)) between 1 and 120), variety text, start_date date not null, end_date date,
 status text not null default 'active' check(status in ('planned','active','completed')), created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 check(end_date is null or end_date>=start_date), unique(id,organization_id), unique(id,parcel_id,organization_id),
 foreign key(parcel_id,organization_id) references public.parcels(id,organization_id)
);
create table public.field_events (
 id uuid primary key default gen_random_uuid(), organization_id uuid not null references public.organizations(id), parcel_id uuid not null, season_id uuid,
 type text not null check(type in ('irrigation','fertilization','treatment','inspection','harvest','note')),
 event_date date not null, notes text not null default '', product text, dose numeric check(dose>=0), unit text,
 cost_usd numeric check(cost_usd>=0), created_by uuid not null default auth.uid() references auth.users(id),
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(), unique(id,organization_id),
 foreign key(parcel_id,organization_id) references public.parcels(id,organization_id),
 foreign key(season_id,parcel_id,organization_id) references public.seasons(id,parcel_id,organization_id)
);
create table public.attachments (
 id uuid primary key default gen_random_uuid(), organization_id uuid not null references public.organizations(id), event_id uuid not null,
 object_path text not null unique, mime_type text not null check(mime_type in ('image/jpeg','image/png','image/webp')),
 size_bytes bigint not null check(size_bytes>0 and size_bytes<=10485760), created_by uuid not null default auth.uid() references auth.users(id),
 status text not null default 'pending' check(status in ('pending','completed')), created_at timestamptz not null default now(),
 foreign key(event_id,organization_id) references public.field_events(id,organization_id),
 check(object_path=organization_id::text || '/' || event_id::text || '/' || id::text)
);
create table public.weather_snapshots (
 id uuid primary key default gen_random_uuid(), organization_id uuid not null references public.organizations(id), farm_id uuid not null,
 latitude double precision not null, longitude double precision not null, provider text not null default 'open-meteo',
 fetched_at timestamptz not null default now(), expires_at timestamptz not null, payload jsonb not null,
 foreign key(farm_id,organization_id) references public.farms(id,organization_id)
);
create table public.satellite_observations (
 id uuid primary key default gen_random_uuid(), organization_id uuid not null references public.organizations(id), parcel_id uuid not null,
 geometry_version integer not null, from_date date not null, to_date date not null,
 provider text not null default 'copernicus-sentinel-hub', ndvi_mean double precision, ndvi_min double precision, ndvi_max double precision,
 valid_fraction double precision not null check(valid_fraction between 0 and 1), quality text not null check(quality in ('valid','low_coverage','no_data')),
 raster_path text, processing_version text not null default 'ndvi-v1', created_at timestamptz not null default now(),
 foreign key(parcel_id,organization_id) references public.parcels(id,organization_id),
 unique(parcel_id,geometry_version,from_date,to_date,processing_version), check(to_date>=from_date)
);
create table public.processing_jobs (
 id uuid primary key default gen_random_uuid(), organization_id uuid not null references public.organizations(id), parcel_id uuid not null,
 geometry_version integer not null, type text not null default 'ndvi' check(type='ndvi'), from_date date not null, to_date date not null,
 status text not null default 'queued' check(status in ('queued','processing','completed','failed','obsolete')),
 attempts integer not null default 0, available_at timestamptz not null default now(), locked_at timestamptz, lease_until timestamptz,
 last_error text, created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 foreign key(parcel_id,organization_id) references public.parcels(id,organization_id),
 unique(parcel_id,geometry_version,type,from_date,to_date), check(to_date>=from_date)
);
create table public.audit_events (
 id bigint generated always as identity primary key, organization_id uuid not null references public.organizations(id),
 actor_id uuid references auth.users(id), action text not null, resource_type text not null, resource_id uuid not null,
 created_at timestamptz not null default now()
);

create function public.touch_updated_at() returns trigger language plpgsql set search_path='' as $$ begin new.updated_at=now(); return new; end $$;
create function public.audit_change() returns trigger language plpgsql security definer set search_path='' as $$
begin
 insert into public.audit_events(organization_id,actor_id,action,resource_type,resource_id)
 values(coalesce(new.organization_id,old.organization_id),auth.uid(),tg_op,tg_table_name,coalesce(new.id,old.id));
 return coalesce(new,old);
end $$;
create function public.validate_parcel_geometry() returns trigger language plpgsql set search_path='' as $$
begin
 new.geom=extensions.st_multi(extensions.st_setsrid(extensions.st_geomfromgeojson(new.geometry_geojson::text),4326));
 if extensions.st_isempty(new.geom) or not extensions.st_isvalid(new.geom) or extensions.st_ndims(new.geom)<>2
 or extensions.st_xmin(new.geom::extensions.box3d)<-180 or extensions.st_xmax(new.geom::extensions.box3d)>180
 or extensions.st_ymin(new.geom::extensions.box3d)<-90 or extensions.st_ymax(new.geom::extensions.box3d)>90 then
 raise exception 'Invalid parcel geometry' using errcode='22023'; end if;
 new.area_ha=extensions.st_area(new.geom::extensions.geography)/10000;
 if new.area_ha<=0 then raise exception 'Parcel area must be positive' using errcode='22023'; end if;
 new.geometry_geojson=extensions.st_asgeojson(new.geom)::jsonb;
 if tg_op='UPDATE' then
 new.geometry_version=old.geometry_version+case when not extensions.st_equals(old.geom,new.geom) then 1 else 0 end;
 else new.geometry_version=1; end if;
 return new;
end $$;
create trigger parcel_geometry before insert or update on public.parcels for each row execute function public.validate_parcel_geometry();
create function public.save_parcel(p_id uuid,p_organization_id uuid,p_farm_id uuid,p_name text,p_geometry jsonb) returns public.parcels
language plpgsql security invoker set search_path='' as $$
declare result public.parcels;
begin
 if p_id is null then
 insert into public.parcels(organization_id,farm_id,name,geometry_geojson) values(p_organization_id,p_farm_id,p_name,p_geometry) returning * into result;
 else
 update public.parcels set name=p_name, farm_id=p_farm_id,geometry_geojson=p_geometry where id=p_id and organization_id=p_organization_id returning * into result;
 if result.id is null then raise exception 'Parcel unavailable' using errcode='P0002'; end if;
 end if;
 return result;
end $$;

-- RLS is the authoritative tenant boundary even when clients bypass the API.
alter table public.organizations enable row level security;
alter table public.memberships enable row level security;
alter table public.profiles enable row level security;
create policy profiles_self on public.profiles for all to authenticated using(id=auth.uid()) with check(id=auth.uid());
create policy organization_read on public.organizations for select to authenticated using(public.has_org_access(id));
create policy organization_update on public.organizations for update to authenticated using(public.is_org_owner(id)) with check(public.is_org_owner(id));
create policy membership_read on public.memberships for select to authenticated using(public.has_org_access(organization_id));
-- Membership writes are deliberately unavailable to clients. Provision additional users with an audited operator procedure.
do $$ declare t text; begin
 foreach t in array array['farms','parcels','seasons','field_events','attachments','weather_snapshots','satellite_observations','processing_jobs','audit_events'] loop
 execute format('alter table public.%I enable row level security',t);
 execute format('create policy tenant_read on public.%I for select to authenticated using(public.has_org_access(organization_id))',t);
 execute format('create index on public.%I(organization_id)',t);
 if t=any(array['farms','parcels','seasons','field_events','attachments']) then
 execute format('create policy tenant_insert on public.%I for insert to authenticated with check(public.has_org_access(organization_id,true))',t);
 execute format('create policy tenant_update on public.%I for update to authenticated using(public.has_org_access(organization_id,true)) with check(public.has_org_access(organization_id,true))',t);
 execute format('create trigger audit_record after insert or update or delete on public.%I for each row execute function public.audit_change()',t);
 end if;
 if t=any(array['farms','parcels','seasons','field_events','processing_jobs']) then
 execute format('create trigger touch_updated before update on public.%I for each row execute function public.touch_updated_at()',t);
 end if;
 end loop;
end $$;
create policy events_delete on public.field_events for delete to authenticated using(public.has_org_access(organization_id,true));
create policy seasons_delete on public.seasons for delete to authenticated using(public.has_org_access(organization_id,true));
create policy attachments_delete on public.attachments for delete to authenticated using(public.has_org_access(organization_id,true));
create function public.protect_ownership() returns trigger language plpgsql set search_path='' as $$ begin
 if tg_op='INSERT' and new.created_by is distinct from auth.uid() and current_user<>'service_role' then raise exception 'Invalid author' using errcode='42501'; end if;
 if tg_op='UPDATE' and (new.organization_id<>old.organization_id or new.created_by<>old.created_by) then raise exception 'Ownership is immutable' using errcode='42501'; end if;
 return new; end $$;
create trigger event_owner before insert or update on public.field_events for each row execute function public.protect_ownership();
create trigger attachment_owner before insert or update on public.attachments for each row execute function public.protect_ownership();
create index on public.field_events(parcel_id,event_date desc);
create index on public.weather_snapshots(farm_id,fetched_at desc);
create index on public.satellite_observations(parcel_id,geometry_version,from_date desc);
create index on public.processing_jobs(status,available_at);

create function public.enqueue_ndvi(p_parcel_id uuid,p_from date,p_to date) returns public.processing_jobs
language plpgsql security definer set search_path='' as $$
declare p public.parcels; result public.processing_jobs;
begin
 select * into p from public.parcels where id=p_parcel_id and archived_at is null;
 if p.id is null or not public.has_org_access(p.organization_id,true) then raise exception 'Parcel unavailable' using errcode='42501'; end if;
 if p_to<p_from or p_to-p_from>366 or p_to>current_date then raise exception 'Invalid date interval' using errcode='22023'; end if;
 insert into public.processing_jobs(organization_id,parcel_id,geometry_version,from_date,to_date)
 values(p.organization_id,p.id,p.geometry_version,p_from,p_to)
 on conflict(parcel_id,geometry_version,type,from_date,to_date) do update set id=public.processing_jobs.id returning * into result;
 return result;
end $$;
create function public.claim_processing_job() returns public.processing_jobs
language plpgsql security definer set search_path='' as $$
declare result public.processing_jobs;
begin
 update public.processing_jobs j set status='obsolete',lease_until=null
 from public.parcels p where j.parcel_id=p.id and j.status in ('queued','processing') and (j.geometry_version<>p.geometry_version or p.archived_at is not null);
 update public.processing_jobs set status='failed',last_error='Worker lease expired after maximum attempts',lease_until=null where status='processing' and lease_until<now() and attempts>=5;
 update public.processing_jobs set status='processing', attempts=attempts+1,locked_at=now(),lease_until=now()+interval '10 minutes'
 where id=(select id from public.processing_jobs where attempts<5 and ((status='queued' and available_at<=now()) or (status='processing' and lease_until<now())) order by available_at for update skip locked limit 1)
 returning * into result;
 return result;
end $$;
create function public.complete_processing_job(p_id uuid,p_error text default null,p_retry boolean default false) returns void
language plpgsql security definer set search_path='' as $$ begin
 update public.processing_jobs set status=case when p_error is null then 'completed' when p_retry and attempts<5 then 'queued' else 'failed' end,
 last_error=left(p_error,500), available_at=now()+make_interval(secs=>least(3600,(power(2,attempts)*30)::integer)),lease_until=null
 where id=p_id and status='processing';
end $$;
-- Explicit privileges: worker-only RPCs must never be callable via an end-user JWT.
revoke all on function public.claim_processing_job() from public,anon,authenticated;
revoke all on function public.complete_processing_job(uuid,text,boolean) from public,anon,authenticated;
grant execute on function public.claim_processing_job() to service_role;
grant execute on function public.complete_processing_job(uuid,text,boolean) to service_role;
revoke all on function public.create_organization(text),public.save_parcel(uuid,uuid,uuid,text,jsonb),public.enqueue_ndvi(uuid,date,date) from public,anon;
grant execute on function public.create_organization(text),public.save_parcel(uuid,uuid,uuid,text,jsonb),public.enqueue_ndvi(uuid,date,date) to authenticated;
grant usage on schema public,extensions to authenticated,service_role;
grant select,insert,update,delete on all tables in schema public to authenticated;
grant all on all tables in schema public to service_role;
grant usage,select on all sequences in schema public to authenticated,service_role;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('field-photos','field-photos',false,10485760,array['image/jpeg','image/png','image/webp']) on conflict(id) do nothing;
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('ndvi-rasters','ndvi-rasters',false,10485760,array['image/png']) on conflict(id) do nothing;
create policy photo_read on storage.objects for select to authenticated using(bucket_id='field-photos' and exists(select 1 from public.attachments a where a.object_path=name and a.status='completed' and public.has_org_access(a.organization_id)));
create policy photo_insert on storage.objects for insert to authenticated with check(bucket_id='field-photos' and exists(select 1 from public.attachments a where a.object_path=name and a.status='pending' and a.created_by=auth.uid() and public.has_org_access(a.organization_id,true)));
create policy raster_read on storage.objects for select to authenticated using(bucket_id='ndvi-rasters' and exists(select 1 from public.satellite_observations s where s.raster_path=name and public.has_org_access(s.organization_id)));

alter table public.satellite_observations add column bounds jsonb;
alter table public.processing_jobs add column lease_token uuid;
-- Attachment metadata cannot bypass the server's byte/type validation.
drop policy tenant_update on public.attachments;
create function public.validate_attachment_insert() returns trigger language plpgsql set search_path='' as $$ begin
 if current_user<>'service_role' and new.status<>'pending' then raise exception 'Attachments must be verified by server' using errcode='42501'; end if;
 return new; end $$;
create trigger attachment_pending before insert on public.attachments for each row execute function public.validate_attachment_insert();

create or replace function public.claim_processing_job() returns public.processing_jobs
language plpgsql security definer set search_path='' as $$
declare result public.processing_jobs;
begin
 update public.processing_jobs j set status='obsolete',lease_until=null,lease_token=null
 from public.parcels p join public.farms f on f.id=p.farm_id where j.parcel_id=p.id and j.status in ('queued','processing') and (j.geometry_version<>p.geometry_version or p.archived_at is not null or f.archived_at is not null);
 update public.processing_jobs set status='failed',last_error='Worker lease expired after maximum attempts',lease_until=null,lease_token=null where status='processing' and lease_until<now() and attempts>=5;
 update public.processing_jobs set status='processing', attempts=attempts+1,locked_at=now(),lease_until=now()+interval '10 minutes',lease_token=gen_random_uuid()
 where id=(select id from public.processing_jobs where attempts<5 and ((status='queued' and available_at<=now()) or (status='processing' and lease_until<now())) order by available_at for update skip locked limit 1)
 returning * into result;
 return result;
end $$;
drop function public.complete_processing_job(uuid,text,boolean);
create function public.complete_processing_job(p_id uuid,p_lease_token uuid,p_error text default null,p_retry boolean default false) returns boolean
language plpgsql security definer set search_path='' as $$ declare affected integer; begin
 update public.processing_jobs set status=case when p_error is null then 'completed' when p_retry and attempts<5 then 'queued' else 'failed' end,
 last_error=left(p_error,500), available_at=now()+make_interval(secs=>least(3600,(power(2,attempts)*30)::integer)),lease_until=null,lease_token=null
 where id=p_id and status='processing' and lease_token=p_lease_token and lease_until>now();
 get diagnostics affected=row_count; return affected=1;
end $$;
revoke all on function public.complete_processing_job(uuid,uuid,text,boolean) from public,anon,authenticated;
grant execute on function public.complete_processing_job(uuid,uuid,text,boolean) to service_role;

create function public.schedule_ndvi_jobs() returns integer
language plpgsql security definer set search_path='' as $$ declare affected integer; begin
 insert into public.processing_jobs(organization_id,parcel_id,geometry_version,from_date,to_date)
 select p.organization_id,p.id,p.geometry_version,
 case when exists(select 1 from public.satellite_observations o where o.parcel_id=p.id and o.geometry_version=p.geometry_version) then current_date-7 else current_date-90 end,current_date
 from public.parcels p join public.farms f on f.id=p.farm_id
 where p.archived_at is null and f.archived_at is null
 on conflict(parcel_id,geometry_version,type,from_date,to_date) do nothing;
 get diagnostics affected=row_count; return affected;
end $$;
revoke all on function public.schedule_ndvi_jobs() from public,anon,authenticated;
grant execute on function public.schedule_ndvi_jobs() to service_role;

create function public.require_active_parent() returns trigger language plpgsql set search_path='' as $$
begin
 if tg_table_name='parcels' then
 if not exists(select 1 from public.farms where id=new.farm_id and archived_at is null) then raise exception 'Farm is archived or unavailable' using errcode='23514'; end if;
 elsif tg_table_name in ('seasons','field_events','processing_jobs') then
 if not exists(select 1 from public.parcels p join public.farms f on f.id=p.farm_id where p.id=new.parcel_id and p.archived_at is null and f.archived_at is null) then raise exception 'Parcel is archived or unavailable' using errcode='23514'; end if;
 elsif tg_table_name='attachments' then
 if not exists(select 1 from public.field_events e join public.parcels p on p.id=e.parcel_id join public.farms f on f.id=p.farm_id where e.id=new.event_id and p.archived_at is null and f.archived_at is null) then raise exception 'Event parent is archived or unavailable' using errcode='23514'; end if;
 end if;
 return new;
end $$;
create trigger parcel_active_parent before insert on public.parcels for each row execute function public.require_active_parent();
create trigger season_active_parent before insert on public.seasons for each row execute function public.require_active_parent();
create trigger event_active_parent before insert on public.field_events for each row execute function public.require_active_parent();
create trigger attachment_active_parent before insert on public.attachments for each row execute function public.require_active_parent();
create trigger job_active_parent before insert on public.processing_jobs for each row execute function public.require_active_parent();

create function public.commit_satellite_observation(p_job_id uuid,p_lease_token uuid,p_observation jsonb) returns boolean
language plpgsql security definer set search_path='' as $$
declare j public.processing_jobs; p public.parcels;
begin
 select * into j from public.processing_jobs where id=p_job_id and lease_token=p_lease_token and status='processing' and lease_until>now() for update;
 if j.id is null then return false; end if;
 select * into p from public.parcels where id=j.parcel_id for share;
 if p.geometry_version<>j.geometry_version or p.archived_at is not null or not exists(select 1 from public.farms where id=p.farm_id and archived_at is null) then return false; end if;
 if (p_observation->>'from_date')::date<j.from_date or (p_observation->>'to_date')::date>j.to_date then raise exception 'Observation outside job interval' using errcode='22023'; end if;
 insert into public.satellite_observations(organization_id,parcel_id,geometry_version,from_date,to_date,ndvi_mean,ndvi_min,ndvi_max,valid_fraction,quality,raster_path,bounds,processing_version)
 values(j.organization_id,j.parcel_id,j.geometry_version,(p_observation->>'from_date')::date,(p_observation->>'to_date')::date,(p_observation->>'ndvi_mean')::double precision,(p_observation->>'ndvi_min')::double precision,(p_observation->>'ndvi_max')::double precision,(p_observation->>'valid_fraction')::double precision,p_observation->>'quality',p_observation->>'raster_path',p_observation->'bounds',coalesce(p_observation->>'processing_version','ndvi-v1'))
 on conflict(parcel_id,geometry_version,from_date,to_date,processing_version) do update set ndvi_mean=excluded.ndvi_mean,ndvi_min=excluded.ndvi_min,ndvi_max=excluded.ndvi_max,valid_fraction=excluded.valid_fraction,quality=excluded.quality,raster_path=excluded.raster_path,bounds=excluded.bounds;
 return true;
end $$;
revoke all on function public.commit_satellite_observation(uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.commit_satellite_observation(uuid,uuid,jsonb) to service_role;
