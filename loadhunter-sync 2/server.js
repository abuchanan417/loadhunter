/* Load Hunter sync server
   Pulls trucks, positions, odometer and hours of service from ISAAC and
   writes them into Supabase: the real tables (trucks, truck_positions,
   driver_hos) and the app's "feeds" record so the planner sees them live.
   Credentials live only in environment variables on Render. */

const http = require("http");
const { createClient } = require("@supabase/supabase-js");

const env = (k, d) => (process.env[k] == null || process.env[k] === "" ? d : process.env[k]);
const CFG = {
  isaacTokenUrl: env("ISAAC_TOKEN_URL", "https://auth.isaachosting.ca/IdentityServer/identity/connect/token"),
  isaacApi: env("ISAAC_API", "https://ct697.isaachosting.ca/isaacapi").replace(/\/+$/, ""),
  isaacUser: env("ISAAC_USER"),
  isaacPass: env("ISAAC_PASS"),
  isaacAuth: env("ISAAC_AUTH"),            // the "Authorization Code" from ISAAC (base64 of client:secret)
  isaacScope: env("ISAAC_SCOPE", ""),      // leave blank unless ISAAC says otherwise
  supabaseUrl: env("SUPABASE_URL"),
  supabaseKey: env("SUPABASE_SERVICE_KEY"),
  syncSecret: env("SYNC_SECRET", ""),
  positionsEvery: +env("POSITIONS_EVERY_SEC", 60),
  hosEvery: +env("HOS_EVERY_SEC", 300),
  fleetEvery: +env("FLEET_EVERY_SEC", 21600),
  autoActiveDays: +env("AUTO_ACTIVE_DAYS", 7),
  leadsAddress: env("LEADS_INBOUND_ADDRESS", ""),   // the CloudMailin address; posts to any other "to" are refused   // a position newer than this flips an out-of-service truck to active
  port: +env("PORT", 10000),
};
for (const k of ["isaacUser", "isaacPass", "isaacAuth", "supabaseUrl", "supabaseKey"]) {
  if (!CFG[k]) { console.error("Missing environment variable for " + k); }
}
const sb = createClient(CFG.supabaseUrl || "http://localhost", CFG.supabaseKey || "x", { auth: { persistSession: false } });

const STATUS = { startedAt: new Date().toISOString(), token: null, runs: {}, errors: [], counts: {} };
const note = (what, data) => { STATUS.runs[what] = Object.assign({ at: new Date().toISOString() }, data || {}); };
const fail = (what, e) => { const m = (e && e.message) || String(e); console.error(what + ": " + m); STATUS.errors.unshift({ at: new Date().toISOString(), what, message: m }); STATUS.errors = STATUS.errors.slice(0, 20); };

/* ---------- ISAAC auth (OAuth2 password flow) ---------- */
let TOKEN = { value: null, exp: 0 };
async function token() {
  if (TOKEN.value && Date.now() < TOKEN.exp - 60000) return TOKEN.value;
  const body = new URLSearchParams({ grant_type: "password", username: CFG.isaacUser, password: CFG.isaacPass });
  if (CFG.isaacScope) body.set("scope", CFG.isaacScope);
  const r = await fetch(CFG.isaacTokenUrl, { method: "POST", headers: { Authorization: "Basic " + CFG.isaacAuth, "Content-Type": "application/x-www-form-urlencoded" }, body });
  const text = await r.text();
  if (!r.ok) throw new Error("ISAAC token " + r.status + ": " + text.slice(0, 300));
  const j = JSON.parse(text);
  TOKEN = { value: j.access_token, exp: Date.now() + (j.expires_in || 3600) * 1000 };
  STATUS.token = { ok: true, expiresAt: new Date(TOKEN.exp).toISOString() };
  return TOKEN.value;
}
async function isaac(path, params) {
  const u = new URL(CFG.isaacApi + path);
  Object.entries(params || {}).forEach(([k, v]) => { if (v == null || v === "") return; if (Array.isArray(v)) v.forEach(x => u.searchParams.append(k, x)); else u.searchParams.set(k, v); });
  const r = await fetch(u, { headers: { Authorization: "Bearer " + await token(), Accept: "application/json" } });
  const text = await r.text();
  if (!r.ok) throw new Error("ISAAC " + path + " " + r.status + ": " + text.slice(0, 300));
  return text ? JSON.parse(text) : null;
}

