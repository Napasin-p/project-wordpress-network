/* Security Dashboard
 * อ่าน data/latest.json + data/history.json (สร้างโดย logwatch container)
 * ⚠️ ทุกข้อความที่มาจาก log (path, user-agent, IP, ผลของ AI) ใส่ผ่าน textContent เท่านั้น
 *    ห้ามใช้ innerHTML — ผู้โจมตีควบคุมข้อความเหล่านี้ได้ (กัน stored XSS)
 */
"use strict";

const TZ = "Asia/Bangkok";
const STATUS = {
  low:      { label: "ต่ำ",      ico: "✓", cls: "st-low" },
  medium:   { label: "ปานกลาง", ico: "!", cls: "st-medium" },
  high:     { label: "สูง",      ico: "!!", cls: "st-high" },
  critical: { label: "วิกฤต",    ico: "✕", cls: "st-critical" },
};
const INCIDENT_TYPE = {
  brute_force: "เดารหัสผ่าน", vuln_scan: "สแกนหาช่องโหว่", sqli: "SQL injection",
  path_traversal: "Path traversal", user_enum: "สืบรายชื่อผู้ใช้", geoblock_pressure: "ถูก geo-block",
  scraping: "ดูดข้อมูล", misconfiguration: "ตั้งค่าผิดพลาด", other: "อื่น ๆ",
};
const ATTACK_NAME = {
  sqli: "SQL injection", path_traversal: "Path traversal", sensitive_file: "หาไฟล์ลับ (.env, .git, backup)",
  admin_probe: "หาหน้า admin (phpMyAdmin ฯลฯ)", xmlrpc: "XML-RPC", user_enum: "สืบรายชื่อผู้ใช้",
  xss: "XSS", shell_upload: "เรียก PHP ใน uploads",
};
const COUNTRY = {
  TH: "ไทย", US: "สหรัฐฯ", GB: "สหราชอาณาจักร", CN: "จีน", RU: "รัสเซีย", DE: "เยอรมนี", FR: "ฝรั่งเศส",
  NL: "เนเธอร์แลนด์", SG: "สิงคโปร์", JP: "ญี่ปุ่น", KR: "เกาหลีใต้", HK: "ฮ่องกง", TW: "ไต้หวัน",
  IN: "อินเดีย", ID: "อินโดนีเซีย", VN: "เวียดนาม", MY: "มาเลเซีย", BR: "บราซิล", CA: "แคนาดา",
  AU: "ออสเตรเลีย", UA: "ยูเครน", BG: "บัลแกเรีย", SC: "เซเชลส์", IR: "อิหร่าน", TR: "ตุรกี",
  RO: "โรมาเนีย", PL: "โปแลนด์", SE: "สวีเดน", CH: "สวิตเซอร์แลนด์", IT: "อิตาลี", ES: "สเปน",
  UZ: "อุซเบกิสถาน", AR: "อาร์เจนตินา", ZZ: "ไม่ระบุ", LOCAL: "ภายในเครื่อง", "?": "ไม่ทราบ",
};

// ---------- DOM helpers (textContent เท่านั้น) ----------
function el(tag, attrs, ...children) {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v === undefined || v === null || v === false) continue;
    if (k === "class") node.className = v;
    else node.setAttribute(k, v === true ? "" : String(v));
  }
  for (const c of children.flat()) {
    if (c === null || c === undefined || c === false) continue;
    node.append(c instanceof Node ? c : document.createTextNode(String(c)));
  }
  return node;
}
const SVGNS = "http://www.w3.org/2000/svg";
function sv(tag, attrs, text) {
  const node = document.createElementNS(SVGNS, tag);
  for (const [k, v] of Object.entries(attrs || {})) node.setAttribute(k, String(v));
  if (text !== undefined) node.textContent = String(text);
  return node;
}
const $ = (id) => document.getElementById(id);
const fmt = (n) => (n === null || n === undefined ? "–" : Number(n).toLocaleString("th-TH"));
const country = (cc) => (COUNTRY[cc] ? `${COUNTRY[cc]} (${cc})` : cc || "?");
const when = (iso) => (iso ? new Date(iso).toLocaleString("th-TH", { timeZone: TZ, dateStyle: "medium", timeStyle: "short" }) : "–");

