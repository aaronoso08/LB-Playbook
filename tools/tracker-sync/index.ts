// tracker-sync: reads the Excel trackers from Microsoft 365 and saves ONLY counts for the Playbook.
// Called every 10 minutes by Supabase (public.tracker_kick, one call per tracker) with the x-sync-token header.
// Never writes to the Excel files. Never stores client names, addresses or phone numbers.
// Needs Edge Function secrets: MS_CLIENT_ID, MS_CLIENT_SECRET (and optional MS_TENANT_ID, default latinobuilt.org).
// SheetJS from npm (0.18.5). Only our own tracker files are read with it.
import * as XLSX from "npm:xlsx@0.18.5";

const SB = Deno.env.get("SUPABASE_URL")!;
const SR = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const H = { apikey: SR, Authorization: `Bearer ${SR}`, "Content-Type": "application/json" };
const G = "https://graph.microsoft.com/v1.0";
const FEE = 750; // HHGP assessment fee

const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { "Content-Type": "application/json" } });
async function db(path: string, init: RequestInit = {}) {
  const r = await fetch(`${SB}/rest/v1/${path}`, { ...init, headers: { ...H, ...(init.headers || {}) } });
  const t = await r.text();
  if (!r.ok) throw new Error(`db ${path.split("?")[0]} ${r.status} ${t.slice(0, 200)}`);
  return t ? JSON.parse(t) : null;
}
const save = (key: string, row: Record<string, unknown>) =>
  db(`tracker_sources?key=eq.${encodeURIComponent(key)}`, { method: "PATCH", body: JSON.stringify({ ...row, synced_at: new Date().toISOString() }) });

// ---------- Microsoft 365 ----------
async function graphToken() {
  const tenant = Deno.env.get("MS_TENANT_ID") || "latinobuilt.org";
  const id = Deno.env.get("MS_CLIENT_ID"), secret = Deno.env.get("MS_CLIENT_SECRET");
  if (!id || !secret) throw new Error("Microsoft connection isn't set up yet (MS_CLIENT_ID / MS_CLIENT_SECRET).");
  const r = await fetch(`https://login.microsoftonline.com/${encodeURIComponent(tenant)}/oauth2/v2.0/token`, {
    method: "POST",
    body: new URLSearchParams({ client_id: id, client_secret: secret, scope: "https://graph.microsoft.com/.default", grant_type: "client_credentials" }),
  });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error("Microsoft sign-in failed: " + String(j.error_description || j.error || r.status).split(/\r?\n/)[0].slice(0, 220));
  return j.access_token as string;
}
class GErr extends Error { constructor(m: string, public status: number) { super(m) } }
async function g(tok: string, path: string) {
  const r = await fetch(G + path, { headers: { Authorization: `Bearer ${tok}` } });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new GErr(`Microsoft says: ${j?.error?.message || r.status}`.slice(0, 240), r.status);
  return j;
}
const encPath = (p: string) => p.split("/").map(encodeURIComponent).join("/");
const SEL = "$select=id,name,eTag,lastModifiedDateTime,parentReference";

// location: user:<upn>:/<path>   or   site:<host>:/sites/<site>:/<path>
async function findFile(tok: string, loc: string) {
  const p = loc.split(":");
  let drive: string, path: string;
  if (p[0] === "user" && p.length === 3) { drive = `/users/${encodeURIComponent(p[1])}/drive`; path = p[2]; }
  else if (p[0] === "site" && p.length === 4) { const site = await g(tok, `/sites/${p[1]}:${p[2]}?$select=id`); drive = `/sites/${site.id}/drive`; path = p[3]; }
  else throw new Error("The tracker's location is written wrong in tracker_sources.");
  try {
    return { drive, item: await g(tok, `${drive}/root:${encPath(path)}?${SEL}`), movedTo: null as string | null };
  } catch (e) {
    if (!(e instanceof GErr) || e.status !== 404) throw e;
    const name = path.split("/").pop()!;
    const s = await g(tok, `${drive}/root/search(q='${encodeURIComponent(name.replace(/'/g, "''"))}')?${SEL}`);
    const hit = (s.value || []).find((x: any) => String(x.name).toLowerCase() === name.toLowerCase());
    if (!hit) throw new Error(`Couldn't find ${name}. Was it moved, renamed or deleted?`);
    const folder = String(hit.parentReference?.path || "").replace(/^.*root:/, "") || "/";
    return { drive, item: hit, movedTo: folder };
  }
}
async function download(tok: string, drive: string, id: string) {
  const r = await fetch(`${G}${drive}/items/${id}/content`, { headers: { Authorization: `Bearer ${tok}` } });
  if (!r.ok) throw new Error(`Couldn't download the file (${r.status}).`);
  return new Uint8Array(await r.arrayBuffer());
}

