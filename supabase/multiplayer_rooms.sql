-- FocusForge Quest: multiplayer rooms
-- Run this once in Supabase Dashboard > SQL Editor.
-- Room presence and live round events use Supabase Realtime channels.

create table if not exists public.multiplayer_rooms (
  id uuid primary key default gen_random_uuid(),
  room_code text not null unique
    check (room_code ~ '^[A-HJ-NP-Z2-9]{6}$'),
  host_user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '2 hours')
);

create index if not exists multiplayer_rooms_expires_at_idx
  on public.multiplayer_rooms (expires_at);

alter table public.multiplayer_rooms enable row level security;

revoke all on public.multiplayer_rooms from anon;
grant select, insert, update, delete on public.multiplayer_rooms to authenticated;

drop policy if exists "Authenticated users can find active rooms"
  on public.multiplayer_rooms;
create policy "Authenticated users can find active rooms"
  on public.multiplayer_rooms
  for select to authenticated
  using (expires_at > now());

drop policy if exists "Users can create their own rooms"
  on public.multiplayer_rooms;
create policy "Users can create their own rooms"
  on public.multiplayer_rooms
  for insert to authenticated
  with check (auth.uid() = host_user_id);

drop policy if exists "Hosts can update their own rooms"
  on public.multiplayer_rooms;
create policy "Hosts can update their own rooms"
  on public.multiplayer_rooms
  for update to authenticated
  using (auth.uid() = host_user_id)
  with check (auth.uid() = host_user_id);

drop policy if exists "Hosts can delete their own rooms"
  on public.multiplayer_rooms;
create policy "Hosts can delete their own rooms"
  on public.multiplayer_rooms
  for delete to authenticated
  using (auth.uid() = host_user_id);

-- Old room records can be deleted periodically from the SQL editor:
-- delete from public.multiplayer_rooms where expires_at <= now();
