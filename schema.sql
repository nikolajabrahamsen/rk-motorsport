-- =====================================================================
-- RK Motorsport – Reservedele PWA
-- Kør hele filen i Supabase → SQL Editor. Filen kan køres igen ved opdateringer
-- (eksisterende data bevares).
-- Første bruger der opretter sig bliver automatisk admin.
-- =====================================================================

-- ---------- Profiler (1:1 med auth.users) ----------
create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  full_name   text not null default '',
  email       text,
  role        text not null default 'mechanic' check (role in ('admin','mechanic','pending')),
  created_at  timestamptz not null default now()
);

-- ---------- Kørere ----------
create table if not exists public.drivers (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  race_number text,
  class       text,
  email       text,               -- faktura-modtager (fx forælder)
  phone       text,
  billing_info text,              -- adresse / CVR / bemærkning til faktura
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);

-- ---------- Hvilke mekanikere/hjælpere står for hvilke kørere ----------
create table if not exists public.driver_mechanics (
  driver_id uuid references public.drivers(id) on delete cascade,
  user_id   uuid references public.profiles(id) on delete cascade,
  primary key (driver_id, user_id)
);

-- ---------- Løb / weekender ----------
create table if not exists public.events (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  location    text,
  date_from   date not null default current_date,
  date_to     date,
  closed      boolean not null default false,  -- lukket = ingen nye registreringer
  created_at  timestamptz not null default now()
);

-- ---------- Vareliste (forberedt til stregkode-scanning) ----------
create table if not exists public.products (
  id          uuid primary key default gen_random_uuid(),
  barcode     text unique,
  sku         text,               -- varenummer
  name        text not null,
  unit_price  numeric(10,2),      -- salgspris inkl. moms
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);

-- ---------- Udtagne reservedele ----------
create table if not exists public.parts_log (
  id          uuid primary key default gen_random_uuid(),
  event_id    uuid not null references public.events(id) on delete restrict,
  driver_id   uuid not null references public.drivers(id) on delete restrict,
  user_id     uuid not null default auth.uid() references public.profiles(id),
  product_id  uuid references public.products(id) on delete set null,
  barcode     text,
  description text not null,
  qty         numeric(10,2) not null default 1 check (qty > 0),
  unit_price  numeric(10,2),      -- kopieres fra vareliste eller udfyldes af admin
  note        text,
  invoiced    boolean not null default false,
  created_at  timestamptz not null default now()
);
create index if not exists parts_log_event_driver on public.parts_log(event_id, driver_id);

-- ---------- v2: godkendelse + e-conomic ----------
alter table public.drivers          add column if not exists economic_customer_number integer;
alter table public.driver_mechanics add column if not exists responsible boolean not null default false;
alter table public.products         add column if not exists economic_product_number text;
create unique index if not exists driver_mechanics_one_responsible
  on public.driver_mechanics(driver_id) where responsible;

-- Én række pr. kører pr. løb når forbruget er godkendt.
-- Ingen række = endnu ikke godkendt af mekaniker.
create table if not exists public.approvals (
  event_id     uuid not null references public.events(id) on delete cascade,
  driver_id    uuid not null references public.drivers(id) on delete cascade,
  status       text not null check (status in ('rejected','mechanic_approved','chief_approved','sending','sent')),
  mechanic_id  uuid references public.profiles(id),
  mechanic_at  timestamptz,
  chief_id     uuid references public.profiles(id),
  chief_at     timestamptz,
  comment      text,             -- teamchefens bemærkning ved afvisning
  total        numeric(10,2),    -- beløb på godkendelsestidspunktet (inkl. moms)
  economic_draft_number integer,
  sent_at      timestamptz,
  error        text,             -- sidste fejl fra e-conomic
  primary key (event_id, driver_id)
);

-- Indstillinger til e-conomic (én række)
create table if not exists public.settings (
  id                       integer primary key default 1 check (id = 1),
  economic_product_number  text,              -- standard-varenr. i e-conomic, fx "RESERVEDELE"
  economic_layout_number   integer,           -- bruges hvis kunden ikke har et layout
  prices_incl_vat          boolean not null default true,
  updated_at               timestamptz not null default now()
);
insert into public.settings (id) values (1) on conflict do nothing;

-- =====================================================================
-- Hjælpefunktioner (SECURITY DEFINER for at undgå RLS-rekursion)
-- =====================================================================
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and role = 'admin');
$$;

create or replace function public.my_role() returns text
language sql stable security definer set search_path = public as $$
  select role from profiles where id = auth.uid();
$$;

create or replace function public.is_member() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.my_role() in ('admin','mechanic'), false);
$$;

