# Setup

About twenty minutes, once.

---

## 1. Create the Supabase project

1. Go to [supabase.com/dashboard](https://supabase.com/dashboard) → **New project**.
2. Name it `golden-jubilee`. Choose the region closest to most contributors
   (`eu-west-1` or `eu-central-1` are the sensible picks for Zimbabwe and the UK).
3. Save the database password somewhere safe — you will not be shown it again.

Use a **dedicated project**. This archive should outlive and stay independent of anything else.

---

## 2. Run the database migration

1. Dashboard → **SQL Editor** → **New query**.
2. Paste the whole of `supabase/migration.sql`.
3. **Run**.

It creates the tables, the security policies, the triggers, the realtime publication and the four
storage buckets. It is safe to run again if you edit it later.

---

## 3. Turn off public sign-ups

Dashboard → **Authentication → Sign In / Providers → Email**.

- **Disable** "Allow new users to sign up".

Only you should be creating accounts. This is the difference between a private family archive and
a public one.

---

## 4. Create your administrator account

1. Dashboard → **Authentication → Users → Add user → Create new user**.
2. Enter your email and a strong password. Tick **Auto Confirm User**.
3. Back in **SQL Editor**, add that email to the allowlist:

```sql
insert into jubilee_admins (email, full_name)
values ('you@example.com', 'Your Name')
on conflict (email) do nothing;
```

Being an auth user is **not** enough — the email must also be in `jubilee_admins`. Repeat both
steps for anyone else in the family who will moderate stories.

---

## 5. Point the site at your project

Dashboard → **Settings → API**. Copy the **Project URL** and the **anon public** key into
`assets/supabase-config.js`:

```js
const SUPABASE_URL      = 'https://xxxxxxxx.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGci...';
const SUBMIT_URL        = 'https://your-address/share.html';
```

`SUBMIT_URL` is what the QR code on the event screen points to — set it once you know the final
web address.

The anon key belongs in the browser and is safe to commit. **Never** put the `service_role` key in
this repository; it bypasses every security policy in the migration.

---

## 6. Artwork (already in place)

| File | Where it appears |
|---|---|
| `assets/hero-portrait.jpg` | The painted portrait, beside the headline on the landing page |
| `assets/event-logo.png` | Event wall opening slide, page footer, browser tab icon |
| `assets/invitation.jpg` | The invitation card in the "You are cordially invited" section |
| `assets/couple-photo.jpg` | Full-width photo band behind the closing call to action |

Untouched full-resolution copies are kept in `assets/originals/` — the versions above were resized
and compressed for the web so the site loads quickly on a phone in Bulawayo.

To swap any of them, save a new file over the same name. If the hero portrait is ever missing the
page simply drops the picture and the text fills the width, so nothing breaks.

---

## 7. Try it locally

```bash
cd ~/Documents/shadreckandbarbaraJubilee
python3 -m http.server 8080
```

Then open <http://localhost:8080>.

Use a local server rather than opening the files directly — `file://` blocks the browser APIs the
photo upload relies on.

**Check these five things:**

1. Submit a test story at `/share.html`, with a photo. It should thank you.
2. It should **not** appear on the landing page.
3. Sign in at `/admin.html`. It should be sitting in **Pending**, with the email and phone visible.
4. Approve it. It should appear on the landing page **without a refresh**.
5. Open `/wall.html` in a second window, approve another story, and watch it join the rotation
   without cutting off the one on screen.

Then delete the test stories from the admin console.

---

## 7. Publish it

The site is plain static files — any host works.

**GitHub Pages** (nothing else to install):

```bash
cd ~/Documents/shadreckandbarbaraJubilee
git add -A
git commit -m "Golden Jubilee stories archive"
gh repo create shadreckandbarbaraJubilee --private --source=. --push
```

Then on GitHub: **Settings → Pages → Source: Deploy from a branch → `master` / root**.

The site appears at `https://<your-username>.github.io/shadreckandbarbaraJubilee/`.

Set `SUBMIT_URL` in `assets/supabase-config.js` to that address (plus `/share.html`), commit, and
push again so the QR code is correct.

> Note: a **private** repo needs a paid GitHub plan for Pages to serve it. On the free plan, either
> make the repo public — the anon key and RLS are designed for exactly that — or host the files on
> Netlify or Cloudflare Pages instead, both of which serve private repos free.

---

## 8. Before the celebration

- Set the rotation speed and QR frequency in **admin → Event screen**.
- Print a few QR cards for the tables, pointing at `SUBMIT_URL`.
- Load `wall.html` on the display machine **early** and leave it open — it caches the fonts and the
  QR library, so a wifi wobble on the night will not blank the screen.
- Run **Backup & export → Export full story archive** and keep the ZIP somewhere off this machine.
- Print the book from `book.html` a few days ahead, so late stories can still be added on the
  screen even after the book has gone to print.

---

## Troubleshooting

**"That account is signed in but is not on the family administrator list."**
The email is in Supabase Auth but not in `jubilee_admins`. Run the insert in step 4. Match the
email exactly (the check is case-insensitive, but whitespace matters).

**A submission fails with "This story has already been received."**
The duplicate guard: identical text within 24 hours. Expected when you test twice with the same
words — change a word.

**A submission fails with "we already have your stories."**
The rate limit: three submissions per email address per hour. It lifts by itself.

**Photos upload but do not show.**
Check the buckets exist in Dashboard → Storage and that `story-cropped` is marked **public**.
Re-running the migration fixes this.

**Approved stories do not appear live.**
Realtime needs the publication. Re-run section 8 of the migration, and confirm under
Dashboard → **Database → Publications → supabase_realtime** that `stories` is ticked.
