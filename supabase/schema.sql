-- Task di coppia: schema, RLS and functions.
-- Run once in Supabase > SQL Editor.

-- =========================================================
-- Tables
-- =========================================================

create table public.profiles (
  id             uuid primary key references auth.users on delete cascade,
  name           text not null default '',
  invite_code    text not null unique default upper(substr(md5(gen_random_uuid()::text), 1, 8)),
  partner_id     uuid unique references public.profiles(id) on delete set null,
  reminder_hours int  not null default 6 check (reminder_hours between 1 and 168)
);

-- status: pool -> active (drawn) -> done (recipient says done) -> completed (author confirms)
create table public.tasks (
  id               bigint generated always as identity primary key,
  author_id        uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  recipient_id     uuid not null references public.profiles(id) on delete cascade,
  text             text not null check (length(text) between 1 and 500),
  reward           text not null check (length(reward) between 1 and 300),
  punishment       text not null check (length(punishment) between 1 and 300),
  status           text not null default 'pool' check (status in ('pool', 'active', 'done', 'completed')),
  doublings        int  not null default 0,   -- punishment multiplier = 2^doublings
  created_at       timestamptz not null default now(),
  drawn_at         timestamptz,
  done_at          timestamptz,
  completed_at     timestamptz,
  last_reminder_at timestamptz
);
create index tasks_recipient_status on public.tasks (recipient_id, status);
-- At most one open task per person.
create unique index tasks_one_open on public.tasks (recipient_id) where status in ('active', 'done');

create table public.push_subscriptions (
  endpoint   text primary key,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  p256dh     text not null,
  auth       text not null,
  created_at timestamptz not null default now()
);

-- One row per ISO week in which the draw has run (makes the draw idempotent).
create table public.draw_log (
  week   date primary key,
  ran_at timestamptz not null default now()
);

-- =========================================================
-- Privileges: clients get only what they need; everything else via RPC.
-- =========================================================

revoke all on public.profiles, public.tasks, public.push_subscriptions, public.draw_log from anon, authenticated;
grant all on public.profiles, public.tasks, public.push_subscriptions, public.draw_log to service_role;

grant select on public.profiles, public.tasks to authenticated;
grant update (name, reminder_hours) on public.profiles to authenticated;
grant insert (recipient_id, text, reward, punishment) on public.tasks to authenticated;

alter table public.profiles           enable row level security;
alter table public.tasks              enable row level security;
alter table public.push_subscriptions enable row level security;
alter table public.draw_log           enable row level security;

-- =========================================================
-- RLS
-- =========================================================

create function public.my_partner() returns uuid
language sql stable security definer set search_path = '' as $$
  select partner_id from public.profiles where id = auth.uid()
$$;

create policy "profiles_select_me_and_partner" on public.profiles
  for select to authenticated
  using (id = auth.uid() or id = public.my_partner());

create policy "profiles_update_me" on public.profiles
  for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

-- The author sees everything they wrote; the recipient never sees the pool.
create policy "tasks_select" on public.tasks
  for select to authenticated
  using (author_id = auth.uid() or (recipient_id = auth.uid() and status <> 'pool'));

-- Insert only for one's own partner (status/doublings/author come from defaults).
create policy "tasks_insert_for_partner" on public.tasks
  for insert to authenticated
  with check (author_id = auth.uid() and recipient_id = public.my_partner());

-- push_subscriptions and draw_log: no policies -> clients have no direct access.

-- =========================================================
-- New user -> profile
-- =========================================================

create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, name)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'name', ''));
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- =========================================================
-- Client RPCs
-- =========================================================

create function public.join_partner(code text) returns void
language plpgsql security definer set search_path = '' as $$
declare other uuid;
begin
  if (select partner_id from public.profiles where id = auth.uid()) is not null then
    raise exception 'Sei già collegato a qualcuno';
  end if;
  select id into other from public.profiles
   where invite_code = upper(trim(code)) and id <> auth.uid() and partner_id is null
   for update;
  if other is null then
    raise exception 'Codice non valido';
  end if;
  update public.profiles set partner_id = other      where id = auth.uid();
  update public.profiles set partner_id = auth.uid() where id = other;
