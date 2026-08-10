-- ============================================================
-- New-submission email notification
-- A story landing in `pending` emails the family so it can be approved.
-- Sent straight from Postgres via pg_net → Resend. No server involved.
-- The API key lives in Supabase Vault, never in the repo.
-- ============================================================

create extension if not exists pg_net with schema extensions;

create or replace function notify_new_story()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  api_key text;
  to_addr text := 'willcrabs@gmail.com';
  body    text;
begin
  -- Only announce genuinely new, unapproved submissions.
  if new.status <> 'pending' then
    return null;
  end if;

  select decrypted_secret into api_key
    from vault.decrypted_secrets where name = 'resend_api_key' limit 1;

  -- No key configured yet: stay silent rather than fail the submission.
  if api_key is null or btrim(api_key) = '' then
    return null;
  end if;

  body :=
    '<div style="font-family:Georgia,serif;max-width:600px;margin:0 auto;color:#241f19">'
    || '<p style="letter-spacing:.2em;text-transform:uppercase;font-size:11px;color:#8a6427">'
    || 'Golden Jubilee &middot; new story</p>'
    || '<h2 style="font-size:24px;margin:.2em 0">' || coalesce(new.full_name,'Someone') || '</h2>'
    || '<p style="color:#5b5248;margin:0 0 18px">'
    || coalesce(new.relationship,'') || coalesce(' &middot; ' || new.location, '') || '</p>'
    || case when new.love_is_quote is not null
            then '<p style="font-style:italic;color:#8a6427">&ldquo;Love is '
                 || new.love_is_quote || '&rdquo;</p>' else '' end
    || '<blockquote style="border-left:3px solid #b8893b;margin:0;padding:4px 0 4px 16px;font-size:17px;line-height:1.6">'
    || replace(coalesce(new.original_message,''), E'\n', '<br>')
    || '</blockquote>'
    || '<p style="margin:28px 0"><a href="https://rent2go-app.github.io/shadreckandbarbaraJubilee/admin.html" '
    || 'style="background:#b8893b;color:#fff;padding:12px 26px;border-radius:999px;'
    || 'text-decoration:none;font-family:Helvetica,Arial,sans-serif;font-size:14px">'
    || 'Review and approve</a></p>'
    || '<p style="font-size:12px;color:#8b8069">Nothing appears publicly until a family '
    || 'administrator approves it.</p></div>';

  perform net.http_post(
    url     := 'https://api.resend.com/emails',
    headers := jsonb_build_object(
                 'Content-Type',  'application/json',
                 'Authorization', 'Bearer ' || api_key),
    body    := jsonb_build_object(
                 'from',    'Jubilee Stories <onboarding@resend.dev>',
                 'to',      jsonb_build_array(to_addr),
                 'subject', 'New Jubilee story from ' || coalesce(new.full_name,'a guest'),
                 'html',    body)
  );

  return null;
end;
$fn$;

drop trigger if exists notify_new_story_trg on stories;
create trigger notify_new_story_trg
  after insert on stories
  for each row execute function notify_new_story();