let MASK = true;
function ip(s) {
  if (!MASK || !s) return s;
  if (/^\d+\.\d+\.\d+\.\d+$/.test(s)) return s.split(".").slice(0, 2).join(".") + ".x.x";
  if (s.includes(":")) return s.split(":").slice(0, 2).join(":") + ":…";
  return s;
}
function badge(level) {
  const st = STATUS[level] || { label: "ยังไม่มีผล", ico: "?", cls: "st-none" };
  return el("span", { class: `badge ${st.cls}` }, el("span", { class: "ico", "aria-hidden": "true" }, st.ico), st.label);
}
function table(headers, rows, numCols = []) {
  if (!rows.length) return el("p", { class: "empty" }, "ไม่มีข้อมูลในช่วงนี้");
  return el("div", { class: "table-wrap" },
    el("table", {},
      el("thead", {}, el("tr", {}, headers.map((h, i) => el("th", { class: numCols.includes(i) ? "num" : null }, h)))),
      el("tbody", {}, rows.map((r) => el("tr", {}, r.map((c, i) => {
        const isMono = c && typeof c === "object" && c.mono;
        return el("td", { class: numCols.includes(i) ? "num" : isMono ? "mono" : null }, isMono ? c.mono : c);
      }))))));
}

// ---------- tooltip ----------
const tip = () => $("tip");
function showTip(evt, text) {
  const t = tip(); t.textContent = text; t.hidden = false;
  const x = Math.min(evt.clientX + 14, window.innerWidth - t.offsetWidth - 8);
  const y = Math.max(evt.clientY - t.offsetHeight - 10, 8);
  t.style.left = `${x}px`; t.style.top = `${y}px`;
}
const hideTip = () => { tip().hidden = true; };

function niceMax(v) {
  if (v <= 4) return 4;
  const p = Math.pow(10, Math.floor(Math.log10(v)));
  for (const m of [1, 2, 2.5, 5, 10]) if (m * p >= v) return m * p;
  return 10 * p;
}
// แท่งมุมโค้ง 4px เฉพาะปลายข้อมูล ฐานตรงติด baseline
function barPath(x, y, w, h) {
  if (h <= 0) return "";
  const r = Math.min(4, w / 2, h);
  return `M${x},${y + h}V${y + r}Q${x},${y} ${x + r},${y}H${x + w - r}Q${x + w},${y} ${x + w},${y + r}V${y + h}Z`;
}

// ---------- กราฟแท่งรายชั่วโมง (ชุดข้อมูลเดียว) ----------
function hourlyChart(container, hours, values, unit) {
  const W = 640, H = 200, L = 36, R = 6, T = 10, B = 26;
  const iw = W - L - R, ih = H - T - B;
  const max = niceMax(Math.max(0, ...values));
  const n = values.length, slot = iw / n, gap = 2, bw = Math.max(2, slot - gap);
  const svg = sv("svg", { class: "bars", viewBox: `0 0 ${W} ${H}`, role: "img", "aria-label": container.querySelector("h2").textContent });
  for (const f of [0, 0.5, 1]) {
    const y = T + ih - ih * f;
    svg.append(sv("line", { class: "grid", x1: L, x2: W - R, y1: y, y2: y }));
    svg.append(sv("text", { class: "axis-label", x: L - 6, y: y + 4, "text-anchor": "end" }, fmt(max * f)));
  }
  const labelHour = (iso) => new Date(iso).toLocaleTimeString("th-TH", { timeZone: TZ, hour: "2-digit", minute: "2-digit", hour12: false });
  values.forEach((v, i) => {
    const x = L + i * slot + gap / 2, h = (v / max) * ih, y = T + ih - h;
    const g = sv("g", {});
    const hit = sv("rect", { class: "hit", x: L + i * slot, y: T, width: slot, height: ih });
    const bar = sv("path", { class: "bar", d: barPath(x, y, bw, h) });
    const text = `${labelHour(hours[i])} น. · ${fmt(v)} ${unit}`;
    hit.addEventListener("mousemove", (e) => { bar.classList.add("active"); showTip(e, text); });
    hit.addEventListener("mouseleave", () => { bar.classList.remove("active"); hideTip(); });
    g.append(hit, bar);
    svg.append(g);
    if (i % 6 === 0 || i === n - 1) svg.append(sv("text", { class: "axis-label", x: L + i * slot + slot / 2, y: H - 8, "text-anchor": "middle" }, labelHour(hours[i])));
  });
  container.querySelector("svg")?.remove();
  container.querySelector("details")?.remove();
  container.append(svg);
  container.append(el("details", { class: "tv" }, el("summary", {}, "ดูเป็นตาราง"),
    table(["ชั่วโมง", unit], hours.map((h, i) => [labelHour(h), fmt(values[i])]), [1])));
}