// ---------- Reading sheets ----------
type Row = unknown[];
const norm = (v: unknown) => String(v ?? "").toLowerCase().replace(/[‐-―]/g, "-").replace(/\s+/g, " ").trim();
const todayPT = () => new Intl.DateTimeFormat("en-CA", { timeZone: "America/Los_Angeles" }).format(new Date());
const addDays = (d: string, n: number) => new Date(Date.parse(d + "T12:00:00Z") + n * 864e5).toISOString().slice(0, 10);
function day(v: unknown): string | null {
  if (v == null || v === "") return null;
  if (typeof v === "number") return v > 20000 && v < 80000 ? new Date(Math.round((v - 25569) * 864e5)).toISOString().slice(0, 10) : null;
  if (v instanceof Date) return isNaN(+v) ? null : v.toISOString().slice(0, 10);
  const s = String(v).trim(), m = s.match(/^(\d{1,2})\/(\d{1,2})\/(\d{2,4})$/);
  if (m) { const y = m[3].length === 2 ? 2000 + +m[3] : +m[3]; return `${y}-${m[1].padStart(2, "0")}-${m[2].padStart(2, "0")}`; }
  const d = new Date(s); return isNaN(+d) ? null : d.toISOString().slice(0, 10);
}
const filled = (v: unknown) => !(v == null || v === false || v === 0 || ["", "false", "no", "n", "0", "-", "☐"].includes(norm(v)));
const col = (hs: string[], ...tests: (string | RegExp)[]) => {
  for (const t of tests) { const i = hs.findIndex((h) => (typeof t === "string" ? h === t : t.test(h))); if (i >= 0) return i; }
  return -1;
};

function readBook(buf: Uint8Array, only?: string) {
  const opts: any = { type: "array", dense: true, cellFormula: false, cellHTML: false, cellText: false, cellStyles: false, bookVBA: false };
  if (only) opts.sheets = [only];
  return XLSX.read(buf, opts);
}
// Finds the sheet whose heading row (first 15 rows) passes the test, keeping the one with the most filled rows.
function findTable(wb: any, test: (hs: string[]) => boolean, nameCol: (hs: string[]) => number) {
  const hidden = new Set((wb.Workbook?.Sheets || []).filter((s: any) => s.Hidden).map((s: any) => s.name));
  let best: any = null;
  for (const name of wb.SheetNames) {
    const ws = wb.Sheets[name];
    if (!ws || !ws["!ref"] || hidden.has(name)) continue;
    const rows: Row[] = XLSX.utils.sheet_to_json(ws, { header: 1, raw: true, defval: null, blankrows: true });
    for (let i = 0; i < Math.min(rows.length, 15); i++) {
      const hs = (rows[i] || []).map(norm);
      if (!test(hs)) continue;
      const nc = nameCol(hs), body = rows.slice(i + 1).filter((r) => r && filled(r[nc]));
      if (!best || body.length > best.body.length) best = { sheet: name, headerRow: i + 1, hs, body };
      break;
    }
  }
  return best;
}
const found = (hs: string[], cols: Record<string, number>) =>
  Object.fromEntries(Object.entries(cols).map(([k, i]) => [k, i >= 0 ? hs[i] : null]));
const plural = (n: number, one: string, many: string) => `${n} ${n === 1 ? one : many}`;
const nums = (list: [string, string | number][]) => list.map(([label, value]) => ({ label, value: String(value), src: "tracker" }));

// ---------- HHGP Tracker ----------
function hhgp(wb: any) {
  const nameOf = (hs: string[]) => col(hs, "client name", "name", "client", /client name/, /^name/);
  const t = findTable(wb, (hs) => col(hs, "status") >= 0 && col(hs, /hha.*date/, /date.*hha/, /^hha$/, /assessment date/) >= 0, nameOf);
  if (!t) throw new Error("Couldn't find the client list (a sheet with Status and HHA Date headings).");
  const hs = t.hs, c = {
    name: nameOf(hs), status: col(hs, "status"), hha: col(hs, /hha.*date/, /date.*hha/, /^hha$/, /assessment date/),
    call: col(hs, /30.?day.*call/, /30.?day/, /call.*30/),
  };
  const today = todayPT();
  let done = 0, scheduled = 0, toCall = 0, overdue = 0, billable = 0, stuck = 0, referredOut = 0, noAnswer = 0;
  for (const r of t.body as Row[]) {
    const st = norm(r[c.status]), d = day(r[c.hha]);
    if (st.includes("referred out")) referredOut++;
    if (st.startsWith("no answer")) noAnswer++;
    if (d && d <= today) {
      done++;
      if (!st.includes("not eligible")) billable++;
      if (c.call >= 0 && !filled(r[c.call])) { toCall++; if (addDays(d, 30) <= today) overdue++; }
      if (st.startsWith("scheduled") && d < today) stuck++;
    } else if (d) scheduled++;
  }
  const list: [string, string | number][] = [["Assessments done", done], ["Scheduled", scheduled]];
  if (c.call >= 0) list.push(["30-day calls overdue", overdue]);
  list.push(["Billable assessment $", "$" + (billable * FEE).toLocaleString("en-US")]);
  const alerts: string[] = [];
  if (stuck) alerts.push(`${plural(stuck, "home is", "homes are")} still "Scheduled" after the visit`);
  if (overdue) alerts.push(`Overdue 30-day calls: ${overdue}`);
  else if (toCall) alerts.push(`30-day calls coming up: ${toCall}`);
  return {
    numbers: nums(list), alerts,
    detail: { sheet: t.sheet, header_row: t.headerRow, rows: t.body.length, columns: found(hs, c), to_call: toCall, still_scheduled: stuck, referred_out: referredOut, no_answer: noAnswer },
    sheet: t.sheet,
  };
}

