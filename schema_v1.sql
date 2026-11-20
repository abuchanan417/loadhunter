-- =====================================================================
-- LOAD HUNTER / TRAILINER  -  01 FOUNDATION
-- Users and roles, settings, activity log, terminals, trucks,
-- trailers, drivers.
-- Paste the whole file into Supabase SQL Editor and click Run.
-- Safe to run once on a fresh project.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. USERS AND ROLES
-- One login per person. A person can hold several roles.
-- Roles: owner, dispatch, sales, billing, driver, shop_lead, mechanic,
-- safety (safety + driver manager for now). is_admin = can manage users.
-- ---------------------------------------------------------------------
create table public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  full_name   text not null default '',
  email       text,
  phone       text,
  roles       text[] not null default '{}',
  is_admin    boolean not null default false,
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint profiles_roles_ok check (
    roles <@ array['owner','dispatch','sales','billing','driver',
                   'shop_lead','mechanic','safety']::text[]
  )
);

-- Helper checks used by every security rule below.
create or replace function public.has_role(r text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.active and (r = any(p.roles) or p.is_admin)
  );
$$;

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.active and p.is_admin
  );
$$;

-- Office = anyone who works in the office (not drivers, not mechanics).
create or replace function public.is_office()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.active
      and (p.is_admin or p.roles && array['owner','dispatch','sales','billing',
                                          'shop_lead','safety']::text[])
  );
$$;

-- ---------------------------------------------------------------------
-- 2. SHARED PLUMBING: updated_at stamp + activity log
-- Every change on every table lands in activity_log with who and when.
-- The log is append-only: nobody can edit or delete it, admin included.
-- ---------------------------------------------------------------------
create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

create table public.activity_log (
  id           bigint generated always as identity primary key,
  at           timestamptz not null default now(),
  user_id      uuid default auth.uid(),
  entity_type  text not null,          -- 'load', 'driver', 'truck', ...
  entity_id    text not null,
  action       text not null,          -- 'insert','update','delete', or app actions:
                                       -- 'status','note','check_call','email','call','text'
  changes      jsonb,                  -- for updates: {field: [old, new]}
  detail       jsonb                   -- anything else the app wants to keep
);
create index activity_log_entity_idx on public.activity_log (entity_type, entity_id, at desc);
create index activity_log_user_idx   on public.activity_log (user_id, at desc);

-- Automatic logging of inserts, updates and deletes.
create or replace function public.log_change()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  diff jsonb := '{}'::jsonb;
  k text;
  o jsonb;
  n jsonb;
begin
  if tg_op = 'INSERT' then
    insert into activity_log(entity_type, entity_id, action, detail)
    values (tg_argv[0], new.id::text, 'insert', to_jsonb(new));
    return new;
  elsif tg_op = 'UPDATE' then
    o := to_jsonb(old); n := to_jsonb(new);
    for k in select jsonb_object_keys(n) loop
      if k <> 'updated_at' and (o -> k) is distinct from (n -> k) then
        diff := diff || jsonb_build_object(k, jsonb_build_array(o -> k, n -> k));
      end if;
    end loop;
    if diff <> '{}'::jsonb then
      insert into activity_log(entity_type, entity_id, action, changes)
      values (tg_argv[0], new.id::text, 'update', diff);
    end if;
    return new;
  else
    insert into activity_log(entity_type, entity_id, action, detail)
    values (tg_argv[0], old.id::text, 'delete', to_jsonb(old));
    return old;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 3. SETTINGS
-- Every Trailiner rule lives here, not in code. Change a number,
-- not the program.
-- ---------------------------------------------------------------------
create table public.settings (
  key          text primary key,
  value        jsonb not null,
  description  text,
  updated_by   uuid default auth.uid(),
  updated_at   timestamptz not null default now()
);

insert into public.settings (key, value, description) values
 ('company',              '{"name":"Trailiner Corp","scac":"TRLH","usdot":"203311","mc":"154121"}', 'Company identifiers'),
 ('relay_through_terminal','true',  'Every load routes through the home terminal'),
 ('out_of_route_max_miles','150',   'Max miles added to route through the terminal'),
 ('equipment_types',      '["reefer","van_in_reefer"]', 'Freight we haul'),
 ('excluded_areas',       '["NYC"]', 'No-go areas'),
 ('hos_rule_set',         '"USA Property 70/8"', 'HOS rule set'),
 ('plan_hours_per_day',   '10',    'Never plan a full 11'),
 ('deliver_hours',        '2',     'Hours allowed to deliver'),
 ('home_time_hours',      '34',    'Hours off when home'),
 ('clock_reset_on_drop_only','true','Clock resets only on an actual trailer drop at the terminal'),
 ('pay_mileage_away',     '0.65',  'Per mile away from home: 0.53 base + 0.12 travel'),
 ('pay_mileage_base',     '0.53',  'Base per mile; home-daily runs'),
 ('pay_travel',           '0.12',  'Travel pay per mile'),
 ('pay_detention',        '{"rate":20,"after_hours":2,"increment_min":15,"cap_hours_per_stop":6}', 'Driver detention pay'),
 ('pay_extra_stop',       '30',    'Per stop beyond first pickup and final drop'),
 ('pay_layover',          '{"rate":75,"per_hours":24,"after_hours":24}', 'Layover, dispatch-approved'),
 ('invoice_terms_printed','"Net 15"', 'Terms printed on every invoice'),
 ('invoice_review_dwell_hours','2', 'Truck sat longer than this at any stop = human review'),
 ('credit_hold_mode',     '"warn"', 'warn or block; accountant sets'),
 ('load_number_prefix',   '"TL"',  'Internal load number prefix');

