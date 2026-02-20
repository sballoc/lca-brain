#!/usr/bin/env node

/**
 * LCA Granola Sync
 *
 * Syncs meeting notes from your Granola "Loblaw" folder
 * to the shared Google Drive folder so the whole team has context.
 *
 * Usage: node sync.js
 * Runs automatically every hour via LaunchAgent after install.
 */

const fs = require('fs');
const path = require('path');
const https = require('https');
const zlib = require('zlib');
const os = require('os');

// ── Config ──────────────────────────────────────────────────
const HOME = os.homedir();
const CREDS_PATH = path.join(HOME, 'Library/Application Support/Granola/supabase.json');
const API_HOST = 'api.granola.ai';
const REQUEST_DELAY = 200;

// The shared Google Drive folder — Google Drive for Desktop syncs this
// Each person's Google Drive mount path differs, so we detect it
function findGDrivePath() {
  const cloudStorage = path.join(HOME, 'Library/CloudStorage');
  if (!fs.existsSync(cloudStorage)) return null;

  const drives = fs.readdirSync(cloudStorage).filter(d => d.startsWith('GoogleDrive-'));
  if (drives.length === 0) return null;

  // Check each drive for the shared folder
  for (const drive of drives) {
    const candidate = path.join(cloudStorage, drive, 'My Drive', 'client context', 'loblaw digital', 'transcripts');
    if (fs.existsSync(path.dirname(candidate))) {
      // Create transcripts subfolder if needed
      if (!fs.existsSync(candidate)) fs.mkdirSync(candidate, { recursive: true });
      return candidate;
    }
    // Also check Shared drives
    const sharedCandidate = path.join(cloudStorage, drive, 'Shared drives', 'client context', 'loblaw digital', 'transcripts');
    if (fs.existsSync(path.dirname(sharedCandidate))) {
      if (!fs.existsSync(sharedCandidate)) fs.mkdirSync(sharedCandidate, { recursive: true });
      return sharedCandidate;
    }
  }

  // If the exact folder doesn't exist yet, create it in the first drive
  const firstDrive = drives[0];
  const fallback = path.join(cloudStorage, firstDrive, 'My Drive', 'client context', 'loblaw digital', 'transcripts');
  fs.mkdirSync(fallback, { recursive: true });
  return fallback;
}

const SYNC_STATE_PATH = path.join(HOME, '.lca-granola-sync-state.json');
const LOCK_PATH = path.join(HOME, '.lca-granola-sync.lock');

// Target Granola folder names (case-insensitive match)
const TARGET_FOLDERS = ['loblaw', 'loblaws', 'loblaw digital', 'remedy'];

// ── Logging ─────────────────────────────────────────────────
function log(msg) { console.log(`[${new Date().toISOString()}] ${msg}`); }
function logError(msg) { console.error(`[${new Date().toISOString()}] ERROR: ${msg}`); }

// ── Lock ────────────────────────────────────────────────────
function acquireLock() {
  if (fs.existsSync(LOCK_PATH)) {
    const lockTime = parseInt(fs.readFileSync(LOCK_PATH, 'utf8'), 10);
    if (Date.now() - lockTime < 30 * 60 * 1000) {
      logError('Sync already running. Exiting.');
      process.exit(0);
    }
  }
  fs.writeFileSync(LOCK_PATH, Date.now().toString());
}
function releaseLock() {
  if (fs.existsSync(LOCK_PATH)) fs.unlinkSync(LOCK_PATH);
}

// ── Credentials ─────────────────────────────────────────────
function getToken() {
  if (!fs.existsSync(CREDS_PATH)) {
    throw new Error('Granola not found. Open Granola and log in first.');
  }
  const raw = JSON.parse(fs.readFileSync(CREDS_PATH, 'utf8'));
  const tokens = JSON.parse(raw.workos_tokens);

  const expiresAt = tokens.obtained_at + (tokens.expires_in * 1000);
  if (Date.now() > expiresAt) {
    throw new Error('Granola token expired. Open Granola to refresh, then re-run.');
  }
  return tokens.access_token;
}

// ── API ─────────────────────────────────────────────────────
let TOKEN = '';