// ---------- Referral Tracker ----------
function referrals(wb: any) {
  const nameOf = (hs: string[]) => col(hs, "client name", /client name/, "name");
  const t = findTable(wb, (hs) => nameOf(hs) >= 0 && col(hs, /^sent to/, /^date sent/) >= 0, nameOf);
  if (!t) throw new Error("Couldn't find the Referrals sheet (a sheet with Client Name and Sent To headings).");
  const hs = t.hs, c = {
    name: nameOf(hs), sent: col(hs, /^date sent/), to: col(hs, /^sent to/), follow: col(hs, /^follow.?up/), outcome: col(hs, /^outcome/),
  };
  const today = todayPT();
  let notSent = 0, due = 0, closed = 0;
  for (const r of t.body as Row[]) {
    const sent = c.sent >= 0 ? day(r[c.sent]) : null, hasOutcome = c.outcome >= 0 && filled(r[c.outcome]);
    if (hasOutcome) { closed++; continue; }
    if (!sent && !(c.to >= 0 && filled(r[c.to]))) { notSent++; continue; }
    const f = c.follow >= 0 ? day(r[c.follow]) : sent ? addDays(sent, 14) : null;
    if (f && f <= today) due++;
  }
  const alerts: string[] = [];
  if (due) alerts.push(`${plural(due, "follow-up is", "follow-ups are")} due`);
  if (notSent) alerts.push(`${plural(notSent, "client hasn't", "clients haven't")} been sent to a partner yet`);
  return {
    numbers: nums([["Referred out", t.body.length], ["Not sent yet", notSent], ["Follow-ups due", due], ["Closed", closed]]),
    alerts, detail: { sheet: t.sheet, header_row: t.headerRow, rows: t.body.length, columns: found(hs, c) }, sheet: t.sheet,
  };
}
const READERS: Record<string, (wb: any) => any> = { hhgp, referrals };

// ---------- One tracker ----------
async function syncOne(tok: string, s: any, force: boolean) {
  const { drive, item, movedTo } = await findFile(tok, s.location);
  const today = todayPT();
  const edited = item.lastModifiedDateTime || null;
  if (!force && s.ok && s.file_etag === item.eTag && s.computed_on === today) {
    await save(s.key, { ok: true, message: null, file_edited_at: edited });
    return { key: s.key, unchanged: true };
  }
  const buf = await download(tok, drive, item.id);
  const known = s.detail?.sheet as string | undefined;
  let res: any = null;
  if (known) { try { res = READERS[s.kind](readBook(buf, known)); } catch { res = null; } }
  if (!res) res = READERS[s.kind](readBook(buf));
  const detail = { ...res.detail, file: item.name, ...(movedTo ? { moved_to: movedTo } : {}) };
  await save(s.key, {
    ok: true, message: movedTo ? `File was found in ${movedTo}. Update its location when you can.` : null,
    numbers: res.numbers, alerts: res.alerts, detail, file_etag: item.eTag, file_edited_at: edited, computed_on: today,
  });
  return { key: s.key, numbers: res.numbers, alerts: res.alerts, detail };
}

Deno.serve(async (req) => {
  const u = new URL(req.url);
  const cfg = await db("tracker_config?id=eq.1&select=sync_token");
  const given = req.headers.get("x-sync-token") || u.searchParams.get("k");
  if (!given || !cfg?.[0]?.sync_token || given !== cfg[0].sync_token) return json({ error: "not allowed" }, 403);
  let body: any = {};
  try { body = req.method === "POST" ? await req.json() : {}; } catch { body = {}; }
  const key = body.key || u.searchParams.get("key");
  const force = body.force === true || u.searchParams.get("force") === "1";
  const sources = await db(`tracker_sources?active=eq.true${key ? `&key=eq.${encodeURIComponent(key)}` : ""}&select=*`);
  if (!sources?.length) return json({ ok: true, results: [] });
  let tok: string;
  try { tok = await graphToken(); } catch (e) {
    for (const s of sources) await save(s.key, { ok: false, message: String((e as Error).message).slice(0, 300) });
    return json({ ok: false, error: (e as Error).message }, 200);
  }
  const results = [];
  for (const s of sources) {
    try { results.push(await syncOne(tok, s, force)); }
    catch (e) {
      const msg = String((e as Error).message || e).slice(0, 300);
      console.error("sync", s.key, msg);
      await save(s.key, { ok: false, message: msg });
      results.push({ key: s.key, error: msg });
    }
  }
  return json({ ok: true, results });
});