// ---------- กราฟแท่งแนวนอน (ชุดข้อมูลเดียว) ----------
function hbarChart(container, rows, unit) {
  container.querySelector("svg")?.remove();
  container.querySelector("details")?.remove();
  container.querySelector(".empty")?.remove();
  if (!rows.length) { container.append(el("p", { class: "empty" }, "ไม่มีการบล็อกในช่วงนี้")); return; }
  const W = 640, rowH = 26, L = 150, R = 48;
  const H = rows.length * rowH + 6;
  const max = Math.max(...rows.map((r) => r.value));
  const svg = sv("svg", { class: "bars", viewBox: `0 0 ${W} ${H}`, role: "img", "aria-label": container.querySelector("h2").textContent });
  rows.forEach((r, i) => {
    const y = i * rowH + 3, bh = rowH - 8, w = Math.max(2, ((W - L - R) * r.value) / max);
    svg.append(sv("text", { class: "cat", x: L - 8, y: y + bh / 2 + 4, "text-anchor": "end" }, r.label));
    const hit = sv("rect", { class: "hit", x: 0, y: i * rowH, width: W, height: rowH });
    // แนวนอน: ฐานอยู่ซ้าย ปลายข้อมูล (ขวา) โค้ง
    const rr = Math.min(4, bh / 2, w);
    const bar = sv("path", { class: "bar", d: `M${L},${y}H${L + w - rr}Q${L + w},${y} ${L + w},${y + rr}V${y + bh - rr}Q${L + w},${y + bh} ${L + w - rr},${y + bh}H${L}Z` });
    hit.addEventListener("mousemove", (e) => { bar.classList.add("active"); showTip(e, `${r.label} · ${fmt(r.value)} ${unit}`); });
    hit.addEventListener("mouseleave", () => { bar.classList.remove("active"); hideTip(); });
    svg.append(hit, bar, sv("text", { class: "val", x: L + w + 6, y: y + bh / 2 + 4 }, fmt(r.value)));
  });
  container.append(svg);
  container.append(el("details", { class: "tv" }, el("summary", {}, "ดูเป็นตาราง"),
    table(["ประเทศ", unit], rows.map((r) => [r.label, fmt(r.value)]), [1])));
}

// ---------- render ----------
let DATA = null, HISTORY = [];

function tile(label, value, note, cls) {
  return el("div", { class: `tile ${cls || ""}` }, el("div", { class: "label" }, label), el("div", { class: "value" }, value), note ? el("div", { class: "note" }, note) : null);
}

