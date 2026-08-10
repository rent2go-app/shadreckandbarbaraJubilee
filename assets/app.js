/* Shadreck & Barbara — Golden Jubilee
 * Shared helpers: public reads, realtime, image processing, card rendering.
 * Loaded by every page after supabase-config.js.
 */

/* The exact columns `anon` is granted. Asking for anything else — email,
   phone, admin_notes — is rejected by Postgres, not by this file. */
const PUBLIC_COLS =
  'id,created_at,full_name,relationship,relationship_other,location,story_type,' +
  'public_message,love_is_quote,cropped_photo_url,thumbnail_photo_url,' +
  'featured,display_order,show_on_landing_page,show_on_event_wall';

const RELATIONSHIPS = {
  child:      'Their child',
  grandchild: 'Their grandchild',
  sibling:    'Their brother or sister',
  family:     'Family',
  friend:     'A friend',
  church:     'Church family',
  colleague:  'A colleague',
  other:      ''
};

const STORY_TYPES = {
  testimony: 'Testimony',
  memory:    'A memory',
  blessing:  'A blessing',
  advice:    'What they taught me',
  tribute:   'Tribute'
};

/* ---------- configuration state ---------- */

/* True once supabase-config.js holds a real project URL and anon key.
   Until then every read returns empty and every write fails — so say so
   plainly rather than blaming the visitor's internet. */
const JUBILEE_CONFIGURED = !/YOUR-PROJECT-REF|YOUR-ANON-PUBLIC-KEY/.test(
  String(SUPABASE_URL) + String(SUPABASE_ANON_KEY)
);

if (!JUBILEE_CONFIGURED){
  console.warn(
    '[jubilee] Supabase is not configured yet. Fill SUPABASE_URL and ' +
    'SUPABASE_ANON_KEY in assets/supabase-config.js — see SETUP.md steps 1–5.'
  );
}

/* ---------- tiny utilities ---------- */

const esc = s => String(s ?? '').replace(/[&<>"']/g, c =>
  ({ '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;' }[c]));

const initials = name => String(name || '?').trim().split(/\s+/)
  .slice(0, 2).map(w => w[0]).join('').toUpperCase();

/* Contributors now describe the relationship in their own words, so the
   stored value is free text. Older rows used fixed keys — map those, and
   otherwise show exactly what the person wrote. */
function relationshipLabel(s){
  if (s.relationship === 'other') return s.relationship_other || '';
  return RELATIONSHIPS[s.relationship] || s.relationship || '';
}

/* Byline under a story: "Their grandchild · Bulawayo" */
function bylineMeta(s, { location = true, relationship = true } = {}){
  return [relationship ? relationshipLabel(s) : '', location ? s.location : '']
    .filter(Boolean).join(' · ');
}

/* ---------- reading ---------- */

/* A request that never answers is worse than one that fails: the event
   screen would sit blank all night waiting for it. Every read is raced
   against a deadline so the page can fall back to what it already has. */
const NETWORK_TIMEOUT_MS = 8000;

function withTimeout(promise, ms = NETWORK_TIMEOUT_MS){
  return Promise.race([
    Promise.resolve(promise),
    new Promise((_, reject) => setTimeout(() => reject(new Error('network timeout')), ms))
  ]);
}

/* surface: 'landing' | 'wall' | 'all' */
async function fetchPublicStories({ surface = 'landing', limit = 60 } = {}){
  if (!JUBILEE_CONFIGURED) return [];
  try {
    let q = db.from('stories').select(PUBLIC_COLS);
    if (surface === 'landing') q = q.eq('show_on_landing_page', true);
    if (surface === 'wall')    q = q.eq('show_on_event_wall', true);

    const { data, error } = await withTimeout(q
      .order('featured',      { ascending: false })
      .order('display_order', { ascending: true, nullsFirst: false })
      .order('created_at',    { ascending: false })
      .limit(limit));

    if (error){ console.error('[jubilee] fetch stories', error); return []; }
    return data || [];
  } catch (err){
    /* Offline, or the project URL is not filled in yet. Fail quietly —
       the page shows its empty state rather than hanging on "Loading". */
    console.error('[jubilee] fetch stories', err);
    return [];
  }
}

async function fetchDisplaySettings(){
  let data = null;
  try {
    if (JUBILEE_CONFIGURED)
      ({ data } = await withTimeout(db.from('display_settings').select('*').eq('id', 1).single()));
  } catch (err){ console.error('[jubilee] display settings', err); }
  return data || {
    rotation_seconds: 14, transition_style: 'fade', show_location: true,
    show_relationship: true, show_love_quote: true, randomize_stories: false,
    qr_frequency: 6, enable_qr_slide: true, event_mode: false,
    headline: 'Shadreck & Barbara — Fifty Years of Love'
  };
}

/* Live updates.
   We listen on `story_pings`, not on `stories`. Realtime honours RLS but
   NOT column-level grants, so publishing `stories` would broadcast whole
   rows — including email addresses and phone numbers — to every browser
   on the page. A ping carries no content: it only says "something
   published changed", and the page then re-reads through the restricted
   column grants above. */
function subscribeStories(onChange){
  if (!JUBILEE_CONFIGURED) return null;
  return db.channel('story-pings')
    .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'story_pings' },
        payload => onChange(payload))
    .subscribe();
}