/* ---------- helpers ---------- */
// .NET TimeSpan "d.hh:mm:ss" or "hh:mm:ss" (can be negative) -> hours
function spanHours(s) {
  if (s == null || s === "") return null;
  const m = String(s).match(/^(-)?(?:(\d+)\.)?(\d{1,2}):(\d{2}):(\d{2})/);
  if (!m) return null;
  const h = (+(m[2] || 0)) * 24 + (+m[3]) + (+m[4]) / 60 + (+m[5]) / 3600;
  return Math.round((m[1] ? -h : h) * 100) / 100;
}
const r2 = n => n == null ? null : Math.round(n * 100) / 100;
const STATUS_MAP = { "off duty": "Off duty", offduty: "Off duty", off: "Off duty", sleeper: "Sleeper", "sleeper berth": "Sleeper", driving: "Driving", "on duty": "On duty", onduty: "On duty", "on duty not driving": "On duty" };
const dutyStatus = s => STATUS_MAP[String(s || "").toLowerCase().trim()] || (s ? String(s) : "");
const nameKeys = n => { const s = String(n || "").trim(); if (!s) return []; const out = new Set([s]); const m = s.match(/^([^,]+),\s*(.+)$/); if (m) out.add(m[2].trim() + " " + m[1].trim()); return [...out]; };

async function upsert(table, rows, onConflict) {
  if (!rows.length) return 0;
  for (let i = 0; i < rows.length; i += 200) {
    const { error } = await sb.from(table).upsert(rows.slice(i, i + 200), onConflict ? { onConflict } : undefined);
    if (error) throw new Error(table + ": " + error.message);
  }
  return rows.length;
}
let FEEDS = { units: {}, drivers: {}, src: "isaac", at: null };
async function writeFeeds() {
  FEEDS.at = new Date().toISOString();
  const { error } = await sb.from("app_docs").upsert({ collection: "data/company", doc_id: "feeds", data: FEEDS });
  if (error) throw new Error("feeds: " + error.message);
}

/* ---------- sync jobs ---------- */
async function syncFleet() {
  const vehicles = await isaac("/api/v1.0/vehicles", { active: true }) || [];
  const list = Array.isArray(vehicles) ? vehicles : [vehicles];
  const rows = list.filter(v => v.vehicleNo).map(v => ({
    unit: String(v.vehicleNo).trim(),
    vin: v.serialNo || null, plate: v.licensePlate || null, year: v.modelYear || null,
    eld_device: "ISAAC", extra: { isaac: v },
  }));
  // only fill what's blank on an existing truck; never flip status
  for (const row of rows) {
    const { data: ex } = await sb.from("trucks").select("id,vin,plate,year,extra").eq("unit", row.unit).maybeSingle();
    if (ex) {
      const patch = { eld_device: "ISAAC", extra: Object.assign({}, ex.extra || {}, { isaac: row.extra.isaac }) };
      if (!ex.vin && row.vin) patch.vin = row.vin; if (!ex.plate && row.plate) patch.plate = row.plate; if (!ex.year && row.year) patch.year = row.year;
      const { error } = await sb.from("trucks").update(patch).eq("id", ex.id); if (error) throw new Error("trucks: " + error.message);
    } else {
      const { error } = await sb.from("trucks").insert(Object.assign({ status: "active" }, row)); if (error) throw new Error("trucks: " + error.message);
    }
  }
  const ops = await isaac("/api/v1.0/operators", { active: true }) || [];
  STATUS.counts.vehicles = rows.length; STATUS.counts.operators = ops.length;
  note("fleet", { vehicles: rows.length, operators: ops.length });
  return ops;
}

