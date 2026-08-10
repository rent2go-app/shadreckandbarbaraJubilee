-- ============================================================
-- Shadreck & Barbara — Golden Jubilee
-- "Stories of Love" permanent testimony archive
--
-- Run this ONCE, top to bottom, in the SQL editor of the
-- DEDICATED Jubilee Supabase project (Dashboard → SQL Editor).
-- It is idempotent: safe to re-run after edits.
--
-- Contents
--   1. Admin identity + is_jubilee_admin()
--   2. stories            — the canonical record (one row per testimony)
--   3. generated_assets   — cards/pages rendered FROM a story
--   4. display_settings   — event-wall config, editable without redeploy
--   5. Privilege grants   — column-level: anon can never read contact info
--   6. Row Level Security — public submit / public read approved / admin all
--   7. Spam + integrity triggers
--   8. Realtime publication
--   9. Storage buckets + storage policies
-- ============================================================

create extension if not exists pgcrypto;


-- ============================================================
-- 1. ADMIN IDENTITY
-- Admins are Supabase Auth users whose email is in this allowlist.
-- Creating an auth user is NOT enough — the email must be listed here.
-- ============================================================

create table if not exists jubilee_admins (
  email      text primary key,
  full_name  text,
  created_at timestamptz not null default now()
);

alter table jubilee_admins enable row level security;

-- SECURITY DEFINER so it can read the allowlist without RLS recursion.
create or replace function is_jubilee_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from jubilee_admins a
    where lower(a.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  );
$$;

revoke all on function is_jubilee_admin() from public;
grant execute on function is_jubilee_admin() to anon, authenticated;

drop policy if exists "Admins read the admin list" on jubilee_admins;
create policy "Admins read the admin list"
  on jubilee_admins for select to authenticated
  using (is_jubilee_admin());


-- ============================================================
-- 2. STORIES — the one canonical record per testimony
-- The website, the event wall and the printed book all read THIS row.
-- No copies are ever made.
-- ============================================================

create table if not exists stories (
  id           uuid primary key default gen_random_uuid(),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  submitted_at timestamptz not null default now(),

  -- who is speaking
  full_name          text not null,
  relationship       text,          -- child | grandchild | sibling | friend | church | colleague | other
  relationship_other text,
  location           text,

  -- private contact details (NEVER exposed to anon — see section 5)
  email text,
  phone text,

  -- the testimony
  story_type       text not null default 'testimony',  -- testimony | memory | blessing | advice | tribute
  original_message text not null,                      -- contributor's words, never overwritten
  edited_message   text,                               -- admin's tidy-up, optional
  love_is_quote    text,                               -- "Love is ..."

  -- what the public actually sees: the edit if there is one, else the original
  public_message text generated always as (
    coalesce(nullif(btrim(edited_message), ''), original_message)
  ) stored,

  -- media (paths/URLs only — binaries live in Storage)
  original_photo_url  text,
  cropped_photo_url   text,
  thumbnail_photo_url text,

  -- moderation workflow
  status          text    not null default 'pending',
  approved        boolean not null default false,
  include_in_book boolean not null default true,
  show_on_landing_page boolean not null default true,
  show_on_event_wall   boolean not null default true,
  featured        boolean not null default false,
  display_order   int,

  -- governance
  consent     boolean not null default false,
  admin_notes text,
  approved_at timestamptz,
  approved_by text,

  constraint stories_status_chk  check (status in ('pending','approved','hold','rejected','archived')),
  constraint stories_consent_chk check (consent = true),
  constraint stories_type_chk    check (story_type in ('testimony','memory','blessing','advice','tribute')),
  constraint stories_name_len    check (char_length(btrim(full_name)) between 2 and 120),
  constraint stories_msg_len     check (char_length(btrim(original_message)) between 20 and 4000),
  constraint stories_quote_len   check (love_is_quote is null or char_length(love_is_quote) <= 200)
);

alter table stories enable row level security;

create index if not exists stories_status_idx   on stories (status, created_at desc);
create index if not exists stories_public_idx   on stories (approved, show_on_landing_page, display_order, created_at desc);
create index if not exists stories_wall_idx     on stories (approved, show_on_event_wall, display_order);
create index if not exists stories_book_idx     on stories (include_in_book, display_order) where approved;
create index if not exists stories_email_idx    on stories (lower(email), created_at desc);
create index if not exists stories_search_idx   on stories
  using gin (to_tsvector('english', coalesce(full_name,'') || ' ' || coalesce(original_message,'') || ' ' || coalesce(love_is_quote,'')));