function api(endpoint, body = {}) {
  return new Promise((resolve, reject) => {
    const data = JSON.stringify(body);
    const req = https.request({
      hostname: API_HOST,
      port: 443,
      path: endpoint,
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${TOKEN}`,
        'Content-Type': 'application/json',
        'User-Agent': 'Granola/5.354.0',
        'X-Client-Version': '5.354.0',
        'Content-Length': Buffer.byteLength(data),
        'Accept-Encoding': 'gzip, deflate',
      },
    }, (res) => {
      const chunks = [];
      res.on('data', c => chunks.push(c));
      res.on('end', () => {
        const buf = Buffer.concat(chunks);
        const parse = (d) => {
          const s = d.toString('utf8');
          if (res.statusCode === 404) return resolve(null);
          if (res.statusCode >= 400) return reject(new Error(`API ${res.statusCode}: ${s.slice(0, 200)}`));
          try { resolve(JSON.parse(s)); } catch { reject(new Error(`Bad JSON: ${s.slice(0, 200)}`)); }
        };
        zlib.gunzip(buf, (err, decoded) => parse(err ? buf : decoded));
      });
    });
    req.on('error', reject);
    req.write(data);
    req.end();
  });
}

function delay(ms) { return new Promise(r => setTimeout(r, ms)); }

// ── Sync State ──────────────────────────────────────────────
function loadState() {
  if (fs.existsSync(SYNC_STATE_PATH)) return JSON.parse(fs.readFileSync(SYNC_STATE_PATH, 'utf8'));
  return { synced: {}, lastSync: null };
}
function saveState(state) {
  fs.writeFileSync(SYNC_STATE_PATH, JSON.stringify(state, null, 2));
}

// ── Fetch Granola folders and find Loblaw doc IDs ───────────
async function getLoblawDocIds() {
  const response = await api('/v2/get-document-lists', {});
  const lists = response?.lists || (Array.isArray(response) ? response : []);

  const docIds = new Set();
  for (const list of lists) {
    const name = (list.name || list.title || '').toLowerCase();
    if (TARGET_FOLDERS.some(t => name.includes(t))) {
      log(`Found Granola folder: "${list.name || list.title}" (${(list.documents || list.document_ids || []).length} docs)`);
      for (const d of (list.documents || list.document_ids || [])) {
        docIds.add(typeof d === 'string' ? d : d.id);
      }
    }
  }

  return docIds;
}

// ── Fetch all documents ─────────────────────────────────────
async function fetchDocs() {
  const all = [];
  let offset = 0;
  while (true) {
    const res = await api('/v2/get-documents', { limit: 100, offset, include_last_viewed_panel: false });
    if (!res?.docs?.length) break;
    all.push(...res.docs);
    if (res.docs.length < 100) break;
    offset += 100;
    await delay(REQUEST_DELAY);
  }
  return all;
}

// ── Format to markdown ──────────────────────────────────────
function toMarkdown(doc, transcript) {
  const lines = [];
  lines.push(`# ${doc.title}`);
  lines.push('');

  const date = new Date(doc.created_at);
  lines.push(`**Date:** ${date.toLocaleDateString('en-US', { weekday: 'long', year: 'numeric', month: 'long', day: 'numeric' })}`);

  if (doc.google_calendar_event?.start?.dateTime) {
    const t = new Date(doc.google_calendar_event.start.dateTime);
    lines.push(`**Time:** ${t.toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit', timeZoneName: 'short' })}`);
  }

  lines.push(`**Source:** Granola (synced by ${os.userInfo().username})`);
  lines.push(`**Document ID:** ${doc.id}`);

  // Attendees
  const attendees = [];
  const seen = new Set();
  for (const a of (doc.people?.attendees || [])) {
    const key = a.email || a.name;
    if (key && !seen.has(key)) {
      seen.add(key);
      let entry = a.name || a.email;
      if (a.email) {
        const domain = a.email.split('@')[1];
        if (domain && domain !== 'latecheckout.studio') entry += ` (${domain})`;
      }
      attendees.push(entry);
    }
  }
  if (attendees.length) {
    lines.push('');
    lines.push('**Attendees:**');
    attendees.forEach(a => lines.push(`- ${a}`));
  }

  lines.push('');
  lines.push('---');
  lines.push('');

  // Notes
  if (doc.notes_markdown) {
    lines.push('## Notes');
    lines.push('');
    lines.push(doc.notes_markdown);
    lines.push('');
    lines.push('---');
    lines.push('');
  }

  // Transcript
  lines.push('## Transcript');
  lines.push('');
  if (Array.isArray(transcript) && transcript.length) {
    for (const seg of transcript) {
      const speaker = seg.source === 'microphone' ? 'You' : 'Other';
      const time = new Date(seg.start_timestamp).toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit' });
      lines.push(`**[${time}] ${speaker}:** ${seg.text}`);
      lines.push('');
    }
  } else {
    lines.push('*No transcript available.*');
  }

  return lines.join('\n');
}

// ── Filename ────────────────────────────────────────────────
function makeFilename(title, createdAt, existing) {
  const dateStr = createdAt.split('T')[0];
  let safe = (title || 'meeting').toLowerCase().replace(/[^a-z0-9\s-]/g, '').replace(/\s+/g, '-').slice(0, 80).replace(/-+$/, '') || 'meeting';
  let name = `${dateStr}_${safe}.md`;
  let i = 1;
  while (existing.includes(name)) { name = `${dateStr}_${safe}_${i++}.md`; }
  return name;
}

// ── Main ────────────────────────────────────────────────────
async function main() {
  log('LCA Granola Sync starting...');

  // Find Google Drive path
  const outputDir = findGDrivePath();
  if (!outputDir) {
    logError('Google Drive not found. Install Google Drive for Desktop and make sure the "client context/loblaw digital" folder is accessible.');
    process.exit(1);
  }
  log(`Output: ${outputDir}`);

  acquireLock();

  try {
    TOKEN = getToken();
    const state = loadState();

    // Get doc IDs from Loblaw-related Granola folders
    const loblawIds = await getLoblawDocIds();
    await delay(REQUEST_DELAY);

    // Fetch all docs
    const allDocs = await fetchDocs();
    log(`Found ${allDocs.length} total documents`);

    // Filter to Loblaw docs only (by folder assignment OR title keyword)
    const loblawDocs = allDocs.filter(doc => {
      if (loblawIds.has(doc.id)) return true;
      const title = (doc.title || '').toLowerCase();
      return TARGET_FOLDERS.some(t => title.includes(t)) || title.includes('remedy');
    });
    log(`${loblawDocs.length} Loblaw-related documents`);

    // Filter to unsynced
    const toSync = loblawDocs.filter(d => !state.synced[d.id]);
    log(`${toSync.length} new to sync`);

    if (!toSync.length) {
      log('All caught up. Nothing new to sync.');
      state.lastSync = new Date().toISOString();
      saveState(state);
      releaseLock();
      return;
    }

    let count = 0;
    let errors = 0;
    const existing = fs.readdirSync(outputDir);

    for (const doc of toSync) {
      try {
        log(`Syncing: ${doc.title}`);
        await delay(REQUEST_DELAY);

        const transcript = await api('/v1/get-document-transcript', { document_id: doc.id });
        if (!transcript) {
          log('  No transcript, skipping');
          state.synced[doc.id] = { title: doc.title, skipped: true, at: new Date().toISOString() };
          continue;
        }

        const filename = makeFilename(doc.title, doc.created_at, existing);
        const md = toMarkdown(doc, transcript);

        fs.writeFileSync(path.join(outputDir, filename), md);
        existing.push(filename);
        log(`  Saved: ${filename}`);

        state.synced[doc.id] = { title: doc.title, file: filename, at: new Date().toISOString() };
        count++;

        if (count % 10 === 0) saveState(state);
      } catch (e) {
        logError(`Failed "${doc.title}": ${e.message}`);
        errors++;
      }
    }

    state.lastSync = new Date().toISOString();
    saveState(state);

    log(`Done: ${count} synced, ${errors} errors`);

  } finally {
    releaseLock();
  }
}

main().catch(e => { logError(e.message); releaseLock(); process.exit(1); });