end $$;

create function public.mark_done(task_id bigint) returns void
language plpgsql security definer set search_path = '' as $$
begin
  update public.tasks
     set status = 'done', done_at = now(), last_reminder_at = null
   where id = task_id and recipient_id = auth.uid() and status = 'active';
  if not found then raise exception 'Operazione non valida'; end if;
end $$;

create function public.confirm_done(task_id bigint) returns void
language plpgsql security definer set search_path = '' as $$
begin
  update public.tasks
     set status = 'completed', completed_at = now()
   where id = task_id and author_id = auth.uid() and status = 'done';
  if not found then raise exception 'Operazione non valida'; end if;
end $$;

create function public.save_subscription(p_endpoint text, p_p256dh text, p_auth text) returns void
language sql security definer set search_path = '' as $$
  insert into public.push_subscriptions (endpoint, user_id, p256dh, auth)
  values (p_endpoint, auth.uid(), p_p256dh, p_auth)
  on conflict (endpoint) do update
    set user_id = excluded.user_id, p256dh = excluded.p256dh, auth = excluded.auth;
$$;

-- =========================================================
-- Server job (GitHub Actions, service key), called every hour:
--  1) weekly draw, once per week, at the first run after Monday 06:00 Rome
--  2) returns the reminders to send (none between 23:00 and 08:00 Rome)
-- =========================================================

create function public.hourly_run()
returns table (user_id uuid, title text, body text)
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_column
declare
  rome      timestamp := now() at time zone 'Europe/Rome';
  this_week date      := date_trunc('week', now() at time zone 'Europe/Rome')::date;
begin
  if rome >= this_week + time '06:00' then
    insert into public.draw_log (week) values (this_week) on conflict do nothing;
    if found then
      -- Not completed: keep it and double the punishment.
      update public.tasks set doublings = doublings + 1 where status in ('active', 'done');
      -- Everyone without an open task gets a random one from the pool written by the partner.
      update public.tasks t
         set status = 'active', drawn_at = now(), last_reminder_at = null
        from (
          select distinct on (p.recipient_id) p.id
            from public.tasks p
           where p.status = 'pool'
             and not exists (select 1 from public.tasks o
                              where o.recipient_id = p.recipient_id and o.status in ('active', 'done'))
           order by p.recipient_id, random()
        ) pick
       where t.id = pick.id;
    end if;
  end if;

  if extract(hour from rome) between 8 and 22 then
    return query
    with due as (
      update public.tasks t
         set last_reminder_at = now()
        from public.profiles p
       where t.status in ('active', 'done')
         and p.id = case when t.status = 'active' then t.recipient_id else t.author_id end
         and (t.last_reminder_at is null
              or t.last_reminder_at <= now() - make_interval(hours => p.reminder_hours) + interval '10 minutes')
      returning p.id as uid, t.status as st, t.text as txt, t.doublings as dbl
    )
    select uid,
           case when st = 'active' then 'Il tuo task della settimana' else 'Task da confermare' end,
           case when st = 'active'
                then txt || case when dbl > 0 then ' (punizione x' || round(power(2::numeric, dbl))::text || ')' else '' end
                else 'Il tuo partner dice di aver fatto: ' || txt end
      from due;
  end if;
end $$;

-- =========================================================
-- Function permissions
-- =========================================================

revoke execute on function public.my_partner(), public.join_partner(text), public.mark_done(bigint),
  public.confirm_done(bigint), public.save_subscription(text, text, text), public.hourly_run(),
  public.handle_new_user()
  from public, anon, authenticated;

grant execute on function public.my_partner(), public.join_partner(text), public.mark_done(bigint),
  public.confirm_done(bigint), public.save_subscription(text, text, text)
  to authenticated;

grant execute on function public.hourly_run() to service_role;