function subscribeDisplaySettings(onChange){
  if (!JUBILEE_CONFIGURED) return null;
  return db.channel('display-settings')
    .on('postgres_changes', { event: 'UPDATE', schema: 'public', table: 'display_settings' },
        payload => onChange(payload.new))
    .subscribe();
}

/* ---------- image processing (all client-side, no server) ---------- */

const PHOTO = {
  maxBytes:  15 * 1024 * 1024,
  accepted:  ['image/jpeg','image/png','image/webp','image/heic','image/heif'],
  cropped:   { w: 1000, h: 1250 },   // 4:5 portrait for cards and screens
  thumb:     { w: 320,  h: 400  }
};

function validatePhoto(file){
  if (!file) return 'Please choose a photograph.';
  if (!PHOTO.accepted.includes(file.type)) return 'Please use a JPG, PNG, WEBP or HEIC image.';
  if (file.size > PHOTO.maxBytes) return 'That photo is larger than 15MB. Please choose a smaller one.';
  return null;
}

async function loadBitmap(file){
  if ('createImageBitmap' in window){
    try { return await createImageBitmap(file, { imageOrientation: 'from-image' }); }
    catch(_){ /* fall through for HEIC and older browsers */ }
  }
  return await new Promise((resolve, reject) => {
    const img = new Image();
    img.onload  = () => resolve(img);
    img.onerror = () => reject(new Error('unreadable'));
    img.src = URL.createObjectURL(file);
  });
}

/* Centre-crop to a fixed portrait ratio, then downscale. */
function cropToPortrait(bitmap, { w, h }){
  const sw = bitmap.width, sh = bitmap.height;
  const targetRatio = w / h;
  let cw = sw, ch = sw / targetRatio;
  if (ch > sh){ ch = sh; cw = sh * targetRatio; }
  const sx = (sw - cw) / 2, sy = (sh - ch) / 2;

  const canvas = document.createElement('canvas');
  canvas.width = w; canvas.height = h;
  const ctx = canvas.getContext('2d');
  ctx.imageSmoothingQuality = 'high';
  ctx.drawImage(bitmap, sx, sy, cw, ch, 0, 0, w, h);
  return canvas;
}

const canvasToBlob = (canvas, type = 'image/jpeg', quality = 0.86) =>
  new Promise(res => canvas.toBlob(res, type, quality));

/* Uploads the original (private bucket) plus a crop and a thumbnail
   (public buckets). Returns the three values stored on the story row.
   `original_photo_url` holds a PATH — that bucket is not public. */
async function uploadPhotoSet(file, onProgress = () => {}){
  const token = (crypto.randomUUID ? crypto.randomUUID() : String(Date.now()) + Math.random().toString(16).slice(2));
  const ext   = (file.name.split('.').pop() || 'jpg').toLowerCase().replace(/[^a-z0-9]/g, '');

  onProgress('Saving your original photograph…');
  const origPath = `${token}/original.${ext}`;
  const up1 = await db.storage.from('story-originals')
    .upload(origPath, file, { contentType: file.type, upsert: false });
  if (up1.error) throw up1.error;

  onProgress('Preparing your photograph…');
  const bitmap = await loadBitmap(file);
  const cropBlob  = await canvasToBlob(cropToPortrait(bitmap, PHOTO.cropped));
  const thumbBlob = await canvasToBlob(cropToPortrait(bitmap, PHOTO.thumb), 'image/jpeg', 0.8);

  const cropPath  = `${token}/cropped.jpg`;
  const thumbPath = `${token}/thumb.jpg`;

  const up2 = await db.storage.from('story-cropped')
    .upload(cropPath, cropBlob, { contentType: 'image/jpeg', upsert: false });
  if (up2.error) throw up2.error;

  const up3 = await db.storage.from('story-cropped')
    .upload(thumbPath, thumbBlob, { contentType: 'image/jpeg', upsert: false });
  if (up3.error) throw up3.error;

  const pub = p => db.storage.from('story-cropped').getPublicUrl(p).data.publicUrl;

  return {
    original_photo_url:  origPath,          // private bucket → path, not URL
    cropped_photo_url:   pub(cropPath),
    thumbnail_photo_url: pub(thumbPath)
  };
}