-- ============================================================
-- 3. GENERATED ASSETS
-- Cards and print pages rendered from a story. Regenerating a card
-- never touches the story record.
-- ============================================================

create table if not exists generated_assets (
  id           uuid primary key default gen_random_uuid(),
  story_id     uuid not null references stories(id) on delete cascade,
  asset_type   text not null,
  file_url     text,
  file_path    text,
  width        int,
  height       int,
  format       text,
  generated_at timestamptz not null default now(),

  constraint generated_assets_type_chk
    check (asset_type in ('book_page','square_card','event_card','thumbnail','printable_pdf'))
);

alter table generated_assets enable row level security;

create index if not exists generated_assets_story_idx on generated_assets (story_id, asset_type);


-- ============================================================
-- 4. DISPLAY SETTINGS — one row, id = 1
-- The event wall reads its configuration from here, so staff can
-- retime the rotation on the night without a redeploy.
-- ============================================================

create table if not exists display_settings (
  id                int primary key default 1,
  rotation_seconds  int     not null default 14,
  transition_style  text    not null default 'fade',   -- fade | slide | none
  show_location     boolean not null default true,
  show_relationship boolean not null default true,
  show_love_quote   boolean not null default true,
  randomize_stories boolean not null default false,
  qr_frequency      int     not null default 6,        -- QR slide after every N stories
  enable_qr_slide   boolean not null default true,
  event_mode        boolean not null default false,
  headline          text    not null default 'Shadreck & Barbara — Fifty Years of Love',
  updated_at        timestamptz not null default now(),

  constraint display_settings_singleton check (id = 1),
  constraint display_settings_rotation  check (rotation_seconds between 4 and 120),
  constraint display_settings_qr        check (qr_frequency between 1 and 50)
);

alter table display_settings enable row level security;

insert into display_settings (id) values (1) on conflict (id) do nothing;


-- ============================================================
-- 5. PRIVILEGE GRANTS (column-level)
-- This is the hard wall around private data. Even if an RLS policy
-- were mis-written, `anon` has no SELECT privilege on email, phone,
-- admin_notes, original_photo_url or the approval audit columns, so
-- PostgREST rejects any attempt to request them.
-- ============================================================

revoke all on stories          from anon, authenticated;
revoke all on generated_assets from anon, authenticated;
revoke all on display_settings from anon, authenticated;
revoke all on jubilee_admins   from anon, authenticated;

-- Public may read only these columns, and only on rows RLS allows.
grant select (
  id, created_at,
  full_name, relationship, relationship_other, location,
  story_type, original_message, edited_message, public_message, love_is_quote,
  cropped_photo_url, thumbnail_photo_url,
  approved, show_on_landing_page, show_on_event_wall, featured, display_order
) on stories to anon;

-- Public may write only these columns. status / approved / admin_notes
-- are not grantable to anon at all, so a forged payload cannot set them.
grant insert (
  full_name, relationship, relationship_other, location,
  email, phone,
  story_type, original_message, love_is_quote,
  original_photo_url, cropped_photo_url, thumbnail_photo_url,
  consent
) on stories to anon;

grant select (id, story_id, asset_type, file_url, file_path, width, height, format, generated_at)
  on generated_assets to anon;

grant select (id, rotation_seconds, transition_style, show_location, show_relationship,
              show_love_quote, randomize_stories, qr_frequency, enable_qr_slide,
              event_mode, headline, updated_at)
  on display_settings to anon;

-- Signed-in users get full table privileges, but RLS below still limits
-- them to the same public view unless they are on the admin allowlist.
grant select, insert, update, delete on stories          to authenticated;
grant select, insert, update, delete on generated_assets to authenticated;
grant select, update                on display_settings  to authenticated;
grant select                        on jubilee_admins    to authenticated;


-- ============================================================
-- 6. ROW LEVEL SECURITY
-- ============================================================

-- --- stories -------------------------------------------------

-- Anyone may submit. The WITH CHECK pins the row to the pending lane.
drop policy if exists "Anyone may submit a story" on stories;
create policy "Anyone may submit a story"
  on stories for insert to anon, authenticated
  with check (
    status = 'pending'
    and approved = false
    and consent = true
    and featured = false
    and approved_at is null
    and approved_by is null
    and admin_notes is null
  );

