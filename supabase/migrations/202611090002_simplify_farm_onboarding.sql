alter table public.farms alter column latitude drop not null;
alter table public.farms alter column longitude drop not null;

create or replace function public.ensure_default_organization() returns public.organizations
language plpgsql security definer set search_path = '' as $$
declare
  result public.organizations;
  current_user_id uuid := auth.uid();
begin
  if current_user_id is null then
    raise exception 'Authentication required' using errcode='42501';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(current_user_id::text, 0));

  select o.* into result
  from public.organizations o
  join public.memberships m on m.organization_id = o.id
  where m.user_id = current_user_id
  order by o.created_at
  limit 1;

  if result.id is null then
    insert into public.organizations(name, created_by)
    values ('Mi explotación', current_user_id)
    returning * into result;

    insert into public.memberships(organization_id, user_id, role)
    values (result.id, current_user_id, 'owner');

    insert into public.profiles(id) values(current_user_id) on conflict do nothing;
  end if;

  return result;
end $$;

revoke all on function public.ensure_default_organization() from public, anon;
grant execute on function public.ensure_default_organization() to authenticated;