-- ---------------------------------------------------------------------
-- 4. TERMINALS
-- ---------------------------------------------------------------------
create table public.terminals (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  address     text,
  city        text,
  state       text,
  zip         text,
  lat         double precision,
  lng         double precision,
  is_home     boolean not null default false,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

insert into public.terminals (name, address, city, state, zip, is_home)
values ('Springfield', '2169 E Blaine St', 'Springfield', 'MO', '65803', true);

-- ---------------------------------------------------------------------
-- 5. TRUCKS
-- Ditat fields carried over. Anything rare goes in "extra".
-- ---------------------------------------------------------------------
create table public.trucks (
  id               uuid primary key default gen_random_uuid(),
  unit             text not null unique,
  status           text not null default 'active'
                   check (status in ('active','out_of_service','in_shop','sold','inactive')),
  terminal_id      uuid references public.terminals(id),
  vin              text,
  year             int,
  make             text,
  model            text,
  plate            text,
  plate_state      text,
  tag_expires      date,
  inspection_due   date,
  lessor           text,          -- blank = company owned
  lease_ref        text,
  owner_type       text,
  purchased_on     date,
  purchase_price   numeric(12,2),
  eld_device       text,          -- ISAAC unit
  tracking_serial  text,
  rfid_tag         text,          -- gate
  odometer         int,           -- from ISAAC, not typed
  odometer_at      timestamptz,
  ditat_id         text,
  notes            text,
  extra            jsonb not null default '{}',
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 6. TRAILERS
-- ---------------------------------------------------------------------
create table public.trailers (
  id               uuid primary key default gen_random_uuid(),
  unit             text not null unique,
  status           text not null default 'active'
                   check (status in ('active','out_of_service','in_shop','sold','for_sale','inactive')),
  trailer_type     text not null default 'reefer',
  terminal_id      uuid references public.terminals(id),
  vin              text,
  year             int,
  make             text,
  model            text,
  length_ft        int,
  plate            text,
  plate_state      text,
  tag_expires      date,
  inspection_due   date,
  reefer_make      text,
  reefer_model     text,
  reefer_year      int,
  reefer_serial    text,
  reefer_hours     int,           -- reefer units run on engine hours
  carb_compliant   boolean,
  carb_number      text,
  carb_expires     date,
  door_type        text,
  floor            text,
  suspension       text,
  tire_size        text,
  tracking_system  text,          -- ORBCOMM
  tracking_serial  text,
  rfid_tag         text,
  owner_type       text,
  purchased_on     date,
  purchase_price   numeric(12,2),
  ditat_id         text,
  notes            text,
  extra            jsonb not null default '{}',
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 7. DRIVERS
-- Never stored anywhere: SSN, bank account numbers (those stay in ADP).
-- DOB and license number live in a separate locked table (driver_private)
-- that dispatch can't read.
-- ---------------------------------------------------------------------
create table public.drivers (
  id                 uuid primary key default gen_random_uuid(),
  profile_id         uuid references public.profiles(id),  -- his tablet login
  ditat_id           text unique,
  first_name         text not null,
  last_name          text not null,
  status             text not null default 'applicant'
                     check (status in ('active','on_leave','terminated','applicant')),
  driver_type        text,          -- company, team, etc.
  pay_type           text,
  is_team            boolean not null default false,
  team_partner_id    uuid references public.drivers(id),
  phone              text,
  phone2             text,
  email              text,
  address            text,
  city               text,
  state              text,
  zip                text,
  hired_on           date,
  terminated_on      date,
  term_reason        text,
  term_notes         text,
  rehireable         boolean,
  prev_hired_on      date,
  prev_terminated_on date,
  license_state      text,
  license_class      text,
  license_status     text,
  license_expires    date,
  medical_expires    date,
  drug_test_expires  date,
  alcohol_test_expires date,
  hazmat             boolean not null default false,
  tanker             boolean not null default false,
  doubles            boolean not null default false,
  reefer_experience  boolean not null default false,
  years_experience   numeric(4,1),
  fuel_card_last4    text check (fuel_card_last4 is null or fuel_card_last4 ~ '^[0-9]{4}$'),
  gate_code          text,
  truck_id           uuid references public.trucks(id),
  trailer_id         uuid references public.trailers(id),
  terminal_id        uuid references public.terminals(id),
  hos_rule_set       text,
  per_diem           boolean not null default false,  -- opt-in exception
  home_daily         boolean not null default false,  -- pays base rate only
  recruited_by       text,
  application_on     date,
  application_denied_on date,
  application_notes  text,
  notes              text,
  extra              jsonb not null default '{}',
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
create index drivers_status_idx on public.drivers (status);
create index drivers_name_idx   on public.drivers (last_name, first_name);
create index drivers_phone_idx  on public.drivers (phone);

create table public.driver_private (
  driver_id       uuid primary key references public.drivers(id) on delete cascade,
  date_of_birth   date,
  license_number  text,
  updated_at      timestamptz not null default now()
);
create index driver_private_license_idx on public.driver_private (license_number);

-- ---------------------------------------------------------------------
-- 8. TRIGGERS: stamp updated_at, log every change
-- ---------------------------------------------------------------------
create trigger t_touch before update on public.profiles  for each row execute function public.touch_updated_at();
create trigger t_touch before update on public.terminals for each row execute function public.touch_updated_at();
create trigger t_touch before update on public.trucks    for each row execute function public.touch_updated_at();
create trigger t_touch before update on public.trailers  for each row execute function public.touch_updated_at();
create trigger t_touch before update on public.drivers   for each row execute function public.touch_updated_at();
create trigger t_touch before update on public.driver_private for each row execute function public.touch_updated_at();

create trigger t_log after insert or update or delete on public.profiles  for each row execute function public.log_change('profile');
create trigger t_log after insert or update or delete on public.terminals for each row execute function public.log_change('terminal');
create trigger t_log after insert or update or delete on public.trucks    for each row execute function public.log_change('truck');
create trigger t_log after insert or update or delete on public.trailers  for each row execute function public.log_change('trailer');
create trigger t_log after insert or update or delete on public.drivers   for each row execute function public.log_change('driver');

-- driver_private: log THAT it changed and who did it, never the values.
create or replace function public.log_private_change()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into activity_log(entity_type, entity_id, action, detail)
  values ('driver_private', coalesce(new.driver_id, old.driver_id)::text,
          lower(tg_op), '{"note":"sensitive fields changed, values not logged"}');
  return coalesce(new, old);
end $$;
create trigger t_log after insert or update or delete on public.driver_private
  for each row execute function public.log_private_change();

-- settings: log value changes
create or replace function public.log_setting_change()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into activity_log(entity_type, entity_id, action, changes)
  values ('setting', coalesce(new.key, old.key), lower(tg_op),
          jsonb_build_object('value', jsonb_build_array(
            case when tg_op = 'INSERT' then null else old.value end,
            case when tg_op = 'DELETE' then null else new.value end)));
  if tg_op = 'DELETE' then
    return old;
  end if;
  new.updated_at := now();
  return new;
end $$;
create trigger t_log before insert or update or delete on public.settings
  for each row execute function public.log_setting_change();

-- ---------------------------------------------------------------------
-- 9. SECURITY (row-level security)
-- Locked by default. Nobody sees anything unless a rule below says so.
-- ---------------------------------------------------------------------
alter table public.profiles       enable row level security;
alter table public.settings       enable row level security;
alter table public.activity_log   enable row level security;
alter table public.terminals      enable row level security;
alter table public.trucks         enable row level security;
alter table public.trailers       enable row level security;
alter table public.drivers        enable row level security;
alter table public.driver_private enable row level security;

-- Logged-out visitors get nothing, anywhere.
revoke all on all tables in schema public from anon;

-- PROFILES: everyone sees their own; office sees everyone (names for
-- "who did this"); only admin adds, edits, deactivates.
create policy profiles_read on public.profiles for select to authenticated
  using (id = auth.uid() or public.is_office());
create policy profiles_admin on public.profiles for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- SETTINGS: everyone logged in reads; owner/admin change.
create policy settings_read on public.settings for select to authenticated using (true);
create policy settings_write on public.settings for all to authenticated
  using (public.has_role('owner')) with check (public.has_role('owner'));

-- ACTIVITY LOG: office reads; anyone logged in can add an entry as
-- themselves; nobody edits or deletes.
create policy log_read on public.activity_log for select to authenticated
  using (public.is_office() or user_id = auth.uid());
create policy log_add on public.activity_log for insert to authenticated
  with check (user_id = auth.uid());
revoke update, delete, truncate on public.activity_log from authenticated, anon;

-- TERMINALS: everyone reads; owner/admin edit.
create policy terminals_read on public.terminals for select to authenticated using (true);
create policy terminals_write on public.terminals for all to authenticated
  using (public.has_role('owner')) with check (public.has_role('owner'));

-- TRUCKS and TRAILERS: everyone logged in reads (drivers and mechanics
-- need unit info); dispatch, shop lead, safety, owner edit.
create policy trucks_read on public.trucks for select to authenticated using (true);
create policy trucks_write on public.trucks for all to authenticated
  using (public.has_role('dispatch') or public.has_role('shop_lead')
         or public.has_role('safety') or public.has_role('owner'))
  with check (public.has_role('dispatch') or public.has_role('shop_lead')
         or public.has_role('safety') or public.has_role('owner'));

create policy trailers_read on public.trailers for select to authenticated using (true);
create policy trailers_write on public.trailers for all to authenticated
  using (public.has_role('dispatch') or public.has_role('shop_lead')
         or public.has_role('safety') or public.has_role('owner'))
  with check (public.has_role('dispatch') or public.has_role('shop_lead')
         or public.has_role('safety') or public.has_role('owner'));

-- DRIVERS: office reads all (sales excluded); a driver reads only himself.
-- Dispatch, safety, owner edit.
create policy drivers_read on public.drivers for select to authenticated
  using (
    profile_id = auth.uid()
    or public.has_role('dispatch') or public.has_role('safety')
    or public.has_role('billing')  or public.has_role('owner')
    or public.has_role('shop_lead')
  );
create policy drivers_write on public.drivers for all to authenticated
  using (public.has_role('dispatch') or public.has_role('safety') or public.has_role('owner'))
  with check (public.has_role('dispatch') or public.has_role('safety') or public.has_role('owner'));

-- DRIVER_PRIVATE (DOB, license #): safety and admin only. Not dispatch.
create policy driver_private_all on public.driver_private for all to authenticated
  using (public.has_role('safety') or public.is_admin())
  with check (public.has_role('safety') or public.is_admin());

-- Done.
-- =====================================================================
-- LOAD HUNTER / TRAILINER  -  02 COMPANIES AND LOADS
-- Companies (brokers, shippers, consignees, customers), locations,
-- contacts, loads, load parties, stops, revenue lines, documents,
-- load notes/communications, yard board.
-- Run AFTER 01_foundation.sql. Paste the whole file and Run.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. COMPANIES: one table, many roles. Same company can be broker,
--    shipper, consignee and direct customer.
-- ---------------------------------------------------------------------
create table public.companies (
  id               uuid primary key default gen_random_uuid(),
  name             text not null,
  roles            text[] not null default '{}'
                   check (roles <@ array['broker','shipper','consignee','customer','vendor']::text[]),
  mc_number        text,
  usdot            text,
  phone            text,
  email            text,
  website          text,
  address          text,
  city             text,
  state            text,
  zip              text,
  -- money side (brokers and direct customers)
  agreed_terms_days int,                 -- their real terms; aging runs off this
  credit_limit     numeric(12,2),
  credit_status    text not null default 'ok' check (credit_status in ('ok','warn','hold')),
  factoring_approved boolean,
  carrier_packet_status text,            -- setup packet with the broker
  days_to_pay_avg  numeric(6,1),         -- calculated from paid invoices
  pain_level       int check (pain_level between 1 and 5),
  go_direct_target boolean not null default false,
  owner_id         uuid references public.profiles(id),   -- salesman account owner
  quickbooks_id    text,
  ditat_id         text,
  notes            text,
  active           boolean not null default true,
  extra            jsonb not null default '{}',
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index companies_name_idx on public.companies (lower(name));
create index companies_mc_idx   on public.companies (mc_number);
create index companies_roles_idx on public.companies using gin (roles);

-- ---------------------------------------------------------------------
-- 2. LOCATIONS: a shipper's plants and DCs, a broker's offices.
-- ---------------------------------------------------------------------
create table public.locations (
  id               uuid primary key default gen_random_uuid(),
  company_id       uuid not null references public.companies(id) on delete cascade,
  name             text not null,
  address          text,
  city             text,
  state            text,
  zip              text,
  lat              double precision,
  lng              double precision,
  geofence_m       int not null default 400,  -- meters, for on-site detection
  dock_hours       text,
  appointment_rule text,
  lumper           boolean,
  avg_dwell_min    int,                       -- calculated
  free_time_hours  numeric(4,1),              -- customer's free time before detention
  temp_notes       text,
  phone            text,
  notes            text,
  active           boolean not null default true,
  extra            jsonb not null default '{}',
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index locations_company_idx on public.locations (company_id);
create index locations_city_idx on public.locations (state, city);

-- ---------------------------------------------------------------------
-- 3. CONTACTS: reps under a company or a location.
-- ---------------------------------------------------------------------
create table public.contacts (
  id               uuid primary key default gen_random_uuid(),
  company_id       uuid not null references public.companies(id) on delete cascade,
  location_id      uuid references public.locations(id) on delete set null,
  name             text not null,
  title            text,
  phone            text,
  phone2           text,
  email            text,
  is_primary       boolean not null default false,
  notes            text,
  active           boolean not null default true,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index contacts_company_idx on public.contacts (company_id);
create index contacts_phone_idx   on public.contacts (phone);
create index contacts_email_idx   on public.contacts (lower(email));

-- ---------------------------------------------------------------------
-- 4. LOADS
-- ---------------------------------------------------------------------
create table public.loads (
  id               uuid primary key default gen_random_uuid(),
  load_no          text not null unique,          -- TL-1120-001
  status           text not null default 'requested'
                   check (status in ('requested','negotiated','confirmed','in_action','completed','cancelled')),
  source           text,                          -- truckstop, chr, dat, manual, ratecon, email, edi, yard
  board_ref        text,                          -- the board's own load id
  broker_load_no   text,                          -- broker's load/order number
  rate_con_no      text,
  customer_po      text,
  bol_no           text,
  ref_numbers      jsonb not null default '{}',   -- the five Ditat reference fields, any others
  -- who's on it
  truck_id         uuid references public.trucks(id),
  trailer_id       uuid references public.trailers(id),
  driver_id        uuid references public.drivers(id),
  driver2_id       uuid references public.drivers(id),
  is_team          boolean not null default false,
  booked_by        uuid references public.profiles(id),
  dispatched_by    uuid references public.profiles(id),
  -- relay / round
  round_id         text,
  leg_no           int,
  leg_count        int,
  relay_swap       boolean not null default false,   -- driver swap at terminal
  parent_load_id   uuid references public.loads(id),  -- second driver on a yard handoff
  -- freight
  equipment        text,
  weight_lbs       int,
  pallets          int,
  pieces           int,
  commodity        text,
  temp_required    boolean not null default false,
  temp_set         numeric(5,1),
  temp_mode        text,                          -- continuous / cycle
  temp_tolerance   numeric(4,1),
  hazmat           boolean not null default false,
  -- summary of the route (stops hold the detail)
  origin_city      text,
  origin_state     text,
  dest_city        text,
  dest_state       text,
  pickup_date      date,
  pickup_date_end  date,
  delivery_date    date,
  -- miles
  board_miles      int,
  pcmiler_loaded   int,          -- miles of record, locked once calculated
  pcmiler_empty    int,
  deadhead_miles   int,
  out_of_route     int,          -- miles added by routing through terminal
  miles_locked_at  timestamptz,
  -- money (lines in load_revenue hold the detail; these are the quick view)
  posted_rate      numeric(10,2),
  agreed_rate      numeric(10,2),
  agreed_terms_days int,          -- from the rate con; aging runs off this
  -- pipeline checks (the nine boxes)
  chk_contacted    boolean not null default false,
  chk_rate_ok      boolean not null default false,
  chk_rate_con     boolean not null default false,
  chk_dispatched   boolean not null default false,
  chk_picked       boolean not null default false,
  chk_delivered    boolean not null default false,
  chk_pod          boolean not null default false,
  chk_invoiced     boolean not null default false,
  chk_paid         boolean not null default false,
  -- billing state
  invoice_id       uuid,                          -- set in 03 (invoices table)
  review_required  boolean not null default false,
  review_reasons   text[] not null default '{}',  -- dwell>2h, rate mismatch, lumper, added stop
  cancelled_reason text,
  notes            text,
  extra            jsonb not null default '{}',
  accepted_at      timestamptz not null default now(),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index loads_status_idx   on public.loads (status);
create index loads_truck_idx    on public.loads (truck_id);
create index loads_driver_idx   on public.loads (driver_id);
create index loads_pickup_idx   on public.loads (pickup_date);
create index loads_round_idx    on public.loads (round_id);

-- Load numbers: TL-MMDD-NNN, sequence resets per pickup day.
create or replace function public.next_load_no(p_day date default current_date)
returns text language plpgsql as $$
declare
  pre text := (select value #>> '{}' from public.settings where key = 'load_number_prefix');
  k   text := to_char(p_day, 'MMDD');
  n   int;
begin
  select coalesce(max(substring(load_no from '\d{3}$')::int), 0) + 1 into n
  from public.loads where load_no like pre || '-' || k || '-%';
  return pre || '-' || k || '-' || lpad(n::text, 3, '0');
end $$;

-- ---------------------------------------------------------------------
-- 5. LOAD PARTIES: how one order lands on two or more companies.
--    Revenue counts once: it belongs to the bill_to row.
-- ---------------------------------------------------------------------
create table public.load_parties (
  id               uuid primary key default gen_random_uuid(),
  load_id          uuid not null references public.loads(id) on delete cascade,
  company_id       uuid not null references public.companies(id),
  location_id      uuid references public.locations(id),
  contact_id       uuid references public.contacts(id),
  role             text not null
                   check (role in ('bill_to','booked_through','customer_of_record','shipper','consignee')),
  created_at       timestamptz not null default now(),
  unique (load_id, company_id, role, location_id)
);
create index load_parties_load_idx    on public.load_parties (load_id);
create index load_parties_company_idx on public.load_parties (company_id, role);

-- ---------------------------------------------------------------------
-- 6. STOPS: pickups and drops in order, with the detention evidence.
-- ---------------------------------------------------------------------
create table public.load_stops (
  id               uuid primary key default gen_random_uuid(),
  load_id          uuid not null references public.loads(id) on delete cascade,
  seq              int not null,                   -- 1, 2, 3...
  stop_type        text not null check (stop_type in ('pickup','delivery')),
  company_id       uuid references public.companies(id),
  location_id      uuid references public.locations(id),
  name             text,                          -- facility name as on the rate con
  address          text,
  city             text,
  state            text,
  zip              text,
  lat              double precision,
  lng              double precision,
  appt_start       timestamptz,
  appt_end         timestamptz,
  appt_required    boolean not null default false,
  appt_set         boolean not null default false,
  free_time_hours  numeric(4,1) not null default 2,
  -- evidence, from ISAAC and the driver app
  on_site_at       timestamptz,                   -- geofence hit
  checked_in_at    timestamptz,                   -- driver tapped it
  loaded_at        timestamptz,
  departed_at      timestamptz,                   -- geofence exit
  bol_in_time      timestamptz,                   -- in/out as written on the BOL
  bol_out_time     timestamptz,
  -- alarm ladder
  alarm_push_at    timestamptz,
  alarm_text_at    timestamptz,
  alarm_call_at    timestamptz,
  missed_appt      boolean not null default false,
  -- detention (one record drives driver pay AND the invoice line)
  detention_min    int,                           -- calculated
  detention_billable boolean,
  detention_payable  boolean,
  detention_reason text,                          -- why killed or adjusted, logged
  added_after_dispatch boolean not null default false,
  pallets          int,
  pieces           int,
  weight_lbs       int,
  stop_notes       text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (load_id, seq)
);
create index load_stops_load_idx on public.load_stops (load_id, seq);

-- ---------------------------------------------------------------------
-- 7. REVENUE LINES: what the customer gets billed (Ditat codes).
-- ---------------------------------------------------------------------
create table public.load_revenue (
  id               uuid primary key default gen_random_uuid(),
  load_id          uuid not null references public.loads(id) on delete cascade,
  code             text not null
                   check (code in ('LINEHAUL','STOP','FSC','UNLOADING','DETENTION','ACCESSORIAL','TONU','LAYOVER','OTHER')),
  description      text,
  qty              numeric(10,2) not null default 1,
  rate             numeric(10,2) not null default 0,
  amount           numeric(12,2) generated always as (round(qty * rate, 2)) stored,
  bill_to_company_id uuid references public.companies(id),   -- split billing, defaults to load's bill_to
  stop_id          uuid references public.load_stops(id),    -- detention / lumper per stop
  rebillable_receipt_doc_id uuid,                              -- lumper receipt
  created_by       uuid default auth.uid(),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index load_revenue_load_idx on public.load_revenue (load_id);

-- ---------------------------------------------------------------------
-- 8. DOCUMENTS: rate cons, BOLs, PODs, receipts. File lives in
--    Supabase Storage; this row holds the link.
-- ---------------------------------------------------------------------
create table public.documents (
  id               uuid primary key default gen_random_uuid(),
  doc_type         text not null
                   check (doc_type in ('rate_con','bol','pod','lumper_receipt','receipt','invoice','photo','other')),
  load_id          uuid references public.loads(id) on delete cascade,
  stop_id          uuid references public.load_stops(id) on delete set null,
  driver_id        uuid references public.drivers(id),
  truck_id         uuid references public.trucks(id),
  trailer_id       uuid references public.trailers(id),
  company_id       uuid references public.companies(id),
  storage_path     text not null,                 -- bucket path
  file_name        text,
  mime_type        text,
  size_bytes       int,
  signed           boolean,                       -- POD signed?
  taken_at         timestamptz,
  lat              double precision,
  lng              double precision,
  uploaded_by      uuid default auth.uid(),
  notes            text,
  created_at       timestamptz not null default now()
);
create index documents_load_idx on public.documents (load_id, doc_type);

-- ---------------------------------------------------------------------
-- 9. COMMUNICATIONS: every email, call, text, note and check call,
--    on the load and on the company. Stamped with user and time.
-- ---------------------------------------------------------------------
create table public.communications (
  id               uuid primary key default gen_random_uuid(),
  kind             text not null
                   check (kind in ('note','check_call','email_in','email_out','call_in','call_out','text_in','text_out','voice_note','system')),
  load_id          uuid references public.loads(id) on delete set null,
  company_id       uuid references public.companies(id) on delete set null,
  contact_id       uuid references public.contacts(id) on delete set null,
  driver_id        uuid references public.drivers(id) on delete set null,
  user_id          uuid default auth.uid(),       -- who logged / sent / answered
  at               timestamptz not null default now(),
  subject          text,
  body             text,                          -- email body, text, note, transcript summary
  transcript       text,
  recording_path   text,
  from_addr        text,                          -- email or phone
  to_addr          text,
  provider_id      text,                          -- Twilio SID, email Message-ID
  duration_sec     int,
  lat              double precision,              -- GPS on check calls
  lng              double precision,
  tagged           boolean not null default true, -- false = sitting in the unmatched queue
  ai_suggested_load_id uuid references public.loads(id),
  extra            jsonb not null default '{}',
  created_at       timestamptz not null default now()
);
create index comms_load_idx    on public.communications (load_id, at desc);
create index comms_company_idx on public.communications (company_id, at desc);
create index comms_queue_idx   on public.communications (user_id, at desc) where tagged = false;

-- One call or text can tag to several loads.
create table public.communication_loads (
  communication_id uuid not null references public.communications(id) on delete cascade,
  load_id          uuid not null references public.loads(id) on delete cascade,
  primary key (communication_id, load_id)
);

-- ---------------------------------------------------------------------
-- 10. FOLLOW-UPS: CRM reminders on a company or contact.
-- ---------------------------------------------------------------------
create table public.follow_ups (
  id               uuid primary key default gen_random_uuid(),
  company_id       uuid references public.companies(id) on delete cascade,
  contact_id       uuid references public.contacts(id) on delete set null,
  load_id          uuid references public.loads(id) on delete set null,
  assigned_to      uuid references public.profiles(id),
  due_at           timestamptz not null,
  title            text not null,
  notes            text,
  done_at          timestamptz,
  done_by          uuid references public.profiles(id),
  created_by       uuid default auth.uid(),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index follow_ups_due_idx on public.follow_ups (assigned_to, due_at) where done_at is null;

-- ---------------------------------------------------------------------
-- 11. YARD BOARD: dropped trailers waiting on the next driver.
-- ---------------------------------------------------------------------
create table public.yard_drops (
  id               uuid primary key default gen_random_uuid(),
  terminal_id      uuid references public.terminals(id),
  trailer_id       uuid references public.trailers(id),
  load_id          uuid references public.loads(id) on delete set null,
  dropped_by_driver_id uuid references public.drivers(id),
  dropped_at       timestamptz not null default now(),
  dest_city        text,
  dest_state       text,
  delivery_date    date,
  status           text not null default 'open' check (status in ('open','assigned','gone')),
  picked_by_driver_id uuid references public.drivers(id),
  picked_at        timestamptz,
  notes            text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 12. TRIGGERS
-- ---------------------------------------------------------------------
create trigger t_touch before update on public.companies      for each row execute function public.touch_updated_at();
create trigger t_touch before update on public.locations      for each row execute function public.touch_updated_at();
create trigger t_touch before update on public.contacts       for each row execute function public.touch_updated_at();
create trigger t_touch before update on public.loads          for each row execute function public.touch_updated_at();
create trigger t_touch before update on public.load_stops     for each row execute function public.touch_updated_at();
create trigger t_touch before update on public.load_revenue   for each row execute function public.touch_updated_at();
create trigger t_touch before update on public.follow_ups     for each row execute function public.touch_updated_at();
create trigger t_touch before update on public.yard_drops     for each row execute function public.touch_updated_at();

create trigger t_log after insert or update or delete on public.companies    for each row execute function public.log_change('company');
create trigger t_log after insert or update or delete on public.locations    for each row execute function public.log_change('location');
create trigger t_log after insert or update or delete on public.contacts     for each row execute function public.log_change('contact');
create trigger t_log after insert or update or delete on public.loads        for each row execute function public.log_change('load');
create trigger t_log after insert or update or delete on public.load_parties for each row execute function public.log_change('load_party');
create trigger t_log after insert or update or delete on public.load_stops   for each row execute function public.log_change('load_stop');
create trigger t_log after insert or update or delete on public.load_revenue for each row execute function public.log_change('load_revenue');
create trigger t_log after insert or update or delete on public.documents    for each row execute function public.log_change('document');
create trigger t_log after insert or update or delete on public.follow_ups   for each row execute function public.log_change('follow_up');
create trigger t_log after insert or update or delete on public.yard_drops   for each row execute function public.log_change('yard_drop');

-- Communications are their own record; log that one was added and to what.
create or replace function public.log_comm()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into activity_log(entity_type, entity_id, action, user_id, detail)
  values ('load', coalesce(new.load_id::text, 'none'), new.kind, new.user_id,
          jsonb_build_object('communication_id', new.id, 'company_id', new.company_id,
                             'subject', new.subject));
  return new;
end $$;
create trigger t_log after insert on public.communications for each row execute function public.log_comm();

-- Load status changes get their own plain-English log row too.
create or replace function public.log_load_status()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if old.status is distinct from new.status then
    insert into activity_log(entity_type, entity_id, action, detail)
    values ('load', new.id::text, 'status',
            jsonb_build_object('load_no', new.load_no, 'from', old.status, 'to', new.status));
  end if;
  return new;
end $$;
create trigger t_status after update on public.loads for each row execute function public.log_load_status();

-- Hard rule: a load can't be completed/delivered-checked without a signed POD on file.
create or replace function public.require_pod()
returns trigger language plpgsql as $$
begin
  if (new.status = 'completed' or (new.chk_delivered and not old.chk_delivered))
     and not exists (select 1 from public.documents d
                     where d.load_id = new.id and d.doc_type = 'pod' and coalesce(d.signed, false)) then
    raise exception 'Load % needs a signed POD on file before it can be marked delivered or completed', new.load_no;
  end if;
  return new;
end $$;
create trigger t_pod before update on public.loads for each row execute function public.require_pod();

-- ---------------------------------------------------------------------
-- 13. SECURITY
-- ---------------------------------------------------------------------
alter table public.companies           enable row level security;
alter table public.locations           enable row level security;
alter table public.contacts            enable row level security;
alter table public.loads               enable row level security;
alter table public.load_parties        enable row level security;
alter table public.load_stops          enable row level security;
alter table public.load_revenue        enable row level security;
alter table public.documents           enable row level security;
alter table public.communications      enable row level security;
alter table public.communication_loads enable row level security;
alter table public.follow_ups          enable row level security;
alter table public.yard_drops          enable row level security;
revoke all on all tables in schema public from anon;

-- Is this driver on this load?
create or replace function public.my_driver_id()
returns uuid language sql stable security definer set search_path = public as $$
  select d.id from public.drivers d where d.profile_id = auth.uid() limit 1;
$$;
create or replace function public.on_my_load(l_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.loads l
                 where l.id = l_id and (l.driver_id = public.my_driver_id() or l.driver2_id = public.my_driver_id()));
$$;

-- COMPANIES / LOCATIONS / CONTACTS: office + sales read; sales edits own
-- accounts; dispatch, billing, owner edit all.
create policy companies_read on public.companies for select to authenticated
  using (public.is_office());
create policy companies_write on public.companies for all to authenticated
  using (public.has_role('dispatch') or public.has_role('billing') or public.has_role('owner')
         or (public.has_role('sales') and owner_id = auth.uid()))
  with check (public.has_role('dispatch') or public.has_role('billing') or public.has_role('owner')
         or (public.has_role('sales') and owner_id = auth.uid()));

create policy locations_read on public.locations for select to authenticated
  using (public.is_office() or public.has_role('driver'));
create policy locations_write on public.locations for all to authenticated
  using (public.has_role('dispatch') or public.has_role('sales') or public.has_role('owner'))
  with check (public.has_role('dispatch') or public.has_role('sales') or public.has_role('owner'));

create policy contacts_read on public.contacts for select to authenticated using (public.is_office());
create policy contacts_write on public.contacts for all to authenticated
  using (public.has_role('dispatch') or public.has_role('sales') or public.has_role('owner'))
  with check (public.has_role('dispatch') or public.has_role('sales') or public.has_role('owner'));

-- LOADS: dispatch, billing, owner, safety full; sales reads (summary in app);
-- driver reads his own and can update his own stop/check fields.
create policy loads_read on public.loads for select to authenticated
  using (public.is_office() or public.on_my_load(id));
create policy loads_write on public.loads for all to authenticated
  using (public.has_role('dispatch') or public.has_role('billing') or public.has_role('owner'))
  with check (public.has_role('dispatch') or public.has_role('billing') or public.has_role('owner'));
create policy loads_driver_update on public.loads for update to authenticated
  using (public.on_my_load(id)) with check (public.on_my_load(id));

create policy parties_read on public.load_parties for select to authenticated using (public.is_office());
create policy parties_write on public.load_parties for all to authenticated
  using (public.has_role('dispatch') or public.has_role('billing') or public.has_role('owner'))
  with check (public.has_role('dispatch') or public.has_role('billing') or public.has_role('owner'));

create policy stops_read on public.load_stops for select to authenticated
  using (public.is_office() or public.on_my_load(load_id));
create policy stops_write on public.load_stops for all to authenticated
  using (public.has_role('dispatch') or public.has_role('billing') or public.has_role('owner'))
  with check (public.has_role('dispatch') or public.has_role('billing') or public.has_role('owner'));
create policy stops_driver_update on public.load_stops for update to authenticated
  using (public.on_my_load(load_id)) with check (public.on_my_load(load_id));

-- REVENUE: billing, dispatch, owner. Drivers never see rates.
create policy revenue_all on public.load_revenue for all to authenticated
  using (public.has_role('dispatch') or public.has_role('billing') or public.has_role('owner'))
  with check (public.has_role('dispatch') or public.has_role('billing') or public.has_role('owner'));

-- DOCUMENTS: office reads; drivers read and add on their own loads.
create policy docs_read on public.documents for select to authenticated
  using (public.is_office() or (load_id is not null and public.on_my_load(load_id)));
create policy docs_insert on public.documents for insert to authenticated
  with check (public.is_office() or (load_id is not null and public.on_my_load(load_id)));
create policy docs_change on public.documents for update to authenticated
  using (public.has_role('dispatch') or public.has_role('billing') or public.has_role('owner'));
create policy docs_delete on public.documents for delete to authenticated
  using (public.is_admin());

-- COMMUNICATIONS: office reads all; drivers read their own loads' threads;
-- anyone adds as themselves; never edited or deleted.
create policy comms_read on public.communications for select to authenticated
  using (public.is_office() or user_id = auth.uid() or (load_id is not null and public.on_my_load(load_id)));
create policy comms_insert on public.communications for insert to authenticated
  with check (user_id = auth.uid() or user_id is null);
create policy comms_tag on public.communications for update to authenticated
  using (public.is_office()) with check (public.is_office());   -- tagging only, app enforces
revoke delete on public.communications from authenticated;

create policy comm_loads_all on public.communication_loads for all to authenticated
  using (public.is_office()) with check (public.is_office());

create policy followups_all on public.follow_ups for all to authenticated
  using (public.is_office()) with check (public.is_office());

create policy yard_read on public.yard_drops for select to authenticated using (true);
create policy yard_write on public.yard_drops for all to authenticated
  using (public.has_role('dispatch') or public.has_role('owner'))
  with check (public.has_role('dispatch') or public.has_role('owner'));

-- Done.
-- =====================================================================
-- LOAD HUNTER / TRAILINER  -  03 MONEY
-- Invoices and the billing queue, payments, driver pay and settlements,
-- purchase orders (lumper, road, shop, inventory, overhead), vendor bills,
-- card expenses, accounting export log.
-- Run AFTER 02. Paste the whole file and Run.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. INVOICES: one per load per bill-to. Built from load_revenue once
--    the signed POD is on file. Every one passes through the queue.
-- ---------------------------------------------------------------------
create table public.invoices (
  id               uuid primary key default gen_random_uuid(),
  invoice_no       text not null unique,
  load_id          uuid not null references public.loads(id),
  bill_to_company_id uuid not null references public.companies(id),
  status           text not null default 'review'
                   check (status in ('review','approved','sent','paid','partial','void','disputed')),
  review_required  boolean not null default false,
  review_reasons   text[] not null default '{}',
  reviewed_by      uuid references public.profiles(id),
  reviewed_at      timestamptz,
  review_notes     text,
  invoice_date     date,
  printed_terms    text not null default 'Net 15',   -- house terms on the paper
  agreed_terms_days int,                              -- what aging actually runs on
  due_date         date,
  subtotal         numeric(12,2) not null default 0,
  total            numeric(12,2) not null default 0,
  paid_amount      numeric(12,2) not null default 0,
  sent_at          timestamptz,
  sent_to          text,
  sent_by          uuid references public.profiles(id),
  paid_at          timestamptz,
  quickbooks_id    text,
  quickbooks_synced_at timestamptz,
  pdf_doc_id       uuid references public.documents(id),
  customer_po      text,
  ref_numbers      jsonb not null default '{}',
  notes            text,
  created_by       uuid default auth.uid(),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index invoices_status_idx on public.invoices (status);
create index invoices_billto_idx on public.invoices (bill_to_company_id, due_date);
create index invoices_load_idx   on public.invoices (load_id);

-- loads.invoice_id was left open in 02; tie it now
alter table public.loads
  add constraint loads_invoice_fk foreign key (invoice_id) references public.invoices(id);

-- Invoice numbers: INV-000001 style
create sequence public.invoice_seq start 1001;
create or replace function public.next_invoice_no()
returns text language sql as $$
  select 'INV-' || lpad(nextval('public.invoice_seq')::text, 6, '0');
$$;

-- Invoice lines: a snapshot of load_revenue at invoice time, so a later
-- edit to the load never changes a sent invoice.
create table public.invoice_lines (
  id               uuid primary key default gen_random_uuid(),
  invoice_id       uuid not null references public.invoices(id) on delete cascade,
  load_revenue_id  uuid references public.load_revenue(id),
  code             text not null,
  description      text,
  qty              numeric(10,2) not null default 1,
  rate             numeric(10,2) not null default 0,
  amount           numeric(12,2) generated always as (round(qty * rate, 2)) stored,
  gl_account       text,                          -- 5036, 5044... accountant confirms
  created_at       timestamptz not null default now()
);
create index invoice_lines_inv_idx on public.invoice_lines (invoice_id);

-- Keep the invoice totals honest.
create or replace function public.invoice_retotal()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_id uuid := coalesce(new.invoice_id, old.invoice_id);
begin
  update public.invoices i
     set subtotal = coalesce((select sum(amount) from public.invoice_lines where invoice_id = v_id), 0),
         total    = coalesce((select sum(amount) from public.invoice_lines where invoice_id = v_id), 0)
   where i.id = v_id;
  return coalesce(new, old);
end $$;
create trigger t_retotal after insert or update or delete on public.invoice_lines
  for each row execute function public.invoice_retotal();

-- Sent invoices are frozen: lines can't change once status leaves review/approved.
create or replace function public.invoice_lines_frozen()
returns trigger language plpgsql as $$
declare st text;
begin
  select status into st from public.invoices where id = coalesce(new.invoice_id, old.invoice_id);
  if st not in ('review','approved') then
    raise exception 'Invoice is %, lines are frozen. Void it and rebill.', st;
  end if;
  return coalesce(new, old);
end $$;
create trigger t_frozen before insert or update or delete on public.invoice_lines
  for each row execute function public.invoice_lines_frozen();

-- ---------------------------------------------------------------------
-- 2. PAYMENTS RECEIVED: comes back from QuickBooks when the deposit is
--    matched, or keyed by billing.
-- ---------------------------------------------------------------------
create table public.payments (
  id               uuid primary key default gen_random_uuid(),
  invoice_id       uuid not null references public.invoices(id),
  company_id       uuid references public.companies(id),
  amount           numeric(12,2) not null,
  paid_on          date not null,
  method           text,                          -- ach, check, card, wire
  reference        text,                          -- check no, QB payment id
  source           text not null default 'quickbooks' check (source in ('quickbooks','manual')),
  quickbooks_id    text,
  notes            text,
  created_by       uuid default auth.uid(),
  created_at       timestamptz not null default now()
);
create index payments_invoice_idx on public.payments (invoice_id);

create or replace function public.apply_payment()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_total numeric; v_paid numeric; v_days int;
begin
  select total into v_total from public.invoices where id = new.invoice_id;
  select coalesce(sum(amount),0) into v_paid from public.payments where invoice_id = new.invoice_id;
  update public.invoices
     set paid_amount = v_paid,
         status = case when v_paid >= v_total then 'paid' when v_paid > 0 then 'partial' else status end,
         paid_at = case when v_paid >= v_total then coalesce(paid_at, new.paid_on::timestamptz) else paid_at end
   where id = new.invoice_id;
  -- roll days-to-pay into the customer record
  update public.companies c
     set days_to_pay_avg = (
       select round(avg(i.paid_at::date - i.invoice_date), 1)
       from public.invoices i
       where i.bill_to_company_id = c.id and i.status = 'paid' and i.invoice_date is not null)
   where c.id = (select bill_to_company_id from public.invoices where id = new.invoice_id);
  return new;
end $$;
create trigger t_apply after insert on public.payments for each row execute function public.apply_payment();

-- ---------------------------------------------------------------------
-- 3. DRIVER PAY: one row per pay item, each with its ADP earning code.
--    Load Hunter calculates, accountant approves, ADP pays.
-- ---------------------------------------------------------------------
create table public.driver_pay_items (
  id               uuid primary key default gen_random_uuid(),
  driver_id        uuid not null references public.drivers(id),
  load_id          uuid references public.loads(id),
  stop_id          uuid references public.load_stops(id),     -- detention per stop
  settlement_id    uuid,                                      -- set when settled
  earning_code     text not null
                   check (earning_code in ('BASE_MILEAGE','TRAVEL_PAY','PER_DIEM','DETENTION','EXTRA_STOP',
                                           'LAYOVER','TONU','BREAKDOWN','DRIVER_ASSIST','OTHER',
                                           'ADVANCE','FUEL','ESCROW','DEDUCTION')),
  description      text,
  qty              numeric(10,2) not null default 1,          -- miles, hours, stops, days
  rate             numeric(10,4) not null default 0,
  amount           numeric(12,2) generated always as (round(qty * rate, 2)) stored,
  taxable          boolean not null default true,             -- per diem travel = false
  approved         boolean not null default false,
  approved_by      uuid references public.profiles(id),
  approved_at      timestamptz,
  disputed         boolean not null default false,
  dispute_notes    text,
  eld_verified     boolean,                                   -- hour-based pay checked against logs
  notes            text,
  created_by       uuid default auth.uid(),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index pay_items_driver_idx on public.driver_pay_items (driver_id, created_at desc);
create index pay_items_load_idx   on public.driver_pay_items (load_id);
create index pay_items_open_idx   on public.driver_pay_items (driver_id) where settlement_id is null;

-- Detention pay can't exist without the matching invoice line (or a logged reason).
create or replace function public.detention_must_be_billed()
returns trigger language plpgsql as $$
begin
  if new.earning_code = 'DETENTION' and new.approved and not coalesce(old.approved,false) then
    if new.stop_id is null then
      raise exception 'Detention pay must point at a stop';
    end if;
    if not exists (select 1 from public.load_revenue r where r.stop_id = new.stop_id and r.code = 'DETENTION')
       and not exists (select 1 from public.load_stops s where s.id = new.stop_id and s.detention_reason is not null) then
      raise exception 'Detention pay on this stop has no matching DETENTION charge on the load and no logged reason';
    end if;
  end if;
  return new;
end $$;
create trigger t_detention before update on public.driver_pay_items
  for each row execute function public.detention_must_be_billed();

-- ---------------------------------------------------------------------
-- 4. SETTLEMENTS: one per driver per pay period. Goes to ADP as gross
--    by earning code.
-- ---------------------------------------------------------------------
create table public.settlements (
  id               uuid primary key default gen_random_uuid(),
  settlement_no    text not null unique,
  driver_id        uuid not null references public.drivers(id),
  period_start     date not null,
  period_end       date not null,
  status           text not null default 'open'
                   check (status in ('open','review','approved','exported','paid','void')),
  gross            numeric(12,2) not null default 0,
  deductions       numeric(12,2) not null default 0,
  net_estimate     numeric(12,2) not null default 0,   -- before ADP taxes
  approved_by      uuid references public.profiles(id),
  approved_at      timestamptz,
  exported_at      timestamptz,
  export_file      text,
  notes            text,
  created_by       uuid default auth.uid(),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (driver_id, period_start, period_end)
);
alter table public.driver_pay_items
  add constraint pay_items_settlement_fk foreign key (settlement_id) references public.settlements(id);

create sequence public.settlement_seq start 1001;
create or replace function public.next_settlement_no()
returns text language sql as $$
  select 'STL-' || lpad(nextval('public.settlement_seq')::text, 6, '0');
$$;

create or replace function public.settlement_retotal()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_id uuid := coalesce(new.settlement_id, old.settlement_id);
begin
  if v_id is null then return coalesce(new, old); end if;
  update public.settlements s set
    gross      = coalesce((select sum(amount) from public.driver_pay_items where settlement_id = v_id and amount > 0), 0),
    deductions = coalesce((select -sum(amount) from public.driver_pay_items where settlement_id = v_id and amount < 0), 0),
    net_estimate = coalesce((select sum(amount) from public.driver_pay_items where settlement_id = v_id), 0)
  where s.id = v_id;
  return coalesce(new, old);
end $$;
create trigger t_stl_retotal after insert or update or delete on public.driver_pay_items
  for each row execute function public.settlement_retotal();

-- ---------------------------------------------------------------------
-- 5. PURCHASE ORDERS: no PO number, no money moves. Every PO ties to
--    a load, a unit, or overhead.
-- ---------------------------------------------------------------------
create table public.purchase_orders (
  id               uuid primary key default gen_random_uuid(),
  po_no            text not null unique,
  po_type          text not null
                   check (po_type in ('lumper','road','shop','inventory','overhead')),
  status           text not null default 'open'
                   check (status in ('requested','open','received','closed','cancelled')),
  vendor_id        uuid references public.companies(id),
  vendor_name      text,                                      -- when vendor isn't in companies yet
  load_id          uuid references public.loads(id),
  stop_id          uuid references public.load_stops(id),
  truck_id         uuid references public.trucks(id),
  trailer_id       uuid references public.trailers(id),
  work_order_id    uuid,                                      -- set in 04 (shop)
  driver_id        uuid references public.drivers(id),
  description      text not null,
  estimate         numeric(12,2),
  approved_amount  numeric(12,2),
  actual_amount    numeric(12,2),
  rebillable       boolean not null default false,            -- lumper = true
  requested_by     uuid references public.profiles(id),
  approved_by      uuid references public.profiles(id),
  approved_at      timestamptz,
  receipt_doc_id   uuid references public.documents(id),
  receipt_required boolean not null default true,
  closed_by        uuid references public.profiles(id),
  closed_at        timestamptz,
  gl_account       text,
  notes            text,
  created_by       uuid default auth.uid(),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint po_tied_to_something check (
    po_type = 'overhead' or load_id is not null or truck_id is not null
    or trailer_id is not null or work_order_id is not null)
);
create index po_status_idx on public.purchase_orders (status);
create index po_load_idx   on public.purchase_orders (load_id);
create index po_unit_idx   on public.purchase_orders (truck_id, trailer_id);

create sequence public.po_seq start 10001;
create or replace function public.next_po_no()
returns text language sql as $$
  select 'PO-' || nextval('public.po_seq')::text;
$$;

-- A PO can't close without its receipt, when one is required.
create or replace function public.po_needs_receipt()
returns trigger language plpgsql as $$
begin
  if new.status = 'closed' and old.status <> 'closed'
     and new.receipt_required and new.receipt_doc_id is null then
    raise exception 'PO % needs its receipt attached before it closes', new.po_no;
  end if;
  if new.status = 'closed' and old.status <> 'closed' then
    new.closed_at := coalesce(new.closed_at, now());
    new.closed_by := coalesce(new.closed_by, auth.uid());
  end if;
  return new;
end $$;
create trigger t_po_close before update on public.purchase_orders
  for each row execute function public.po_needs_receipt();

-- Lumper PO closed with rebillable flag → an UNLOADING revenue line lands on the load.
create or replace function public.po_rebill()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'closed' and old.status <> 'closed' and new.rebillable and new.load_id is not null
     and not exists (select 1 from public.load_revenue r where r.load_id = new.load_id and r.code = 'UNLOADING') then
    insert into public.load_revenue(load_id, code, description, qty, rate, stop_id, rebillable_receipt_doc_id)
    values (new.load_id, 'UNLOADING', 'Lumper ' || new.po_no, 1, coalesce(new.actual_amount, new.approved_amount, 0),
            new.stop_id, new.receipt_doc_id);
    update public.loads set review_required = true,
           review_reasons = array_append(review_reasons, 'lumper') where id = new.load_id;
  end if;
  return new;
end $$;
create trigger t_po_rebill after update on public.purchase_orders
  for each row execute function public.po_rebill();

-- ---------------------------------------------------------------------
-- 6. VENDOR BILLS: the invoice the vendor sends. Must match a PO.
-- ---------------------------------------------------------------------
create table public.vendor_bills (
  id               uuid primary key default gen_random_uuid(),
  vendor_id        uuid references public.companies(id),
  po_id            uuid not null references public.purchase_orders(id),
  bill_no          text,
  bill_date        date,
  due_date         date,
  amount           numeric(12,2) not null,
  status           text not null default 'received'
                   check (status in ('received','matched','mismatch','approved','sent_to_qb','paid','void')),
  matched_by       uuid references public.profiles(id),
  matched_at       timestamptz,
  mismatch_notes   text,
  doc_id           uuid references public.documents(id),
  quickbooks_id    text,
  notes            text,
  created_by       uuid default auth.uid(),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index vendor_bills_po_idx on public.vendor_bills (po_id);

-- ---------------------------------------------------------------------
-- 7. CARD EXPENSES: small spends (meals, incidentals) coded after the
--    fact. No PO, but receipt + justification, or it's flagged.
-- ---------------------------------------------------------------------
create table public.card_expenses (
  id               uuid primary key default gen_random_uuid(),
  card_last4       text check (card_last4 ~ '^[0-9]{4}$'),
  spent_by_driver_id uuid references public.drivers(id),
  spent_by_user_id uuid references public.profiles(id),
  spent_on         date not null,
  merchant         text,
  amount           numeric(12,2) not null,
  category         text,                                      -- meal, fuel, parking, toll, scale, other
  load_id          uuid references public.loads(id),
  truck_id         uuid references public.trucks(id),
  justification    text,
  receipt_doc_id   uuid references public.documents(id),
  coded            boolean generated always as (category is not null and receipt_doc_id is not null) stored,
  flagged          boolean not null default false,
  gl_account       text,
  reviewed_by      uuid references public.profiles(id),
  reviewed_at      timestamptz,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index card_exp_uncoded_idx on public.card_expenses (spent_on) where coded = false;

-- ---------------------------------------------------------------------
-- 8. ACCOUNTING EXPORT LOG: what went to QuickBooks / ADP, when, result.
-- ---------------------------------------------------------------------
create table public.export_log (
  id               bigint generated always as identity primary key,
  target           text not null check (target in ('quickbooks','adp','ifta','csv')),
  entity_type      text not null,                 -- invoice, bill, customer, vendor, settlement
  entity_id        uuid,
  direction        text not null default 'out' check (direction in ('out','in')),
  status           text not null check (status in ('ok','error','skipped')),
  external_id      text,
  message          text,
  payload          jsonb,
  user_id          uuid default auth.uid(),
  at               timestamptz not null default now()
);
create index export_log_entity_idx on public.export_log (entity_type, entity_id);

-- ---------------------------------------------------------------------
-- 9. TRIGGERS: stamps and activity log
-- ---------------------------------------------------------------------
create trigger t_touch before update on public.invoices         for each row execute function public.touch_updated_at();
create trigger t_touch before update on public.driver_pay_items for each row execute function public.touch_updated_at();
create trigger t_touch before update on public.settlements      for each row execute function public.touch_updated_at();
create trigger t_touch before update on public.purchase_orders  for each row execute function public.touch_updated_at();
create trigger t_touch before update on public.vendor_bills     for each row execute function public.touch_updated_at();
create trigger t_touch before update on public.card_expenses    for each row execute function public.touch_updated_at();

create trigger t_log after insert or update or delete on public.invoices         for each row execute function public.log_change('invoice');
create trigger t_log after insert or update or delete on public.invoice_lines    for each row execute function public.log_change('invoice_line');
create trigger t_log after insert or update or delete on public.payments         for each row execute function public.log_change('payment');
create trigger t_log after insert or update or delete on public.driver_pay_items for each row execute function public.log_change('driver_pay');
create trigger t_log after insert or update or delete on public.settlements      for each row execute function public.log_change('settlement');
create trigger t_log after insert or update or delete on public.purchase_orders  for each row execute function public.log_change('purchase_order');
create trigger t_log after insert or update or delete on public.vendor_bills     for each row execute function public.log_change('vendor_bill');
create trigger t_log after insert or update or delete on public.card_expenses    for each row execute function public.log_change('card_expense');

-- ---------------------------------------------------------------------
-- 10. SECURITY
-- Money tables: billing and owner full. Dispatch sees invoices/POs and
-- can raise POs (lumper, road). Drivers see their own pay only.
-- ---------------------------------------------------------------------
alter table public.invoices         enable row level security;
alter table public.invoice_lines    enable row level security;
alter table public.payments         enable row level security;
alter table public.driver_pay_items enable row level security;
alter table public.settlements      enable row level security;
alter table public.purchase_orders  enable row level security;
alter table public.vendor_bills     enable row level security;
alter table public.card_expenses    enable row level security;
alter table public.export_log       enable row level security;
revoke all on all tables in schema public from anon;

create policy inv_read on public.invoices for select to authenticated
  using (public.has_role('billing') or public.has_role('owner') or public.has_role('dispatch') or public.has_role('sales'));
create policy inv_write on public.invoices for all to authenticated
  using (public.has_role('billing') or public.has_role('owner'))
  with check (public.has_role('billing') or public.has_role('owner'));

create policy invl_read on public.invoice_lines for select to authenticated
  using (public.has_role('billing') or public.has_role('owner') or public.has_role('dispatch'));
create policy invl_write on public.invoice_lines for all to authenticated
  using (public.has_role('billing') or public.has_role('owner'))
  with check (public.has_role('billing') or public.has_role('owner'));

create policy pay_all on public.payments for all to authenticated
  using (public.has_role('billing') or public.has_role('owner'))
  with check (public.has_role('billing') or public.has_role('owner'));

create policy dpay_read on public.driver_pay_items for select to authenticated
  using (public.has_role('billing') or public.has_role('owner') or public.has_role('dispatch')
         or driver_id = public.my_driver_id());
create policy dpay_write on public.driver_pay_items for all to authenticated
  using (public.has_role('billing') or public.has_role('owner') or public.has_role('dispatch'))
  with check (public.has_role('billing') or public.has_role('owner') or public.has_role('dispatch'));

create policy stl_read on public.settlements for select to authenticated
  using (public.has_role('billing') or public.has_role('owner') or driver_id = public.my_driver_id());
create policy stl_write on public.settlements for all to authenticated
  using (public.has_role('billing') or public.has_role('owner'))
  with check (public.has_role('billing') or public.has_role('owner'));

create policy po_read on public.purchase_orders for select to authenticated
  using (public.is_office() or driver_id = public.my_driver_id());
create policy po_write on public.purchase_orders for all to authenticated
  using (public.has_role('billing') or public.has_role('owner') or public.has_role('dispatch') or public.has_role('shop_lead'))
  with check (public.has_role('billing') or public.has_role('owner') or public.has_role('dispatch') or public.has_role('shop_lead'));

create policy vb_read on public.vendor_bills for select to authenticated
  using (public.has_role('billing') or public.has_role('owner') or public.has_role('shop_lead'));
create policy vb_write on public.vendor_bills for all to authenticated
  using (public.has_role('billing') or public.has_role('owner'))
  with check (public.has_role('billing') or public.has_role('owner'));

create policy ce_read on public.card_expenses for select to authenticated
  using (public.has_role('billing') or public.has_role('owner')
         or spent_by_driver_id = public.my_driver_id() or spent_by_user_id = auth.uid());
create policy ce_insert on public.card_expenses for insert to authenticated
  with check (spent_by_driver_id = public.my_driver_id() or spent_by_user_id = auth.uid()
              or public.has_role('billing') or public.has_role('owner'));
create policy ce_update on public.card_expenses for update to authenticated
  using (public.has_role('billing') or public.has_role('owner')
         or (reviewed_at is null and (spent_by_driver_id = public.my_driver_id() or spent_by_user_id = auth.uid())));

create policy export_read on public.export_log for select to authenticated
  using (public.has_role('billing') or public.has_role('owner'));
create policy export_insert on public.export_log for insert to authenticated
  with check (public.has_role('billing') or public.has_role('owner'));

-- Done.
-- =====================================================================
-- LOAD HUNTER / TRAILINER  -  04 SHOP AND RECRUITING
-- Service types and PM schedule, unit service status, work orders,
-- work order lines (labor/parts/outside), parts inventory, breakdowns,
-- driver applicants, 391.23 employer verifications, recruiting campaigns.
-- Run AFTER 03. Paste the whole file and Run.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. SERVICE TYPES: Ditat's schedule carried over, as rows. Derreck
--    fixes the intervals here, not in code.
--    interval = how often. alert = how far ahead to warn.
-- ---------------------------------------------------------------------
create table public.service_types (
  id               uuid primary key default gen_random_uuid(),
  code             text not null unique,
  name             text not null,
  applies_to       text not null check (applies_to in ('truck','trailer','reefer')),
  interval_miles   int,
  alert_miles      int,
  interval_days    int,
  alert_days       int,
  interval_hours   int,                           -- reefer engine hours
  alert_hours      int,
  parent_code      text,                          -- PM A is child of B, B of C
  checklist        text,
  active           boolean not null default true,
  sort_order       int not null default 100,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

insert into public.service_types (code, name, applies_to, interval_miles, alert_miles, interval_days, alert_days, parent_code, checklist, sort_order) values
 ('PM_A',    'PM A',                       'truck', 20000, 15000, null, null, 'PM_B', 'Oil and filter, chassis lube, brakes, lights, tires, belts and hoses', 10),
 ('PM_B',    'PM B',                       'truck', 40000, 30000, null, null, 'PM_C', 'A plus fuel and air filters, coolant check, suspension, driveline', 20),
 ('PM_C',    'PM C',                       'truck', 80000, 60000, null, null, null,   'B plus annual DOT inspection, valve adjust, full fluid service', 30),
 ('OIL',     'Engine oil + filter (synthetic)', 'truck', 25000, 20000, 180, 7,  null, null, 40),
 ('FUEL_FLT','Fuel filters',               'truck', 50000, 30000, 365, 30,  null, null, 50),
 ('AIR_FLT', 'Air filter',                 'truck', 75000, 50000, 500, 365, null, null, 60),
 ('DPF',     'DPF cleaning',               'truck', 300000, 200000, 1000, 700, null, null, 70),
 ('DIFF',    'Differential fluid',         'truck', 500000, 300000, 1500, 1200, null, null, 80),
 ('TRANS',   'Transmission fluid + filter','truck', 500000, 300000, 1500, 1200, null, null, 90),
 ('DOT_TRK', 'Annual DOT inspection',      'truck', null, null, 365, 30, null, null, 100),
 ('TRL_PM',  'Trailer PM',                 'trailer', null, null, 90, 14, null, 'Brakes, lights, tires, doors, floor, air lines', 110),
 ('DOT_TRL', 'Annual DOT inspection',      'trailer', null, null, 365, 30, null, null, 120);
insert into public.service_types (code, name, applies_to, interval_hours, alert_hours, sort_order)
 values ('REEFER_PM', 'Reefer unit PM', 'reefer', 2000, 200, 130);

-- ---------------------------------------------------------------------
-- 2. UNIT SERVICE STATUS: last done / next due per unit per service.
-- ---------------------------------------------------------------------
create table public.unit_services (
  id               uuid primary key default gen_random_uuid(),
  truck_id         uuid references public.trucks(id) on delete cascade,
  trailer_id       uuid references public.trailers(id) on delete cascade,
  service_type_id  uuid not null references public.service_types(id),
  last_done_at     date,
  last_done_miles  int,
  last_done_hours  int,
  next_due_at      date,
  next_due_miles   int,
  next_due_hours   int,
  last_work_order_id uuid,
  notes            text,
  updated_at       timestamptz not null default now(),
  constraint unit_services_one_unit check ((truck_id is null) <> (trailer_id is null)),
  unique (truck_id, service_type_id),
  unique (trailer_id, service_type_id)
);

-- When a service is logged done, roll the next due forward from the intervals.
create or replace function public.roll_service_due()
returns trigger language plpgsql as $$
declare st public.service_types;
begin
  select * into st from public.service_types where id = new.service_type_id;
  if new.last_done_at is not null and st.interval_days is not null then
    new.next_due_at := new.last_done_at + st.interval_days;
  end if;
  if new.last_done_miles is not null and st.interval_miles is not null then
    new.next_due_miles := new.last_done_miles + st.interval_miles;
  end if;
  if new.last_done_hours is not null and st.interval_hours is not null then
    new.next_due_hours := new.last_done_hours + st.interval_hours;
  end if;
  new.updated_at := now();
  return new;
end $$;
create trigger t_roll before insert or update on public.unit_services
  for each row execute function public.roll_service_due();

-- ---------------------------------------------------------------------
-- 3. WORK ORDERS: in-house, roadside, outside shop. One per job.
-- ---------------------------------------------------------------------
create table public.work_orders (
  id               uuid primary key default gen_random_uuid(),
  wo_no            text not null unique,
  truck_id         uuid references public.trucks(id),
  trailer_id       uuid references public.trailers(id),
  wo_type          text not null default 'shop'
                   check (wo_type in ('shop','roadside','outside','pm')),
  status           text not null default 'open'
                   check (status in ('open','in_progress','waiting_parts','waiting_vendor','done','closed','cancelled')),
  priority         text not null default 'normal' check (priority in ('low','normal','high','truck_down')),
  truck_down       boolean not null default false,
  complaint        text not null,                 -- what's wrong, driver's words
  cause            text,
  correction       text,                          -- what was done
  service_type_id  uuid references public.service_types(id),   -- when it's a PM
  odometer         int,
  reefer_hours     int,
  assigned_to      uuid references public.profiles(id),        -- mechanic
  opened_by        uuid references public.profiles(id),
  reported_by_driver_id uuid references public.drivers(id),
  load_id          uuid references public.loads(id),           -- breakdown on a load
  vendor_id        uuid references public.companies(id),       -- outside shop
  location_text    text,                                        -- where the truck is
  eta_back         timestamptz,
  labor_hours      numeric(6,2),
  parts_cost       numeric(12,2) not null default 0,
  labor_cost       numeric(12,2) not null default 0,
  outside_cost     numeric(12,2) not null default 0,
  total_cost       numeric(12,2) generated always as (parts_cost + labor_cost + outside_cost) stored,
  opened_at        timestamptz not null default now(),
  started_at       timestamptz,
  done_at          timestamptz,
  closed_at        timestamptz,
  closed_by        uuid references public.profiles(id),
  notes            text,
  extra            jsonb not null default '{}',
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint wo_one_unit check (truck_id is not null or trailer_id is not null)
);
create index wo_status_idx on public.work_orders (status);
create index wo_truck_idx  on public.work_orders (truck_id, opened_at desc);
create index wo_trailer_idx on public.work_orders (trailer_id, opened_at desc);
create index wo_open_idx   on public.work_orders (truck_id) where status not in ('closed','cancelled');

create sequence public.wo_seq start 1001;
create or replace function public.next_wo_no()
returns text language sql as $$ select 'WO-' || nextval('public.wo_seq')::text; $$;

-- tie purchase_orders.work_order_id now that the table exists
alter table public.purchase_orders
  add constraint po_wo_fk foreign key (work_order_id) references public.work_orders(id);

-- Truck in shop / truck down: flip the truck status with the WO.
create or replace function public.wo_unit_status()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.truck_id is not null then
    if new.status in ('open','in_progress','waiting_parts','waiting_vendor') and (new.truck_down or new.wo_type = 'roadside') then
      update public.trucks set status = 'in_shop' where id = new.truck_id and status = 'active';
    elsif new.status in ('closed','cancelled')
      and not exists (select 1 from public.work_orders w where w.truck_id = new.truck_id and w.id <> new.id
                      and w.status not in ('closed','cancelled') and (w.truck_down or w.wo_type = 'roadside')) then
      update public.trucks set status = 'active' where id = new.truck_id and status = 'in_shop';
    end if;
  end if;
  if new.trailer_id is not null then
    if new.status in ('open','in_progress','waiting_parts','waiting_vendor') and new.truck_down then
      update public.trailers set status = 'in_shop' where id = new.trailer_id and status = 'active';
    elsif new.status in ('closed','cancelled')
      and not exists (select 1 from public.work_orders w where w.trailer_id = new.trailer_id and w.id <> new.id
                      and w.status not in ('closed','cancelled') and w.truck_down) then
      update public.trailers set status = 'active' where id = new.trailer_id and status = 'in_shop';
    end if;
  end if;
  return new;
end $$;
create trigger t_wo_unit after insert or update of status, truck_down on public.work_orders
  for each row execute function public.wo_unit_status();

-- Closing a PM work order marks the service done on the unit.
create or replace function public.wo_close_service()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'closed' and old.status <> 'closed' then
    new.closed_at := coalesce(new.closed_at, now());
    new.closed_by := coalesce(new.closed_by, auth.uid());
    if new.service_type_id is not null then
      insert into public.unit_services (truck_id, trailer_id, service_type_id, last_done_at, last_done_miles, last_done_hours, last_work_order_id)
      values (new.truck_id, new.trailer_id, new.service_type_id, coalesce(new.done_at, now())::date, new.odometer, new.reefer_hours, new.id)
      on conflict (truck_id, service_type_id) where truck_id is not null do update
        set last_done_at = excluded.last_done_at, last_done_miles = excluded.last_done_miles,
            last_done_hours = excluded.last_done_hours, last_work_order_id = excluded.last_work_order_id;
      if new.trailer_id is not null then
        insert into public.unit_services (truck_id, trailer_id, service_type_id, last_done_at, last_done_miles, last_done_hours, last_work_order_id)
        values (null, new.trailer_id, new.service_type_id, coalesce(new.done_at, now())::date, null, new.reefer_hours, new.id)
        on conflict (trailer_id, service_type_id) where trailer_id is not null do update
          set last_done_at = excluded.last_done_at, last_done_hours = excluded.last_done_hours,
              last_work_order_id = excluded.last_work_order_id;
      end if;
    end if;
  end if;
  return new;
end $$;
create trigger t_wo_close before update on public.work_orders
  for each row execute function public.wo_close_service();

-- ---------------------------------------------------------------------
-- 4. WORK ORDER LINES: labor, parts, outside charges.
-- ---------------------------------------------------------------------
create table public.work_order_lines (
  id               uuid primary key default gen_random_uuid(),
  work_order_id    uuid not null references public.work_orders(id) on delete cascade,
  line_type        text not null check (line_type in ('labor','part','outside','note','photo')),
  description      text,
  part_id          uuid,                                      -- set below
  qty              numeric(10,2) not null default 1,
  unit_cost        numeric(12,2) not null default 0,
  amount           numeric(12,2) generated always as (round(qty * unit_cost, 2)) stored,
  mechanic_id      uuid references public.profiles(id),
  hours            numeric(6,2),
  po_id            uuid references public.purchase_orders(id),
  doc_id           uuid references public.documents(id),      -- photo
  created_by       uuid default auth.uid(),
  created_at       timestamptz not null default now()
);
create index wol_wo_idx on public.work_order_lines (work_order_id);

create or replace function public.wo_retotal()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_id uuid := coalesce(new.work_order_id, old.work_order_id);
begin
  update public.work_orders w set
    parts_cost   = coalesce((select sum(amount) from public.work_order_lines where work_order_id = v_id and line_type = 'part'), 0),
    labor_cost   = coalesce((select sum(amount) from public.work_order_lines where work_order_id = v_id and line_type = 'labor'), 0),
    outside_cost = coalesce((select sum(amount) from public.work_order_lines where work_order_id = v_id and line_type = 'outside'), 0),
    labor_hours  = (select sum(hours) from public.work_order_lines where work_order_id = v_id and line_type = 'labor')
  where w.id = v_id;
  return coalesce(new, old);
end $$;
create trigger t_wo_retotal after insert or update or delete on public.work_order_lines
  for each row execute function public.wo_retotal();

-- ---------------------------------------------------------------------
-- 5. PARTS INVENTORY: bought to stock on an inventory PO, cost moves to
--    the unit only when Derreck issues the part to a work order.
-- ---------------------------------------------------------------------
create table public.parts (
  id               uuid primary key default gen_random_uuid(),
  part_no          text not null unique,
  description      text not null,
  category         text,
  vendor_id        uuid references public.companies(id),
  vendor_part_no   text,
  on_hand          numeric(10,2) not null default 0,
  min_stock        numeric(10,2) not null default 0,
  last_cost        numeric(12,2),
  avg_cost         numeric(12,2),
  bin              text,
  active           boolean not null default true,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
alter table public.work_order_lines
  add constraint wol_part_fk foreign key (part_id) references public.parts(id);

create table public.part_movements (
  id               bigint generated always as identity primary key,
  part_id          uuid not null references public.parts(id),
  qty              numeric(10,2) not null,                    -- + in, - out
  reason           text not null check (reason in ('received','issued','returned','adjusted','scrapped')),
  po_id            uuid references public.purchase_orders(id),
  work_order_id    uuid references public.work_orders(id),
  unit_cost        numeric(12,2),
  user_id          uuid default auth.uid(),
  at               timestamptz not null default now(),
  notes            text
);
create index part_mov_part_idx on public.part_movements (part_id, at desc);

create or replace function public.apply_part_movement()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.parts p
     set on_hand = on_hand + new.qty,
         last_cost = case when new.reason = 'received' and new.unit_cost is not null then new.unit_cost else last_cost end,
         avg_cost  = case when new.reason = 'received' and new.unit_cost is not null and new.qty > 0
                          then round((coalesce(avg_cost,0) * greatest(on_hand,0) + new.unit_cost * new.qty) / (greatest(on_hand,0) + new.qty), 2)
                          else avg_cost end,
         updated_at = now()
   where p.id = new.part_id;
  -- issuing to a work order puts the cost on the unit
  if new.reason = 'issued' and new.work_order_id is not null then
    insert into public.work_order_lines (work_order_id, line_type, description, part_id, qty, unit_cost, created_by)
    select new.work_order_id, 'part', p.description, p.id, -new.qty, coalesce(new.unit_cost, p.avg_cost, p.last_cost, 0), new.user_id
    from public.parts p where p.id = new.part_id;
  end if;
  return new;
end $$;
create trigger t_part_mov after insert on public.part_movements
  for each row execute function public.apply_part_movement();

-- ---------------------------------------------------------------------
-- 6. RECRUITING: applicants, employment history, 391.23 verifications,
--    campaigns. Hire = row written to drivers.
-- ---------------------------------------------------------------------
create table public.applicants (
  id               uuid primary key default gen_random_uuid(),
  stage            text not null default 'new'
                   check (stage in ('new','screening','verifying','offer','hired','declined','withdrawn')),
  source           text,                                      -- transforce, indeed, referral, walk-in
  campaign_id      uuid,
  first_name       text not null,
  last_name        text not null,
  phone            text,
  email            text,
  address          text,
  city             text,
  state            text,
  zip              text,
  applied_on       date not null default current_date,
  license_state    text,
  license_class    text,
  license_expires  date,
  medical_expires  date,
  hazmat           boolean not null default false,
  tanker           boolean not null default false,
  doubles          boolean not null default false,
  years_experience numeric(4,1),
  cmv_months       numeric(6,1),                              -- calculated from history
  accidents_3yr    int,
  violations_3yr   int,
  dui_ever         boolean,
  flags            jsonb not null default '[]',               -- compliance flags from the app
  hire_gate_ok     boolean not null default false,
  recruiter_id     uuid references public.profiles(id),
  decline_reason   text,
  hired_driver_id  uuid references public.drivers(id),
  hired_on         date,
  notes            text,
  application      jsonb not null default '{}',               -- full 391.21 form as submitted
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index applicants_stage_idx on public.applicants (stage, applied_on desc);
create index applicants_phone_idx on public.applicants (phone);

-- DOB and license number for applicants go in the same locked table style as drivers.
create table public.applicant_private (
  applicant_id     uuid primary key references public.applicants(id) on delete cascade,
  date_of_birth    date,
  license_number   text,
  updated_at       timestamptz not null default now()
);

create table public.applicant_employers (
  id               uuid primary key default gen_random_uuid(),
  applicant_id     uuid not null references public.applicants(id) on delete cascade,
  employer         text not null,
  usdot            text,
  contact          text,
  phone            text,
  email            text,
  fax              text,
  from_date        date,
  to_date          date,
  position         text,
  cmv              boolean not null default true,              -- drove a CMV there
  reason_left      text,
  subject_to_fmcsr boolean,
  drug_testing     boolean,
  -- 391.23 verification
  ver_status       text not null default 'pending'
                   check (ver_status in ('pending','sent','received','no_response','not_required')),
  ver_sent_at      timestamptz,
  ver_received_at  timestamptz,
  ver_result       text,
  ver_attempts     jsonb not null default '[]',
  ver_doc_id       uuid references public.documents(id),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index app_emp_idx on public.applicant_employers (applicant_id);

create table public.campaigns (
  id               uuid primary key default gen_random_uuid(),
  vendor           text not null,                             -- TransForce
  name             text not null,
  starts_on        date,
  days             int,
  cost             numeric(12,2),
  delivery         text,
  api_key_ref      text,                                      -- name of the server-side secret, never the key
  notes            text,
  active           boolean not null default true,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
alter table public.applicants
  add constraint applicants_campaign_fk foreign key (campaign_id) references public.campaigns(id);

-- Hiring an applicant creates the driver (or finds the rehire by license/phone).
create or replace function public.hire_applicant(p_applicant uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare a public.applicants; ap public.applicant_private; d_id uuid;
begin
  if not (public.has_role('safety') or public.has_role('owner') or public.is_admin()) then
    raise exception 'Only safety or owner can hire';
  end if;
  select * into a from public.applicants where id = p_applicant;
  if a.id is null then raise exception 'Applicant not found'; end if;
  if not a.hire_gate_ok then raise exception 'Hire gate is not clear on %', a.first_name || ' ' || a.last_name; end if;
  select * into ap from public.applicant_private where applicant_id = p_applicant;

  -- rehire match on license number, then phone
  select d.id into d_id from public.drivers d join public.driver_private dp on dp.driver_id = d.id
   where ap.license_number is not null and dp.license_number = ap.license_number limit 1;
  if d_id is null and a.phone is not null then
    select d.id into d_id from public.drivers d
     where regexp_replace(d.phone, '\D', '', 'g') = regexp_replace(a.phone, '\D', '', 'g') limit 1;
  end if;

  if d_id is null then
    insert into public.drivers (first_name, last_name, status, phone, email, address, city, state, zip, hired_on,
      license_state, license_class, license_expires, medical_expires, hazmat, tanker, doubles, years_experience, application_on, recruited_by)
    values (a.first_name, a.last_name, 'active', a.phone, a.email, a.address, a.city, a.state, a.zip, current_date,
      a.license_state, a.license_class, a.license_expires, a.medical_expires, a.hazmat, a.tanker, a.doubles, a.years_experience, a.applied_on,
      (select full_name from public.profiles where id = a.recruiter_id))
    returning id into d_id;
  else
    update public.drivers set status = 'active', prev_hired_on = hired_on, prev_terminated_on = terminated_on,
      hired_on = current_date, terminated_on = null, term_reason = null, phone = coalesce(a.phone, phone), email = coalesce(a.email, email)
    where id = d_id;
  end if;

  insert into public.driver_private (driver_id, date_of_birth, license_number)
  values (d_id, ap.date_of_birth, ap.license_number)
  on conflict (driver_id) do update set date_of_birth = coalesce(excluded.date_of_birth, driver_private.date_of_birth),
                                        license_number = coalesce(excluded.license_number, driver_private.license_number);

  update public.applicants set stage = 'hired', hired_driver_id = d_id, hired_on = current_date where id = p_applicant;
  return d_id;
end $$;

-- ---------------------------------------------------------------------
-- 7. TRIGGERS
-- ---------------------------------------------------------------------
create trigger t_touch before update on public.service_types      for each row execute function public.touch_updated_at();
create trigger t_touch before update on public.work_orders        for each row execute function public.touch_updated_at();
create trigger t_touch before update on public.parts              for each row execute function public.touch_updated_at();
create trigger t_touch before update on public.applicants         for each row execute function public.touch_updated_at();
create trigger t_touch before update on public.applicant_employers for each row execute function public.touch_updated_at();
create trigger t_touch before update on public.campaigns          for each row execute function public.touch_updated_at();

create trigger t_log after insert or update or delete on public.service_types       for each row execute function public.log_change('service_type');
create trigger t_log after insert or update or delete on public.unit_services       for each row execute function public.log_change('unit_service');
create trigger t_log after insert or update or delete on public.work_orders         for each row execute function public.log_change('work_order');
create trigger t_log after insert or update or delete on public.work_order_lines    for each row execute function public.log_change('work_order_line');
create trigger t_log after insert or update or delete on public.parts               for each row execute function public.log_change('part');
create trigger t_log after insert or update or delete on public.applicants          for each row execute function public.log_change('applicant');
create trigger t_log after insert or update or delete on public.applicant_employers for each row execute function public.log_change('applicant_employer');
create trigger t_log after insert or update or delete on public.campaigns           for each row execute function public.log_change('campaign');
-- applicant_private: log that it changed, never the values
create or replace function public.log_applicant_private_change()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into activity_log(entity_type, entity_id, action, detail)
  values ('applicant_private', coalesce(new.applicant_id, old.applicant_id)::text,
          lower(tg_op), '{"note":"sensitive fields changed, values not logged"}');
  return coalesce(new, old);
end $$;
create trigger t_log after insert or update or delete on public.applicant_private
  for each row execute function public.log_applicant_private_change();

-- ---------------------------------------------------------------------
-- 8. SECURITY
-- ---------------------------------------------------------------------
alter table public.service_types       enable row level security;
alter table public.unit_services       enable row level security;
alter table public.work_orders         enable row level security;
alter table public.work_order_lines    enable row level security;
alter table public.parts               enable row level security;
alter table public.part_movements      enable row level security;
alter table public.applicants          enable row level security;
alter table public.applicant_private   enable row level security;
alter table public.applicant_employers enable row level security;
alter table public.campaigns           enable row level security;
revoke all on all tables in schema public from anon;

create or replace function public.is_shop()
returns boolean language sql stable security definer set search_path = public as $$
  select public.has_role('shop_lead') or public.has_role('mechanic') or public.has_role('owner') or public.is_admin();
$$;

-- Service types and unit status: everyone reads; shop lead / owner edit.
create policy st_read on public.service_types for select to authenticated using (true);
create policy st_write on public.service_types for all to authenticated
  using (public.has_role('shop_lead') or public.has_role('owner')) with check (public.has_role('shop_lead') or public.has_role('owner'));
create policy us_read on public.unit_services for select to authenticated using (true);
create policy us_write on public.unit_services for all to authenticated
  using (public.has_role('shop_lead') or public.has_role('owner')) with check (public.has_role('shop_lead') or public.has_role('owner'));

-- Work orders: office and shop read; dispatch can open (roadside); shop lead
-- edits all; mechanic edits what's assigned to him; drivers read WOs on their truck.
create policy wo_read on public.work_orders for select to authenticated
  using (public.is_office() or public.is_shop()
         or truck_id in (select truck_id from public.drivers where profile_id = auth.uid()));
create policy wo_insert on public.work_orders for insert to authenticated
  with check (public.is_office() or public.is_shop() or public.has_role('driver'));
create policy wo_update on public.work_orders for update to authenticated
  using (public.has_role('shop_lead') or public.has_role('owner') or public.has_role('dispatch')
         or (public.has_role('mechanic') and assigned_to = auth.uid()));

create policy wol_read on public.work_order_lines for select to authenticated
  using (public.is_office() or public.is_shop());
create policy wol_write on public.work_order_lines for all to authenticated
  using (public.is_shop()) with check (public.is_shop());

create policy parts_read on public.parts for select to authenticated using (public.is_office() or public.is_shop());
create policy parts_write on public.parts for all to authenticated
  using (public.has_role('shop_lead') or public.has_role('owner')) with check (public.has_role('shop_lead') or public.has_role('owner'));
create policy pm_read on public.part_movements for select to authenticated using (public.is_office() or public.is_shop());
create policy pm_insert on public.part_movements for insert to authenticated
  with check (public.has_role('shop_lead') or public.has_role('owner'));

-- Recruiting: safety (driver manager) and owner. Dispatch can read the pipeline.
create policy app_read on public.applicants for select to authenticated
  using (public.has_role('safety') or public.has_role('owner') or public.has_role('dispatch'));
create policy app_write on public.applicants for all to authenticated
  using (public.has_role('safety') or public.has_role('owner')) with check (public.has_role('safety') or public.has_role('owner'));
create policy appp_all on public.applicant_private for all to authenticated
  using (public.has_role('safety') or public.is_admin()) with check (public.has_role('safety') or public.is_admin());
create policy appe_all on public.applicant_employers for all to authenticated
  using (public.has_role('safety') or public.has_role('owner')) with check (public.has_role('safety') or public.has_role('owner'));
create policy camp_all on public.campaigns for all to authenticated
  using (public.has_role('safety') or public.has_role('owner')) with check (public.has_role('safety') or public.has_role('owner'));

-- Done.
