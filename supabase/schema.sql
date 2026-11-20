-- Ashen Crown shared-world backend (Supabase / PostgreSQL)
-- Run in Supabase SQL Editor after enabling Email + Google providers in Auth.
create extension if not exists pgcrypto;

create table if not exists public.characters (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  name text not null check (char_length(name) between 2 and 18),
  class text not null check (class in ('swordsman','mage','priest','guardian')),
  level integer not null default 1 check (level between 1 and 100),
  xp integer not null default 0 check (xp >= 0),
  gold integer not null default 0 check (gold >= 0),
  location text not null default 'Village of Embers',
  evolution integer not null default 0 check (evolution between 0 and 3),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists characters_owner_idx on public.characters(owner_id);

create table if not exists public.parties (
  id uuid primary key default gen_random_uuid(),
  invite_code text not null unique default upper(substr(encode(gen_random_bytes(6),'hex'),1,8)),
  leader_character uuid not null references public.characters(id) on delete cascade,
  dungeon text,
  status text not null default 'forming' check (status in ('forming','in_dungeon','disbanded')),
  created_at timestamptz not null default now()
);
create table if not exists public.party_members (
  party_id uuid not null references public.parties(id) on delete cascade,
  character_id uuid not null references public.characters(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key(party_id,character_id),
  unique(character_id)
);
create table if not exists public.dungeon_runs (
  id uuid primary key default gen_random_uuid(),
  party_id uuid references public.parties(id) on delete set null,
  dungeon text not null,
  state jsonb not null default '{}'::jsonb,
  status text not null default 'active' check (status in ('active','complete','failed')),
  started_at timestamptz not null default now(),
  ended_at timestamptz
);

alter table public.characters enable row level security;
alter table public.parties enable row level security;
alter table public.party_members enable row level security;
alter table public.dungeon_runs enable row level security;

drop policy if exists "owners manage own characters" on public.characters;
create policy "owners manage own characters" on public.characters for all
 using (owner_id = auth.uid()) with check (owner_id = auth.uid());

drop policy if exists "party members can view parties" on public.parties;
create policy "party members can view parties" on public.parties for select
 using (exists(select 1 from public.party_members pm join public.characters c on c.id=pm.character_id where pm.party_id=id and c.owner_id=auth.uid()));
drop policy if exists "leaders create parties" on public.parties;
create policy "leaders create parties" on public.parties for insert
 with check (exists(select 1 from public.characters c where c.id=leader_character and c.owner_id=auth.uid()));
drop policy if exists "leaders update parties" on public.parties;
create policy "leaders update parties" on public.parties for update
 using (exists(select 1 from public.characters c where c.id=leader_character and c.owner_id=auth.uid()))
 with check (exists(select 1 from public.characters c where c.id=leader_character and c.owner_id=auth.uid()));

drop policy if exists "members view party rosters" on public.party_members;
create policy "members view party rosters" on public.party_members for select
 using (exists(select 1 from public.party_members mine join public.characters c on c.id=mine.character_id where mine.party_id=party_id and c.owner_id=auth.uid()));
drop policy if exists "owners join with own character" on public.party_members;
create policy "owners join with own character" on public.party_members for insert
 with check (exists(select 1 from public.characters c where c.id=character_id and c.owner_id=auth.uid()));
drop policy if exists "owners leave own character" on public.party_members;
create policy "owners leave own character" on public.party_members for delete
 using (exists(select 1 from public.characters c where c.id=character_id and c.owner_id=auth.uid()));

drop policy if exists "party members view dungeon runs" on public.dungeon_runs;
create policy "party members view dungeon runs" on public.dungeon_runs for select
 using (party_id is not null and exists(select 1 from public.party_members pm join public.characters c on c.id=pm.character_id where pm.party_id=dungeon_runs.party_id and c.owner_id=auth.uid()));
drop policy if exists "party members create dungeon runs" on public.dungeon_runs;
create policy "party members create dungeon runs" on public.dungeon_runs for insert
 with check (party_id is not null and exists(select 1 from public.party_members pm join public.characters c on c.id=pm.character_id where pm.party_id=dungeon_runs.party_id and c.owner_id=auth.uid()));

-- Enable Realtime for live party rosters and shared dungeon status.
do $$ begin
  alter publication supabase_realtime add table public.party_members;
exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table public.parties;
exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table public.dungeon_runs;
exception when duplicate_object then null; when undefined_object then null; end $$;
