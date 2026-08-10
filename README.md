# Shadreck & Barbara — Golden Jubilee

The **Stories of Love** archive: a permanent, searchable database of the testimonies, memories and
blessings collected for Shadreck and Barbara's 50th wedding anniversary.

One canonical record per story. The website, the event screen and the printed book all read that
same record — no copies, no duplicates, no folder of loose images.

## The pages

| Page | Who it's for | What it does |
|---|---|---|
| `index.html` | Everyone | Landing page. Live tray of the most recent approved stories. |
| `share.html` | Contributors | The submission form. Photo upload, story, "Love is…" line, consent. |
| `stories.html` | Everyone | Full gallery with search and filters. |
| `wall.html` | The celebration | Full-screen rotating testimony wall. Configured live from the admin page. |
| `admin.html` | Family only | Moderation, editing, display toggles, event-screen settings, exports. |
| `book.html` | Family only | Print-ready A4 book. Print to PDF from the browser. |

## Architecture

```
CONTRIBUTOR SUBMISSION  (share.html)
        |
        v
   stories  ── the one canonical record ──┐
        |                                  |
        ├── photographs ──> Supabase Storage
        |                     story-originals  (private)
        |                     story-cropped    (public)
        |                     story-generated  (public)
        |                     story-print      (private)
        |
        ├── generated_assets  ── cards & pages rendered FROM the story
        |
        ├── landing page tray      (index.html,   realtime)
        ├── full story gallery     (stories.html, realtime)
        ├── event testimony wall   (wall.html,    realtime)
        └── print book export      (book.html)
```

Everything is static HTML and browser JavaScript talking to Supabase. No build step, no server,
no framework. Open the files, or serve the folder — either works.

## How a story travels

1. Someone submits at `share.html`. The row is created as **`pending`**. Column-level grants make
   it impossible for a submission to arrive already approved.
2. A family administrator reads it at `admin.html`, optionally tidies the wording, and approves.
3. The moment it is approved, Supabase Realtime pushes it to every open landing page and event
   screen. The screen **does not interrupt** the testimony currently showing — the new story joins
   the rotation queue.
4. It is included in `book.html` unless *Printed book* is unticked.

## What the contributor's original words are protected from

`original_message` is the contributor's text, verbatim. A database trigger silently rejects any
attempt to change it — including from an administrator. Edits go into `edited_message`, and the
public sees `edited_message` when it exists, otherwise `original_message`. The original is always
recoverable, and it is what goes into `story.txt` in the archive export.

## Privacy

Email addresses, phone numbers, admin notes, pending submissions and the original uploads are
never readable by the public. This is enforced twice:

- **Row Level Security** — the public read policy only matches approved, published rows.
- **Column-level grants** — `anon` has no `SELECT` privilege on `email`, `phone`, `admin_notes`,
  `original_photo_url`, `status`, `approved_at` or `approved_by`. Even a hand-written API request
  asking for those columns is refused by Postgres.

The `story-originals` and `story-print` buckets are private. Administrators reach the originals
through short-lived signed URLs.

## Backup

`admin.html` → **Backup & export** produces:

- **CSV** — every field, every story, including private ones.
- **Full story archive (ZIP)** — the CSV plus one folder per story containing `story.txt` (original
  and edited words side by side), the original photograph as uploaded, the portrait crop, and any
  generated cards.

Download the full archive before the celebration and again afterwards. The memories should not
depend on this website, or on Supabase, staying online.

## Running the event screen

Open `wall.html` on the display machine and press **F** for fullscreen.

| Key | Action |
|---|---|
| `F` | Fullscreen |
| `Space` | Pause / resume |
| `→` | Next story |
| `←` | Previous story |

Rotation speed, the QR slide, shuffling and what appears under each story are all read from the
`display_settings` table — change them in **admin → Event screen** and every connected display
updates within a second. No redeploy, no restart.

The screen re-reads the story list every two minutes as a safety net for unreliable venue wifi.

## Setup

See [SETUP.md](SETUP.md).
