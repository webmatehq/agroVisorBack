alter table public.farms drop constraint if exists farms_timezone_check;
alter table public.farms add constraint farms_timezone_check
  check (timezone in ('America/Guayaquil', 'Pacific/Galapagos', 'America/Argentina/Buenos_Aires', 'America/Argentina/Cordoba'));