async function syncPositions() {
  const res = await isaac("/api/v1.0/positions", { distanceInMiles: true });
  const list = Array.isArray(res) ? res : (res && res.vehiclePositionInfos) || (res ? [res] : []);
  const rows = [], units = {};
  for (const p of list) {
    if (!p.vehicleNo || p.latitude == null) continue;
    const unit = String(p.vehicleNo).trim(), at = p.readingDateTime || new Date().toISOString();
    rows.push({ unit, at, lat: p.latitude, lng: p.longitude, speed: p.speed, heading: p.course, odometer: p.odometer != null ? Math.round(p.odometer) : null,
      engine_hours: p.engineHours, fuel_pct: p.fuelLevel, driver_no: p.driverNo, driver_name: p.driverName, address: p.proximityAddress, online: p.online, source: "isaac" });
    units[unit] = { gps: { lat: p.latitude, lon: p.longitude, at, src: "isaac", odometer: p.odometer != null ? Math.round(p.odometer) : "", label: p.proximityAddress || "", speed: p.speed, driver: p.driverName || "" } };
  }
  await upsert("truck_positions", rows, "unit,at");
  // last position onto the truck record
  const fresh = at => (Date.now() - new Date(at).getTime()) < CFG.autoActiveDays * 86400000;
  for (const r of rows) {
    const patch = { last_lat: r.lat, last_lng: r.lng, last_speed: r.speed, last_position_at: r.at, last_address: r.address,
      odometer: r.odometer, odometer_at: r.odometer != null ? r.at : undefined, engine_hours: r.engine_hours };
    const { data: ex } = await sb.from("trucks").select("id,status").eq("unit", r.unit).maybeSingle();
    if (!ex) { await sb.from("trucks").insert(Object.assign({ unit: r.unit, status: fresh(r.at) ? "active" : "out_of_service", eld_device: "ISAAC" }, patch)); continue; }
    if (fresh(r.at) && (ex.status === "out_of_service" || ex.status === "inactive")) patch.status = "active";  // a truck that pings is a truck we run
    await sb.from("trucks").update(patch).eq("id", ex.id);
  }
  Object.keys(units).forEach(u => { FEEDS.units[u] = Object.assign(FEEDS.units[u] || {}, units[u]); });
  await writeFeeds();
  STATUS.counts.positions = rows.length;
  note("positions", { vehicles: rows.length });
}

async function syncHos(ops) {
  if (!ops) ops = await isaac("/api/v1.0/operators", { active: true }) || [];
  const nos = ops.map(o => o.operatorNo).filter(n => n != null);
  const byNo = {}; ops.forEach(o => byNo[o.operatorNo] = o);
  const rows = [];
  for (let i = 0; i < nos.length; i += 30) {
    const chunk = nos.slice(i, i + 30);
    const [avail, recap] = await Promise.all([
      isaac("/api/v1.2/driverAvailability/UsaRegulations", { driverNo: chunk }).catch(e => { fail("hos availability", e); return []; }),
      isaac("/api/v1.1/driverAvailability/UsaRecap", { driverNo: chunk }).catch(e => { fail("hos recap", e); return []; }),
    ]);
    const A = {}; (avail || []).forEach(a => A[a.driverNo] = a);
    const R = {}; (recap || []).forEach(r => R[r.driverNo] = r);
    for (const n of chunk) {
      const a = A[n], r = R[n]; if (!a && !r) continue;
      const op = byNo[n] || {};
      const name = (a && a.driverName) || (r && r.driverName) || [op.firstName, op.lastName].filter(Boolean).join(" ");
      const prev = (r && r.recapInfos && r.recapInfos.workedHoursPrevDayList) || [];
      const recapArr = prev.slice(-7).map(d => spanHours(d.workTime) || 0);
      if (r && r.recapInfos && r.recapInfos.workedHoursEvalDay != null) recapArr.push(spanHours(r.recapInfos.workedHoursEvalDay) || 0);
      const at = new Date().toISOString();
      const hos = {
        status: dutyStatus(a && a.status),
        driveLeft: r2(r ? spanHours(r.timeRemainingDriving) : (a ? spanHours(a.availableDriving) : null)),
        windowLeft: r2(r ? spanHours(r.timeRemainingShift) : null),
        cycleLeft: r2(r ? spanHours(r.timeRemainingOnDutyForCycle) : (a && a.cumulativeOnDutyHours != null ? 70 - spanHours(a.cumulativeOnDutyHours) : null)),
        breakIn: r2(spanHours((r && r.drivingTimeRemainingBeforeBreak) || (a && a.drivingTimeRemainingBeforeBreak))),
        recap: recapArr.length ? recapArr.join(", ") : "",
        lastDutyChange: a && a.lastDutyChangeUtc || null,
        at, src: "isaac",
      };
      rows.push({ isaac_driver_no: n, driver_name: name, at, status: hos.status, drive_left_h: hos.driveLeft, window_left_h: hos.windowLeft,
        cycle_left_h: hos.cycleLeft, break_in_h: hos.breakIn, recap: recapArr, last_duty_change_at: hos.lastDutyChange, raw: { availability: a, recap: r }, license: op.operatorLicence || null });
      nameKeys(name).forEach(k => { FEEDS.drivers[k] = { hos }; });
      // same hours on the unit the driver is in right now
      Object.keys(FEEDS.units).forEach(u => { const g = FEEDS.units[u].gps; if (g && g.driver && nameKeys(g.driver).includes(name)) FEEDS.units[u].hos = hos; });
    }
  }
  await upsert("driver_hos", rows, "isaac_driver_no");
  await writeFeeds();
  STATUS.counts.hos = rows.length;
  note("hos", { drivers: rows.length });
}