-- Public read: approved, and flagged for at least one public surface.
drop policy if exists "Public reads approved stories" on stories;
create policy "Public reads approved stories"
  on stories for select to anon, authenticated
  using (
    approved = true
    and status = 'approved'
    and (show_on_landing_page or show_on_event_wall)
  );

-- Admins see and manage everything, including pending and rejected.
drop policy if exists "Admins read every story" on stories;
create policy "Admins read every story"
  on stories for select to authenticated using (is_jubilee_admin());

drop policy if exists "Admins update stories" on stories;
create policy "Admins update stories"
  on stories for update to authenticated
  using (is_jubilee_admin()) with check (is_jubilee_admin());

drop policy if exists "Admins delete stories" on stories;
create policy "Admins delete stories"
  on stories for delete to authenticated using (is_jubilee_admin());

-- --- generated_assets ----------------------------------------

drop policy if exists "Public reads assets of approved stories" on generated_assets;
create policy "Public reads assets of approved stories"
  on generated_assets for select to anon, authenticated
  using (exists (
    select 1 from stories s
    where s.id = generated_assets.story_id
      and s.approved = true
      and s.status = 'approved'
  ));

drop policy if exists "Admins manage assets" on generated_assets;
create policy "Admins manage assets"
  on generated_assets for all to authenticated
  using (is_jubilee_admin()) with check (is_jubilee_admin());

-- --- display_settings ----------------------------------------

drop policy if exists "Anyone reads display settings" on display_settings;
create policy "Anyone reads display settings"
  on display_settings for select to anon, authenticated using (true);

drop policy if exists "Admins update display settings" on display_settings;
create policy "Admins update display settings"
  on display_settings for update to authenticated
  using (is_jubilee_admin()) with check (is_jubilee_admin());


-- ============================================================
-- 7. TRIGGERS — integrity, audit and spam control
-- ============================================================

-- 7a. Keep updated_at honest.
create or replace function touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists stories_touch_updated_at on stories;
create trigger stories_touch_updated_at
  before update on stories
  for each row execute function touch_updated_at();

-- 7b. Keep `status` and `approved` in lockstep, and stamp the approver.
--     Also protects original_message from ever being overwritten.
create or replace function stories_moderation_guard()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  -- The contributor's own words are immutable, forever.
  if tg_op = 'UPDATE' and new.original_message is distinct from old.original_message then
    new.original_message := old.original_message;
  end if;

  if new.status = 'approved' then
    new.approved := true;
    if tg_op = 'INSERT' or old.status is distinct from 'approved' then
      new.approved_at := now();
      new.approved_by := coalesce(auth.jwt() ->> 'email', new.approved_by);
    end if;
  else
    new.approved    := false;
    new.approved_at := null;
  end if;

  return new;
end;
$$;

drop trigger if exists stories_moderation_guard_trg on stories;
create trigger stories_moderation_guard_trg
  before insert or update on stories
  for each row execute function stories_moderation_guard();

-- 7c. Practical spam control at the database edge.
--     Max 3 submissions per email per hour; identical text blocked for 24h.
create or replace function stories_rate_limit()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  recent int;
begin
  if is_jubilee_admin() then
    return new;   -- admins may enter stories taken over the phone
  end if;

  if new.email is not null and btrim(new.email) <> '' then
    select count(*) into recent
      from stories
     where lower(email) = lower(new.email)
       and created_at > now() - interval '1 hour';

    if recent >= 3 then
      raise exception 'Thank you — we already have your stories. Please contact the family to add more.'
        using errcode = 'check_violation';
    end if;
  end if;

  if exists (
    select 1 from stories
     where original_message = new.original_message
       and created_at > now() - interval '24 hours'
  ) then
    raise exception 'This story has already been received. Thank you.'
      using errcode = 'check_violation';
  end if;

  return new;
end;
$$;

drop trigger if exists stories_rate_limit_trg on stories;
create trigger stories_rate_limit_trg
  before insert on stories
  for each row execute function stories_rate_limit();

-- 7d. display_settings.updated_at
drop trigger if exists display_settings_touch on display_settings;
create trigger display_settings_touch
  before update on display_settings
  for each row execute function touch_updated_at();


