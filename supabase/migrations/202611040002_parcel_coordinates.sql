alter table public.parcels add column latitude double precision;
alter table public.parcels add column longitude double precision;

update public.parcels
set latitude=extensions.st_y(extensions.st_centroid(geom)),
    longitude=extensions.st_x(extensions.st_centroid(geom));

alter table public.parcels alter column latitude set not null;
alter table public.parcels alter column longitude set not null;
alter table public.parcels add constraint parcels_latitude_check check(latitude between -90 and 90);
alter table public.parcels add constraint parcels_longitude_check check(longitude between -180 and 180);

create or replace function public.validate_parcel_geometry() returns trigger language plpgsql set search_path='' as $$
begin
 new.geom=extensions.st_multi(extensions.st_setsrid(extensions.st_geomfromgeojson(new.geometry_geojson::text),4326));
 if extensions.st_isempty(new.geom) or not extensions.st_isvalid(new.geom) or extensions.st_ndims(new.geom)<>2
 or extensions.st_xmin(new.geom::extensions.box3d)<-180 or extensions.st_xmax(new.geom::extensions.box3d)>180
 or extensions.st_ymin(new.geom::extensions.box3d)<-90 or extensions.st_ymax(new.geom::extensions.box3d)>90 then
 raise exception 'Invalid parcel geometry' using errcode='22023'; end if;
 new.area_ha=extensions.st_area(new.geom::extensions.geography)/10000;
 if new.area_ha<=0 then raise exception 'Parcel area must be positive' using errcode='22023'; end if;
 new.geometry_geojson=extensions.st_asgeojson(new.geom)::jsonb;
 new.latitude=extensions.st_y(extensions.st_centroid(new.geom));
 new.longitude=extensions.st_x(extensions.st_centroid(new.geom));
 if tg_op='UPDATE' then
 new.geometry_version=old.geometry_version+case when not extensions.st_equals(old.geom,new.geom) then 1 else 0 end;
 else new.geometry_version=1; end if;
 return new;
end $$;