function render() {
  const d = DATA; if (!d) return;
  const s = d.stats, ai = d.ai || {}, m = ai.meta || {}, f = ai.findings;
  const usage = d._usage || {};

  $("meta").textContent = `สแกนล่าสุด ${when(d.generated_at)} · ช่วงข้อมูล ${d.window.hours} ชั่วโมง (${when(d.window.from)} – ${when(d.window.to)})`;

  // tiles
  const level = f ? f.threat_level : null;
  const st = STATUS[level] || { label: "ยังไม่มีผล", ico: "?", cls: "st-none" };
  const threat = el("div", { class: "tile threat" },
    el("div", { class: `lamp ${st.cls}`, "aria-hidden": "true" }, st.ico),
    el("div", {}, el("div", { class: "label" }, "ระดับภัยคุกคาม (AI)"), el("div", { class: "value" }, st.label),
      el("div", { class: "note" }, f ? `${f.incidents.length} เหตุการณ์` : (m.error ? `ผิดพลาด: ${m.error}` : "ยังไม่ได้วิเคราะห์"))));
  const geo = s.geoblock, ng = s.nginx, sys = s.system || {};
  const banned = Object.values(s.fail2ban.currently_banned || {}).reduce((a, l) => a + l.length, 0);
  $("tiles").replaceChildren(
    threat,
    tile("บล็อกต่างประเทศ", fmt(geo.logged_drops), `${fmt(geo.unique_ips)} IP · ${d.window.hours} ชม.`),
    tile("Requests ที่เข้าถึงเว็บ", fmt(ng.total_requests), `${fmt(ng.unique_ips)} IP`),
    tile("WordPress login ผิด", fmt(ng.wp_login.failed_total), `จาก ${fmt(ng.wp_login.post_total)} ครั้ง`),
    tile("fail2ban แบนอยู่", fmt(banned), "IP"),
    tile("ใบรับรอง HTTPS", sys.cert_days_left != null ? `${sys.cert_days_left} วัน` : "–", "ก่อนหมดอายุ (ต่ออายุอัตโนมัติ)"),
    tile("ค่า AI สะสม", usage.est_cost_usd != null ? `$${usage.est_cost_usd.toFixed(2)}` : "–", usage.runs ? `${fmt(usage.runs)} รอบ · ${fmt(usage.input_tokens + usage.output_tokens)} token` : ""),
  );

  // AI
  $("ai-meta").textContent = m.model_served
    ? `${m.model_served} · effort ${m.effort} · ${fmt(m.input_tokens)} + ${fmt(m.output_tokens)} token · ~$${(m.est_cost_usd || 0).toFixed(3)} · ${m.seconds}s`
    : (m.error ? `ผิดพลาด: ${m.error}` : "");
  $("ai-summary").textContent = f ? f.summary_th : (m.error ? "การวิเคราะห์รอบล่าสุดไม่สำเร็จ — ดูรายละเอียดด้านบน" : "ยังไม่มีผลวิเคราะห์");
  const inc = $("incidents");
  inc.replaceChildren(...(f && f.incidents.length
    ? f.incidents.map((i) => el("div", { class: "incident" },
        el("div", { class: "row1" }, badge(i.severity), el("span", { class: "title" }, i.title_th), el("span", { class: "type" }, INCIDENT_TYPE[i.type] || i.type)),
        el("dl", {},
          i.source_ips.length ? [el("dt", {}, "IP ต้นทาง"), el("dd", {}, i.source_ips.map(ip).join(", "))] : null,
          el("dt", {}, "หลักฐาน"), el("dd", {}, i.evidence_th),
          el("dt", {}, "ควรทำ"), el("dd", {}, i.recommended_action_th))))
    : [el("p", { class: "empty" }, f ? "ไม่พบเหตุการณ์ผิดปกติ" : "—")]));
  $("review").replaceChildren(...(f && f.ips_to_review.length
    ? f.ips_to_review.map((r) => el("li", {}, el("code", {}, ip(r.ip)), " — ", r.reason_th))
    : [el("li", { class: "empty" }, "ไม่มี")]));
  $("defenses").replaceChildren(...(f ? f.defenses_working_th.map((t) => el("li", {}, t)) : []));
  $("ai-notes").textContent = f && f.notes_th ? `หมายเหตุจาก AI: ${f.notes_th}` : "";

  // charts
  hourlyChart($("c-geo"), d.series.hours, d.series.geoblock_drops || [], "ครั้งที่ถูกบล็อก");
  hourlyChart($("c-req"), d.series.hours, d.series.requests || [], "requests");
  hbarChart($("c-country"), (geo.top_countries || []).slice(0, 10).map((c) => ({ label: country(c.country), value: c.count })), "ครั้ง");

  // attacks
  const atk = Object.entries(ng.attack_patterns || {});
  $("attacks").replaceChildren(table(["รูปแบบ", "ครั้ง", "IP หลัก", "ตัวอย่าง"],
    atk.map(([k, v]) => [ATTACK_NAME[k] || k, fmt(v.count), v.top_ips.map((x) => ip(x.ip)).join(", "), { mono: (v.samples || [])[0] || "" }]), [1]));

  $("top-ips").replaceChildren(table(["IP", "ประเทศ", "requests", "4xx"],
    ng.top_ips.slice(0, 8).map((x) => [{ mono: ip(x.ip) }, country(x.country), fmt(x.requests), fmt(x.client_errors)]), [2, 3]));

  const ssh = s.ssh, f2b = s.fail2ban;
  const sshRows = [
    ["SSH login สำเร็จ (public key)", fmt(ssh.events.accepted || 0)],
    ["SSH user ที่ไม่มีอยู่จริง", fmt(ssh.events.invalid_user || 0)],
    ["SSH user ที่ไม่ได้รับอนุญาต (เช่น root)", fmt(ssh.events.not_allowed || 0)],
    ["WordPress login (POST)", fmt(ng.wp_login.post_total)],
    ["WordPress login ผิด", fmt(ng.wp_login.failed_total)],
    ...Object.entries(f2b.by_jail || {}).map(([j, c]) => [`fail2ban ${j}: แบน`, fmt(c.Ban || 0)]),
  ];
  const bannedRows = Object.entries(f2b.currently_banned || {}).flatMap(([j, l]) => l.map((x) => [j, { mono: ip(x.ip) }, country(x.country)]));
  $("auth").replaceChildren(table(["รายการ", "จำนวน"], sshRows, [1]),
    el("h3", {}, "IP ที่ fail2ban แบนอยู่ตอนนี้"), table(["jail", "IP", "ประเทศ"], bannedRows));

  const svc = Object.entries(sys.services || {});
  $("system").replaceChildren(
    table(["บริการ", "สถานะ"], svc.map(([k, v]) => [k, badge(v === "active" ? "low" : "critical")])),
    table(["รายการ", "ค่า"], [
      ["Load (1 นาที)", sys.load_1m != null ? sys.load_1m.toFixed(2) : "–"],
      ["RAM ใช้ไป", sys.mem_used_pct != null ? `${sys.mem_used_pct}%` : "–"],
      ["Disk ใช้ไป", sys.disk_used_pct != null ? `${sys.disk_used_pct}%` : "–"],
      ["ช่วง IP ไทยใน ipset", Object.entries(sys.ipset_entries || {}).map(([k, v]) => `${k}: ${fmt(v)}`).join(" · ")],
      ["Uptime", sys.uptime_hours != null ? `${sys.uptime_hours} ชม.` : "–"],
    ], [1]));
  // สถานะบริการใช้ badge "ต่ำ/วิกฤต" ไม่สื่อ — เปลี่ยนคำให้ตรงความหมาย
  $("system").querySelectorAll(".badge").forEach((b) => { b.lastChild.textContent = b.classList.contains("st-low") ? "ทำงาน" : "หยุด"; });

  $("history").replaceChildren(table(["เวลา", "ระดับ", "เหตุการณ์", "บล็อก", "ค่า AI"],
    HISTORY.slice(-10).reverse().map((h) => [when(h.at), h.threat_level ? badge(h.threat_level) : (h.error ? "ผิดพลาด" : "ไม่ใช้ AI"), fmt(h.incidents), fmt(h.geoblock_drops), h.cost_usd ? `$${h.cost_usd.toFixed(3)}` : "–"]), [2, 3, 4]));
}

async function load() {
  try {
    const [latest, history, usage] = await Promise.all([
      fetch("data/latest.json", { cache: "no-store" }).then((r) => { if (!r.ok) throw new Error(`latest.json HTTP ${r.status}`); return r.json(); }),
      fetch("data/history.json", { cache: "no-store" }).then((r) => (r.ok ? r.json() : [])),
      fetch("data/usage.json", { cache: "no-store" }).then((r) => (r.ok ? r.json() : {})),
    ]);
    DATA = latest; DATA._usage = usage; HISTORY = history;
    $("error").hidden = true;
    render();
  } catch (e) {
    $("error").textContent = `โหลดข้อมูลไม่สำเร็จ: ${e.message}`;
    $("error").hidden = false;
  }
}

document.addEventListener("DOMContentLoaded", () => {
  $("mask").addEventListener("change", (e) => { MASK = e.target.checked; render(); });
  $("reload").addEventListener("click", load);
  load();
  setInterval(load, 5 * 60 * 1000);
});