-- ============================================================
-- 8. REALTIME
-- Approving a story pushes it straight to the landing page and the
-- event wall.
--
-- IMPORTANT: `stories` is deliberately NOT published to realtime.
-- Realtime honours RLS policies but NOT column-level grants, so
-- publishing `stories` would broadcast whole rows — email addresses,
-- phone numbers, admin notes — to every connected browser.
--
-- Instead we publish a contentless signal table. A browser is told
-- only *that* something changed; it then re-reads through the
-- column-restricted grants in section 5. No private field is ever
-- pushed over the wire.
-- ============================================================

create table if not exists story_pings (
  id         bigserial primary key,
  story_id   uuid,
  created_at timestamptz not null default now()
);

alter table story_pings enable row level security;

revoke all on story_pings from anon, authenticated;
grant select (id, story_id, created_at) on story_pings to anon, authenticated;

drop policy if exists "Anyone may listen for changes" on story_pings;
create policy "Anyone may listen for changes"
  on story_pings for select to anon, authenticated using (true);

-- SECURITY DEFINER so a contributor's insert can raise a ping without
-- holding any privilege on this table.
create or replace function stories_ping()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  -- Signal on every new submission (so the admin console shows it arriving)
  -- and on any change either side of which was publicly visible.
  if tg_op = 'INSERT'
     or (tg_op = 'UPDATE' and (new.approved or old.approved))
     or (tg_op = 'DELETE' and old.approved) then
    insert into story_pings (story_id) values (coalesce(new.id, old.id));
    -- keep the signal table from growing without bound
    delete from story_pings where created_at < now() - interval '2 days';
  end if;
  return null;
end;
$$;

drop trigger if exists stories_ping_trg on stories;
create trigger stories_ping_trg
  after insert or update or delete on stories
  for each row execute function stories_ping();

do $$
begin
  begin execute 'alter publication supabase_realtime add table story_pings';      exception when duplicate_object then null; end;
  begin execute 'alter publication supabase_realtime add table display_settings'; exception when duplicate_object then null; end;
  -- Belt and braces: make sure a previous run has not left `stories` published.
  begin execute 'alter publication supabase_realtime drop table stories';         exception when others then null; end;
end $$;


-- ============================================================
-- 9. STORAGE
-- Binaries never go in Postgres. The story row holds the path.
--   story-originals : private — the untouched upload, admin-only
--   story-cropped   : public  — portrait crops for cards and screens
--   story-generated : public  — rendered digital cards
--   story-print     : private — print-ready pages and PDFs
-- ============================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values
  ('story-originals', 'story-originals', false, 15728640, array['image/jpeg','image/png','image/webp','image/heic','image/heif']),
  ('story-cropped',   'story-cropped',   true,   5242880, array['image/jpeg','image/webp']),
  ('story-generated', 'story-generated', true,   8388608, array['image/png','image/jpeg','image/webp']),
  ('story-print',     'story-print',     false, 104857600, array['application/pdf','image/png','image/jpeg'])
on conflict (id) do update
  set public             = excluded.public,
      file_size_limit    = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- Contributors may upload, but never list or read the originals bucket.
drop policy if exists "Public may upload story photos" on storage.objects;
create policy "Public may upload story photos"
  on storage.objects for insert to anon, authenticated
  with check (bucket_id in ('story-originals','story-cropped'));

-- Public buckets serve their files over public URLs; this covers API reads.
drop policy if exists "Public reads public story media" on storage.objects;
create policy "Public reads public story media"
  on storage.objects for select to anon, authenticated
  using (bucket_id in ('story-cropped','story-generated'));

drop policy if exists "Admins manage all story media" on storage.objects;
create policy "Admins manage all story media"
  on storage.objects for all to authenticated
  using (bucket_id in ('story-originals','story-cropped','story-generated','story-print') and is_jubilee_admin())
  with check (bucket_id in ('story-originals','story-cropped','story-generated','story-print') and is_jubilee_admin());


-- ============================================================
-- 10. FINAL STEP — add yourself as an administrator
-- Replace the address below with the email you will sign in with,
-- then create that user in Dashboard → Authentication → Users.
-- ============================================================

-- insert into jubilee_admins (email, full_name)
-- values ('you@example.com', 'Your Name')
-- on conflict (email) do nothing;