/* ---------- rendering ---------- */

function photoMarkup(s, cls = 'card-photo'){
  const src = s.cropped_photo_url || s.thumbnail_photo_url;
  return src
    ? `<img class="${cls}" src="${esc(src)}" alt="Photograph of ${esc(s.full_name)}" loading="lazy">`
    : `<div class="${cls} empty">${esc(initials(s.full_name))}</div>`;
}

function storyCard(s, opts = {}){
  const meta  = bylineMeta(s, opts);
  const quote = (opts.love_quote !== false && s.love_is_quote)
    ? `<p class="quote">“Love is ${esc(s.love_is_quote)}”</p>` : '';
  const type  = STORY_TYPES[s.story_type] || '';

  return `
    <article class="card${s.featured ? ' featured' : ''}" data-id="${esc(s.id)}">
      ${photoMarkup(s)}
      <div class="card-body">
        ${type ? `<span class="tag">${esc(type)}</span>` : ''}
        ${quote}
        <p class="msg">${esc(s.public_message)}</p>
        <div class="byline">
          <strong>${esc(s.full_name)}</strong>
          ${meta ? `<span class="small muted">${esc(meta)}</span>` : ''}
        </div>
      </div>
    </article>`;
}

/* ---------- shared navigation ----------
   One definition for every page. Put <div id="nav-mount"></div> in a page
   and call mountNav('<key>'). Keeps the links identical everywhere. */

const NAV_LINKS = [
  { key: 'home',      href: 'index.html',   label: 'Home' },
  { key: 'stories',   href: 'stories.html', label: 'Stories' },
  { key: 'slideshow', href: 'wall.html',    label: 'Slideshow', target: '_blank' },
  { key: 'admin',     href: 'admin.html',   label: 'Family login' }
];

/* Submission deadline — end of Friday 28 August 2026 (CAT). One source of
   truth for the top bar and the landing-page band. */
const DEADLINE = new Date('2026-08-28T23:59:59+02:00');
const deadlineDaysLeft = () => Math.ceil((DEADLINE - new Date()) / 86400000);

function deadlineBar(){
  const d = deadlineDaysLeft();
  const urgent = d >= 0 && d <= 7;
  const line = d > 1  ? `Share your story by <strong>Friday 28 August</strong> &nbsp;&middot;&nbsp; ${d} days left`
             : d === 1 ? `<strong>Last day</strong> to share your story &mdash; Friday 28 August`
             : d === 0 ? `<strong>Today is the last day</strong> to share your story`
             : `Stories are still welcome &mdash; they reach Gogo &amp; Khulu, but are not played on the night`;
  return `<a class="topbar${urgent ? ' urgent' : ''}${d < 0 ? ' closed' : ''}" href="share.html">
            <span>${line}</span>
          </a>`;
}

function mountNav(active = ''){
  const mount = document.getElementById('nav-mount');
  if (!mount) return;

  const links = NAV_LINKS.map(l => {
    const tgt = l.target ? ` target="${l.target}" rel="noopener"` : '';
    return `<a href="${l.href}"${tgt}${l.key === active ? ' class="active"' : ''}>${l.label}</a>`;
  }).join('');

  mount.outerHTML = `
    ${deadlineBar()}
    <nav class="nav">
      <div class="wrap">
        <a class="brand" href="index.html">Shadreck <span>&amp;</span> Barbara</a>
        <button class="nav-toggle" id="nav-toggle" aria-label="Menu" aria-expanded="false">&#9776;</button>
        <div class="nav-links" id="nav-links">
          ${links}
          <a class="btn sm" href="share.html">Share your story</a>
        </div>
      </div>
    </nav>`;

  const toggle = document.getElementById('nav-toggle');
  toggle.addEventListener('click', () => {
    const open = document.getElementById('nav-links').classList.toggle('open');
    toggle.setAttribute('aria-expanded', open ? 'true' : 'false');
  });
}

/* ---------- scroll reveal ---------- */

function initReveal(){
  const els = document.querySelectorAll('.reveal');
  if (!('IntersectionObserver' in window)){
    els.forEach(el => el.classList.add('in')); return;
  }
  const io = new IntersectionObserver(entries => {
    entries.forEach(e => { if (e.isIntersecting){ e.target.classList.add('in'); io.unobserve(e.target); } });
  }, { threshold: 0.12 });
  els.forEach(el => io.observe(el));
}

document.addEventListener('DOMContentLoaded', initReveal);
