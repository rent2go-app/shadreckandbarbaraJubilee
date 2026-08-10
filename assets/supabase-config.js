/* Shadreck & Barbara — Golden Jubilee
 * Supabase client configuration.
 *
 * Project: BarbaraandshadreckGoldenJubilee
 *   Dashboard → Settings → Data API   → Project URL
 *   Dashboard → Settings → API Keys   → publishable key
 *
 * The publishable key is safe to publish — it is designed to sit in the
 * browser. Row Level Security and the column grants in
 * supabase/migration.sql are what protect the data.
 * NEVER put a secret key (sb_secret_… / service_role) in this file.
 */
const SUPABASE_URL      = 'https://ogumciqvnxhicqphplxe.supabase.co';
const SUPABASE_ANON_KEY = 'sb_publishable_jv7aCV80vbBt0Q8bVjKulw_-ljxqJIf';

/* The public address contributors are sent to. This is what the QR code on
 * the event screen encodes, so it must be the LIVE address before the day.
 * Change it here only — nothing else needs touching. */
const SUBMIT_URL = 'https://rent2go-app.github.io/shadreckandbarbaraJubilee/share.html';

const db = supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