async function syncFaults() {
  // cursor lives in settings so a restart never re-reads the whole history
  const { data: cur } = await sb.from("settings").select("value").eq("key", "isaac_dtc_tracking_key").maybeSingle();
  let key = cur && cur.value != null ? +cur.value : 0;
  const res = await isaac("/api/v1.0/dtc", { trackingKey: key });
  const vehicles = (res && res.vehicles) || [];
  let n = 0;
  const lamp = d => { const l = d.lampStatus || {}; const on = Object.entries(l).filter(([k, v]) => v === true || v === 1 || v === "On").map(([k]) => k.replace(/Lamp.*$/i, "")); return on.length ? on.join(",") : null; };
  for (const v of vehicles) {
    const unit = String(v.vehicleId || "").trim(); if (!unit) continue;
    for (const d of v.dtcs || []) {
      const code = d.errorCode || (d.spn != null ? "SPN " + d.spn + (d.fmi != null ? " FMI " + d.fmi : "") : null);
      if (!code) continue;
      const seen = d.occuredOn || new Date().toISOString();
      const { data: ex } = await sb.from("truck_faults").select("id,status,occurrences").eq("unit", unit).eq("code", code).maybeSingle();
      if (ex) {
        const patch = { last_seen_at: seen, occurrences: Math.max(ex.occurrences + 1, d.occurenceCount || 0), lamp: lamp(d), raw: d };
        if (ex.status === "dismissed" || ex.status === "cleared") patch.status = "new";   // came back
        await sb.from("truck_faults").update(patch).eq("id", ex.id);
      } else {
        await sb.from("truck_faults").insert({ unit, code, spn: d.spn, fmi: d.fmi, description: d.spnDescription || d.errorCodeDescription || d.siDorPIDDescription || null,
          fmi_description: d.fmiDescription || null, source_desc: d.saDescription || d.midDescription || null, lamp: lamp(d),
          first_seen_at: seen, last_seen_at: seen, occurrences: d.occurenceCount || 1, raw: d });
      }
      n++;
    }
  }
  if (res && res.trackingKey != null && res.trackingKey !== key) {
    await sb.from("settings").upsert({ key: "isaac_dtc_tracking_key", value: res.trackingKey, description: "ISAAC fault code cursor (sync server)" });
  }
  STATUS.counts.faults = n;
  note("faults", { vehicles: vehicles.length, codes: n, trackingKey: res && res.trackingKey });
}


