-- FocusForge Quest: account-based campaign progress
-- Run once in Supabase Dashboard -> SQL Editor.

create table if not exists public.campaign_progress (
  user_id uuid primary key references auth.users(id) on delete cascade,
  progress jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

alter table public.campaign_progress enable row level security;

grant select, insert, update on public.campaign_progress to authenticated;

drop policy if exists "Players can read their own campaign progress" on public.campaign_progress;
create policy "Players can read their own campaign progress"
  on public.campaign_progress for select
  to authenticated
  using (auth.uid() = user_id);

drop policy if exists "Players can insert their own campaign progress" on public.campaign_progress;
create policy "Players can insert their own campaign progress"
  on public.campaign_progress for insert
  to authenticated
  with check (auth.uid() = user_id);

drop policy if exists "Players can update their own campaign progress" on public.campaign_progress;
create policy "Players can update their own campaign progress"
  on public.campaign_progress for update
  to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);
