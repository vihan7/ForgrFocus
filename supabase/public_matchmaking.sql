-- FocusForge Quest: public matchmaking
-- Run this migration in Supabase Dashboard > SQL Editor after the PR is merged.
-- Private room creation and room-code joining are not changed by this migration.

alter table public.multiplayer_rooms
  add column if not exists is_public boolean not null default false,
  add column if not exists status text not null default 'waiting'
    check (status in ('waiting','started')),
  add column if not exists player_count integer not null default 1
    check (player_count between 0 and 5),
  add column if not exists countdown_started_at timestamptz,
  add column if not exists started_at timestamptz;

create index if not exists multiplayer_public_waiting_idx
  on public.multiplayer_rooms (is_public, status, player_count, created_at)
  where is_public = true;

create table if not exists public.public_room_members (
  room_id uuid not null references public.multiplayer_rooms(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (room_id, user_id),
  unique (user_id)
);

alter table public.public_room_members enable row level security;
revoke all on public.public_room_members from anon, authenticated;

create or replace function public.join_public_room()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_room public.multiplayer_rooms%rowtype;
  v_count integer;
  v_code text;
begin
  if v_user is null then
    raise exception 'Please sign in before joining public matchmaking.';
  end if;

  -- Finish any countdown that expired even if its host disconnected.
  update public.multiplayer_rooms
     set status = 'started', started_at = coalesce(started_at, now())
   where is_public = true
     and status = 'waiting'
     and countdown_started_at is not null
     and countdown_started_at <= now() - interval '30 seconds';

  -- Reuse an existing membership if this user retries the request.
  select r.* into v_room
    from public.public_room_members m
    join public.multiplayer_rooms r on r.id = m.room_id
   where m.user_id = v_user
     and r.is_public = true
     and r.status = 'waiting'
     and r.expires_at > now()
   limit 1;

  if found then
    select count(*) into v_count
      from public.public_room_members where room_id = v_room.id;
    return jsonb_build_object(
      'room_id', v_room.id, 'room_code', v_room.room_code,
      'host_user_id', v_room.host_user_id, 'player_count', v_count,
      'countdown_started_at', v_room.countdown_started_at,
      'status', v_room.status
    );
  end if;

  -- Lock the least-populated eligible room so concurrent joins cannot exceed 5.
  select * into v_room
    from public.multiplayer_rooms
   where is_public = true
     and status = 'waiting'
     and player_count < 5
     and expires_at > now()
   order by player_count asc, created_at asc
   for update skip locked
   limit 1;

  if not found then
    loop
      v_code := '';
      while length(v_code) < 6 loop
        v_code := v_code || substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789',
          1 + floor(random() * 32)::integer, 1);
      end loop;
      begin
        insert into public.multiplayer_rooms
          (room_code, host_id, host_user_id, is_public, status, player_count)
        values
          (v_code, v_user, v_user, true, 'waiting', 0)
        returning * into v_room;
        exit;
      exception when unique_violation then
        -- Generate another code and retry.
      end;
    end loop;
  end if;

  insert into public.public_room_members(room_id, user_id)
  values (v_room.id, v_user)
  on conflict (user_id) do nothing;

  select count(*) into v_count
    from public.public_room_members where room_id = v_room.id;

  update public.multiplayer_rooms
     set player_count = v_count,
         countdown_started_at = case
           when v_count >= 2 then coalesce(countdown_started_at, now())
           else countdown_started_at
         end
   where id = v_room.id
   returning * into v_room;

  return jsonb_build_object(
    'room_id', v_room.id, 'room_code', v_room.room_code,
    'host_user_id', v_room.host_user_id, 'player_count', v_count,
    'countdown_started_at', v_room.countdown_started_at,
    'status', v_room.status
  );
end;
$$;

create or replace function public.leave_public_room(p_room_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_count integer;
begin
  if v_user is null then
    raise exception 'Please sign in.';
  end if;

  delete from public.public_room_members
   where room_id = p_room_id and user_id = v_user;

  select count(*) into v_count
    from public.public_room_members where room_id = p_room_id;

  if v_count = 0 then
    delete from public.multiplayer_rooms
     where id = p_room_id and is_public = true;
  else
    update public.multiplayer_rooms
       set player_count = v_count
     where id = p_room_id and is_public = true and status = 'waiting';
  end if;
end;
$$;

create or replace function public.start_public_room(p_room_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_room public.multiplayer_rooms%rowtype;
  v_count integer;
begin
  if v_user is null then
    raise exception 'Please sign in.';
  end if;

  select * into v_room
    from public.multiplayer_rooms
   where id = p_room_id and is_public = true
   for update;

  if not found then
    raise exception 'Public room not found.';
  end if;

  if not exists (
    select 1 from public.public_room_members
     where room_id = p_room_id and user_id = v_user
  ) then
    raise exception 'You are not a member of this room.';
  end if;

  select count(*) into v_count
    from public.public_room_members where room_id = p_room_id;

  if v_room.status = 'started' then
    return jsonb_build_object('status','started','player_count',v_count,'started_by_me',false);
  end if;

  if v_count < 2 then
    raise exception 'At least two players are needed to start.';
  end if;

  if v_room.countdown_started_at is null
     or v_room.countdown_started_at > now() - interval '30 seconds' then
    raise exception 'The 30-second lobby countdown has not finished.';
  end if;

  update public.multiplayer_rooms
     set status = 'started', started_at = coalesce(started_at, now()),
         player_count = v_count
   where id = p_room_id
   returning * into v_room;

  return jsonb_build_object(
    'status', v_room.status, 'started_at', v_room.started_at,
    'player_count', v_count, 'room_code', v_room.room_code,
    'started_by_me', true
  );
end;
$$;

revoke all on function public.join_public_room() from public;
revoke all on function public.leave_public_room(uuid) from public;
revoke all on function public.start_public_room(uuid) from public;
grant execute on function public.join_public_room() to authenticated;
grant execute on function public.leave_public_room(uuid) to authenticated;
grant execute on function public.start_public_room(uuid) to authenticated;