/* ---------- inbound lead emails (CloudMailin JSON normalized → applicants) ---------- */
const LEAD_FIELDS = [
  ["first_name", /\b(first\s*name)\s*[:=]\s*(.+)/i],
  ["last_name", /\b(last\s*name|surname)\s*[:=]\s*(.+)/i],
  ["full_name", /\b(?:applicant|driver|candidate|lead)?\s*(name)\s*[:=]\s*(.+)/i],
  ["phone", /\b(phone|mobile|cell|telephone)(?:\s*number)?\s*[:=]\s*([+()\d .-]{7,})/i],
  ["email", /\b(e-?mail)(?:\s*address)?\s*[:=]\s*([^\s,;<>]+@[^\s,;<>]+)/i],
  ["city", /\b(city)\s*[:=]\s*(.+)/i],
  ["state", /\b(state)\s*[:=]\s*([A-Za-z .]{2,20})/i],
  ["zip", /\b(zip(?:\s*code)?|postal)\s*[:=]\s*(\d{5})/i],
  ["license_class", /\b(cdl(?:\s*class)?|license\s*class|class)\s*[:=]\s*([ABC])\b/i],
  ["license_state", /\b(cdl\s*state|license\s*state)\s*[:=]\s*([A-Za-z]{2})\b/i],
  ["years_experience", /\b(experience|years?\s*(?:of\s*)?experience|cdl\s*experience)\s*[:=]\s*([\d.]+)/i],
  ["endorsements", /\b(endorsements?)\s*[:=]\s*(.+)/i],
  ["lead_id", /\b(lead\s*id|reference|ref\s*#?|id)\s*[:=]\s*([\w-]+)/i],
];
function parseLead(text) {
  const out = {}; const lines = String(text || "").replace(/\r/g, "").split("\n").map(l => l.trim()).filter(Boolean);
  for (const [k, re] of LEAD_FIELDS) {
    for (const l of lines) { const m = l.match(re); if (m && m[2] && out[k] == null) { out[k] = m[2].trim(); break; } }
  }
  if (!out.first_name && out.full_name) { const p = out.full_name.split(/\s+/); out.first_name = p.shift(); out.last_name = p.join(" "); }
  if (!out.email) { const m = String(text || "").match(/[\w.+-]+@[\w-]+\.[\w.-]+/); if (m) out.email = m[0]; }
  if (!out.phone) { const m = String(text || "").match(/\(?\d{3}\)?[ .-]?\d{3}[ .-]?\d{4}/); if (m) out.phone = m[0]; }
  if (out.state && out.state.length > 2) { const ST = { alabama: "AL", arkansas: "AR", missouri: "MO", oklahoma: "OK", kansas: "KS", texas: "TX", tennessee: "TN", kentucky: "KY", illinois: "IL", iowa: "IA", nebraska: "NE", mississippi: "MS", louisiana: "LA", georgia: "GA", indiana: "IN", ohio: "OH", michigan: "MI", wisconsin: "WI", minnesota: "MN", colorado: "CO", "new mexico": "NM", arizona: "AZ", florida: "FL", alabama_: "AL" }; out.state = ST[out.state.toLowerCase()] || out.state.slice(0, 2).toUpperCase(); }
  const e = (out.endorsements || "").toUpperCase();
  out.hazmat = /H\b|HAZ/.test(e); out.tanker = /\bN\b|TANK/.test(e); out.doubles = /\bT\b|DOUBLE/.test(e);
  return out;
}
async function handleLead(req, res, source) {
  let body = ""; for await (const chunk of req) body += chunk;
  let mail; try { mail = JSON.parse(body); } catch (e) { res.writeHead(400); return res.end("bad json"); }
  const h = mail.headers || {}; const env = mail.envelope || {};
  const to = String((env.to || h.to || "")).toLowerCase();
  if (CFG.leadsAddress && !to.includes(CFG.leadsAddress.toLowerCase())) { res.writeHead(403); return res.end("wrong address"); }
  const text = mail.plain || (mail.html ? String(mail.html).replace(/<[^>]+>/g, " ") : "") || "";
  const p = parseLead(text);
  const raw = { subject: h.subject, from: h.from || env.from, received_at: new Date().toISOString(), plain: mail.plain, html: mail.html ? String(mail.html).slice(0, 20000) : null };
  // keep the raw email no matter what, then try to make an applicant
  const { data: lead, error: le } = await sb.from("lead_emails").insert({ source, from_addr: raw.from, subject: raw.subject, body: raw.plain || raw.html, parsed: p, raw: mail }).select("id").single();
  if (le) { fail("lead store", le); }
  if (p.first_name || p.phone || p.email) {
    const { data: camp } = await sb.from("campaigns").select("id").ilike("vendor", source).eq("active", true).order("starts_on", { ascending: false }).limit(1).maybeSingle();
    const dup = p.phone ? await sb.from("applicants").select("id").eq("phone", p.phone).maybeSingle() : { data: null };
    if (dup.data) { await sb.from("lead_emails").update({ applicant_id: dup.data.id, note: "duplicate of existing applicant" }).eq("id", lead && lead.id); }
    else {
      const { data: app, error: ae } = await sb.from("applicants").insert({
        stage: "new", source, campaign_id: camp ? camp.id : null, first_name: p.first_name || "(unknown)", last_name: p.last_name || "", phone: p.phone || null, email: p.email || null,
        city: p.city || null, state: p.state || null, zip: p.zip || null, license_state: p.license_state || null, license_class: p.license_class || null,
        years_experience: p.years_experience ? +p.years_experience : null, hazmat: !!p.hazmat, tanker: !!p.tanker, doubles: !!p.doubles,
        notes: "From " + source + " lead email" + (p.lead_id ? " #" + p.lead_id : "") + (raw.subject ? ": " + raw.subject : ""),
        application: { lead_email_id: lead && lead.id, parsed: p },
      }).select("id").single();
      if (ae) fail("lead applicant", ae); else if (lead) await sb.from("lead_emails").update({ applicant_id: app.id }).eq("id", lead.id);
    }
  }
  STATUS.counts.leads = (STATUS.counts.leads || 0) + 1; note("leads", { last_from: raw.from, parsed: Object.keys(p).filter(k => p[k]) });
  res.writeHead(200, { "Content-Type": "application/json" }); res.end(JSON.stringify({ ok: true, parsed: p }));
}

/* ---------- scheduler ---------- */
let OPS = null, busy = false;
async function run(what) {
  if (busy) return; busy = true;
  try {
    if (what === "fleet" || what === "all") OPS = await syncFleet();
    if (what === "positions" || what === "all") await syncPositions();
    if (what === "hos" || what === "all") await syncHos(OPS);
    if (what === "faults" || what === "all") await syncFaults().catch(e => fail("faults", e));
    await sb.from("settings").upsert({ key: "isaac_sync", value: { runs: STATUS.runs, counts: STATUS.counts, errors: STATUS.errors.slice(0, 5) }, description: "ISAAC sync status (written by the sync server)" });
  } catch (e) { fail(what, e); }
  finally { busy = false; }
}
function schedule() {
  run("all");
  setInterval(() => run("positions"), CFG.positionsEvery * 1000);
  setInterval(() => run("hos"), CFG.hosEvery * 1000);
  setInterval(() => run("faults"), CFG.hosEvery * 1000);
  setInterval(() => run("fleet"), CFG.fleetEvery * 1000);
}

/* ---------- tiny web server: health, status, manual sync ---------- */
http.createServer(async (req, res) => {
  const u = new URL(req.url, "http://x");
  const json = (code, obj) => { res.writeHead(code, { "Content-Type": "application/json" }); res.end(JSON.stringify(obj, null, 2)); };
  if (u.pathname === "/health") return json(200, { ok: true });
  if (u.pathname.startsWith("/leads/") && req.method === "POST") { try { return await handleLead(req, res, u.pathname.split("/")[2] || "lead"); } catch (e) { fail("leads", e); return json(500, { error: e.message }); } }
  if (u.pathname === "/status") return json(200, STATUS);
  if (u.pathname === "/sync" && req.method === "POST") {
    if (CFG.syncSecret && u.searchParams.get("secret") !== CFG.syncSecret) return json(403, { error: "bad secret" });
    run(u.searchParams.get("what") || "all"); return json(202, { started: true });
  }
  if (u.pathname === "/token-test") {
    if (CFG.syncSecret && u.searchParams.get("secret") !== CFG.syncSecret) return json(403, { error: "bad secret" });
    try { await token(); return json(200, { ok: true, token: STATUS.token }); } catch (e) { return json(500, { ok: false, error: e.message }); }
  }
  json(404, { error: "not found" });
}).listen(CFG.port, () => { console.log("loadhunter-sync listening on " + CFG.port); schedule(); });