create or replace function public.is_mechanic_for(d uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from driver_mechanics dm
    join profiles p on p.id = dm.user_id
    where dm.driver_id = d and dm.user_id = auth.uid() and p.role in ('admin','mechanic')
  );
$$;

create or replace function public.event_open(e uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from events where id = e and not closed);
$$;

create or replace function public.approval_status(e uuid, d uuid) returns text
language sql stable security definer set search_path = public as $$
  select status from approvals where event_id = e and driver_id = d;
$$;

-- Mekaniker må tilføje/slette: løbet er åbent og intet er godkendt,
-- eller teamchefen har sendt listen retur (afvist).
create or replace function public.mech_can_edit(e uuid, d uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select case coalesce(public.approval_status(e, d), 'none')
    when 'none' then public.event_open(e)
    when 'rejected' then true
    else false end;
$$;

-- Ansvarlig mekaniker. Er ingen markeret som ansvarlig, må alle tilknyttede godkende.
create or replace function public.can_approve(d uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_admin() or (
    public.is_mechanic_for(d) and (
      exists (select 1 from driver_mechanics where driver_id = d and user_id = auth.uid() and responsible)
      or not exists (select 1 from driver_mechanics where driver_id = d and responsible)
    ));
$$;

-- Trin 1: mekanikeren godkender forbruget (løbet skal være lukket)
create or replace function public.approve_driver(e uuid, d uuid) returns void
language plpgsql security definer set search_path = public as $$
declare st text := public.approval_status(e, d); tot numeric;
begin
  if not public.can_approve(d) then raise exception 'Du er ikke ansvarlig mekaniker for denne kører'; end if;
  if public.event_open(e) then raise exception 'Løbet skal lukkes før forbruget kan godkendes'; end if;
  if st is not null and st <> 'rejected' then raise exception 'Forbruget er allerede godkendt'; end if;
  select coalesce(sum(qty * unit_price), 0) into tot from parts_log where event_id = e and driver_id = d;
  insert into approvals (event_id, driver_id, status, mechanic_id, mechanic_at, total, comment, error)
  values (e, d, 'mechanic_approved', auth.uid(), now(), tot, null, null)
  on conflict (event_id, driver_id) do update set status = 'mechanic_approved', mechanic_id = auth.uid(),
    mechanic_at = now(), total = tot, chief_id = null, chief_at = null, error = null;
end $$;

-- Trin 2: teamchefen godkender
create or replace function public.chief_approve(e uuid, d uuid) returns void
language plpgsql security definer set search_path = public as $$
declare tot numeric;
begin
  if not public.is_admin() then raise exception 'Kun teamchefen kan godkende'; end if;
  if coalesce(public.approval_status(e, d), '') <> 'mechanic_approved' then
    raise exception 'Mekanikeren har ikke godkendt forbruget endnu'; end if;
  if exists (select 1 from parts_log where event_id = e and driver_id = d and unit_price is null) then
    raise exception 'Der mangler pris på en eller flere linjer'; end if;
  select coalesce(sum(qty * unit_price), 0) into tot from parts_log where event_id = e and driver_id = d;
  update approvals set status = 'chief_approved', chief_id = auth.uid(), chief_at = now(), total = tot, error = null
  where event_id = e and driver_id = d;
end $$;

-- Teamchefen sender listen retur til mekanikeren med en bemærkning
create or replace function public.reject_approval(e uuid, d uuid, msg text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Kun teamchefen kan afvise'; end if;
  if coalesce(public.approval_status(e, d), '') not in ('mechanic_approved','chief_approved') then
    raise exception 'Kan ikke afvises i nuværende status'; end if;
  update approvals set status = 'rejected', comment = nullif(trim(msg), ''), chief_id = null, chief_at = null
  where event_id = e and driver_id = d;
end $$;

-- Opret profil automatisk ved signup. Første bruger = admin.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into profiles (id, full_name, email, role)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name', ''),
    new.email,
    case when not exists (select 1 from profiles) then 'admin' else 'pending' end
  );
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Mekanikere må ikke ændre pris/faktureret-status – kun admin.
-- Linjer er låst når teamchefen har godkendt eller de er sendt til e-conomic.
-- (auth.uid() er null for Edge Function med service-role → ingen begrænsning)
create or replace function public.guard_parts_log() returns trigger
language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if auth.uid() is null then return coalesce(new, old); end if;
  r := coalesce(new, old);
  if coalesce(public.approval_status(r.event_id, r.driver_id), '') in ('chief_approved','sending','sent')
     or (tg_op = 'UPDATE' and coalesce(public.approval_status(old.event_id, old.driver_id), '') in ('chief_approved','sending','sent')) then
    raise exception 'Listen er godkendt af teamchefen og er låst';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  if not public.is_admin() then
    if tg_op = 'UPDATE' then
      new.invoiced := old.invoiced;
      new.event_id := old.event_id;
      new.driver_id := old.driver_id;
      new.user_id := old.user_id;
    else
      new.invoiced := false;
      new.user_id := auth.uid();
    end if;
  end if;
  return new;
end $$;

drop trigger if exists parts_log_guard on public.parts_log;
create trigger parts_log_guard before insert or update or delete on public.parts_log
  for each row execute function public.guard_parts_log();

-- =====================================================================
-- Row Level Security
-- =====================================================================
alter table public.profiles         enable row level security;
alter table public.drivers          enable row level security;
alter table public.driver_mechanics enable row level security;
alter table public.events           enable row level security;
alter table public.products         enable row level security;
alter table public.parts_log        enable row level security;
alter table public.approvals        enable row level security;
alter table public.settings         enable row level security;

-- profiles
drop policy if exists "profiles read"   on public.profiles;
drop policy if exists "profiles self"   on public.profiles;
drop policy if exists "profiles admin"  on public.profiles;
-- godkendte holdmedlemmer kan se hinandens navne (vises ved registreringer)
create policy "profiles read"  on public.profiles for select using (id = auth.uid() or public.is_member());
create policy "profiles self"  on public.profiles for update using (id = auth.uid())
  with check (id = auth.uid() and role = public.my_role());
create policy "profiles admin" on public.profiles for all using (public.is_admin()) with check (public.is_admin());

-- drivers
drop policy if exists "drivers read"  on public.drivers;
drop policy if exists "drivers admin" on public.drivers;
create policy "drivers read"  on public.drivers for select using (public.is_admin() or public.is_mechanic_for(id));
create policy "drivers admin" on public.drivers for all using (public.is_admin()) with check (public.is_admin());

-- driver_mechanics
drop policy if exists "dm read"  on public.driver_mechanics;
drop policy if exists "dm admin" on public.driver_mechanics;
create policy "dm read"  on public.driver_mechanics for select using (user_id = auth.uid() or public.is_admin());
create policy "dm admin" on public.driver_mechanics for all using (public.is_admin()) with check (public.is_admin());

-- events (alle godkendte brugere kan se løb)
drop policy if exists "events read"  on public.events;
drop policy if exists "events admin" on public.events;
create policy "events read"  on public.events for select
  using (public.is_member());
create policy "events admin" on public.events for all using (public.is_admin()) with check (public.is_admin());

-- products (alle godkendte kan slå op, kun admin redigerer)
drop policy if exists "products read"  on public.products;
drop policy if exists "products admin" on public.products;
create policy "products read"  on public.products for select
  using (public.is_member());
create policy "products admin" on public.products for all using (public.is_admin()) with check (public.is_admin());

-- parts_log
drop policy if exists "parts read"   on public.parts_log;
drop policy if exists "parts insert" on public.parts_log;
drop policy if exists "parts update" on public.parts_log;
drop policy if exists "parts delete" on public.parts_log;
create policy "parts read" on public.parts_log for select
  using (public.is_admin() or public.is_mechanic_for(driver_id));
create policy "parts insert" on public.parts_log for insert
  with check (public.is_admin() or (public.is_mechanic_for(driver_id) and public.mech_can_edit(event_id, driver_id)));
create policy "parts update" on public.parts_log for update
  using (public.is_admin() or (user_id = auth.uid() and not invoiced and public.mech_can_edit(event_id, driver_id)));
create policy "parts delete" on public.parts_log for delete
  using (public.is_admin() or (public.is_mechanic_for(driver_id) and not invoiced and public.mech_can_edit(event_id, driver_id)
         and (user_id = auth.uid() or public.approval_status(event_id, driver_id) = 'rejected')));

-- approvals: ændres kun via funktionerne ovenfor (og af Edge Function)
drop policy if exists "approvals read"  on public.approvals;
drop policy if exists "approvals admin" on public.approvals;
create policy "approvals read"  on public.approvals for select using (public.is_admin() or public.is_mechanic_for(driver_id));
create policy "approvals admin" on public.approvals for all using (public.is_admin()) with check (public.is_admin());

-- settings: kun admin
drop policy if exists "settings admin" on public.settings;
create policy "settings admin" on public.settings for all using (public.is_admin()) with check (public.is_admin());

-- RPC-funktioner må kun kaldes af indloggede brugere
revoke execute on function public.approve_driver(uuid, uuid), public.chief_approve(uuid, uuid),
  public.reject_approval(uuid, uuid, text) from public, anon;
grant execute on function public.approve_driver(uuid, uuid), public.chief_approve(uuid, uuid),
  public.reject_approval(uuid, uuid, text), public.can_approve(uuid) to authenticated;
