/* Security Dashboard
 * อ่าน data/latest.json + data/history.json (สร้างโดย logwatch container)
 * ⚠️ ทุกข้อความที่มาจาก log (path, user-agent, IP, ผลของ AI) ใส่ผ่าน textContent เท่านั้น
 *    ห้ามใช้ innerHTML — ผู้โจมตีควบคุมข้อความเหล่านี้ได้ (กัน stored XSS)
 */
"use strict";

const TZ = "Asia/Bangkok";
const STATUS = {
  low:      { label: "ต่ำ",      ico: "check", cls: "st-low" },
  medium:   { label: "ปานกลาง", ico: "alert", cls: "st-medium" },
  high:     { label: "สูง",      ico: "alert", cls: "st-high" },
  critical: { label: "วิกฤต",    ico: "x", cls: "st-critical" },
};
const NO_STATUS = { label: "ยังไม่มีผล", ico: "question", cls: "st-none" };
// หัวข้อใหญ่ของการ์ดบนสุด ตามระดับภัยที่ AI ประเมิน
const VERDICT = { low: "ปกติดี", medium: "ควรตรวจสอบ", high: "มีความเสี่ยงสูง", critical: "ต้องรีบจัดการ" };
const SEV_ORDER = { critical: 0, high: 1, medium: 2, low: 3 };
// geoblock_pressure = ต่างประเทศถูก firewall บล็อกไปแล้ว ทุกรอบ AI แนะนำว่า "ไม่ต้องทำอะไร"
// แยกออกจากเรื่องที่ทีมควรแก้ เพื่อให้รู้ว่าอันไหนควรดูก่อนแม้ทุกอันเป็นระดับ "ต่ำ"
const INFO_TYPES = new Set(["geoblock_pressure"]);
const isInfo = (i) => INFO_TYPES.has(i.type) && (i.severity || "low") === "low";
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
// ไอคอนเส้นที่วาดเอง (viewBox 24, เส้นหนาเท่ากันทุกตัว) — แทนตัวอักษร ✓ ! ✕ ⚑
const ICONS = {
  check: ["M5 12.5l4.5 4.5L19 7.5"],
  x: ["M6.5 6.5l11 11", "M17.5 6.5l-11 11"],
  alert: ["M12 6.5v7", "M12 17.6v.1"],
  question: ["M9.3 9.2a2.8 2.8 0 1 1 3.9 2.6c-.7.3-1.2 1-1.2 1.8v.4", "M12 17.6v.1"],
  flag: ["M6 20.5V4", "M6 4.5h10.5l-2 4 2 4H6"],
  info: ["M12 11v6", "M12 7.4v.1"],
};
function icon(name, size = 16, width = 2.4) {
  const s = sv("svg", { class: "ico", viewBox: "0 0 24 24", width: size, height: size, fill: "none", stroke: "currentColor",
    "stroke-width": width, "stroke-linecap": "round", "stroke-linejoin": "round", "aria-hidden": "true", focusable: "false" });
  for (const d of ICONS[name] || []) s.append(sv("path", { d }));
  return s;
}
const $ = (id) => document.getElementById(id);
const fmt = (n) => (n === null || n === undefined ? "–" : Number(n).toLocaleString("th-TH"));
const country = (cc) => (COUNTRY[cc] ? `${COUNTRY[cc]} (${cc})` : cc || "?");
const when = (iso) => (iso ? new Date(iso).toLocaleString("th-TH", { timeZone: TZ, dateStyle: "medium", timeStyle: "short" }) : "–");
// แบบสั้นสำหรับตารางประวัติ เช่น "28 ต.ค. 19:06" (ไม่มีปี ไม่ให้ตัดเป็น 4 บรรทัดบนมือถือ)
const whenShort = (iso) => (iso ? new Date(iso).toLocaleString("th-TH", { timeZone: TZ, day: "numeric", month: "short", hour: "2-digit", minute: "2-digit", hour12: false }) : "–");

let MASK = true;
function ip(s) {
  if (!MASK || !s) return s;
  if (/^\d+\.\d+\.\d+\.\d+$/.test(s)) return s.split(".").slice(0, 2).join(".") + ".x.x";
  if (s.includes(":")) return s.split(":").slice(0, 2).join(":") + ":…";
  return s;
}
// ข้อความอิสระจาก AI อาจมี IP เต็มปนอยู่ → ซ่อนด้วยกฎเดียวกับ ip() (127.0.0.1 = ภายในเครื่อง ไม่ต้องซ่อน)
function maskText(s) {
  if (!MASK || typeof s !== "string") return s;
  return s
    .replace(/\b\d{1,3}(?:\.\d{1,3}){3}\b/g, (m) => (m === "127.0.0.1" ? m : ip(m)))
    .replace(/\b(?:[0-9a-f]{1,4}:){3,7}[0-9a-f]{1,4}\b|\b[0-9a-f]{1,4}::(?:[0-9a-f]{1,4}:?)*/gi, (m) => ip(m)); // IPv6 (เวลา 19:06:00 ไม่โดน)
}
function badge(level) {
  const st = STATUS[level] || NO_STATUS;
  return el("span", { class: `badge ${st.cls}` }, el("span", { class: "ico-wrap" }, icon(st.ico, 12, 2.8)), st.label);
}
// สถานะว่างที่แปลว่า "ปกติดี" — ✓ สีเขียว แทนข้อความจาง ๆ ว่าไม่มีข้อมูล
const allClear = (text, tag = "p") => el(tag, { class: "empty ok" }, text);
function table(headers, rows, numCols = [], empty = "ไม่มีข้อมูลในช่วงนี้") {
  if (!rows.length) return empty instanceof Node ? empty : el("p", { class: "empty" }, empty);
  return el("div", { class: "table-wrap" },
    el("table", {},
      el("thead", {}, el("tr", {}, headers.map((h, i) => el("th", { class: numCols.includes(i) ? "num" : null }, h)))),
      el("tbody", {}, rows.map((r) => el("tr", {}, r.map((c, i) => {
        // ช่องพิเศษ: { mono } ตัวอักษรความกว้างเท่ากัน · { text } ธรรมดา · nowrap: ห้ามตัดบรรทัด (IP, เวลา)
        const spec = c && typeof c === "object" && !(c instanceof Node) ? c : null;
        const cls = [numCols.includes(i) ? "num" : spec && spec.mono !== undefined ? "mono" : null, spec && spec.nowrap ? "nowrap" : null].filter(Boolean).join(" ");
        return el("td", { class: cls || null }, spec ? (spec.mono !== undefined ? spec.mono : spec.text) : c);
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

// กล่องวาดกราฟ: วัดความกว้างจริงแล้ววาด SVG ขนาดนั้นเลย (1 หน่วย = 1px)
// ไม่ใช้ viewBox ตายตัวแล้วย่อทั้งก้อน — บนมือถือตัวอักษรจะเล็กเหลือ ~6px
function chartBox(container) {
  let box = container.querySelector(".chart-box");
  if (!box) { box = el("div", { class: "chart-box" }); container.append(box); }
  box.replaceChildren();
  return box;
}
// ถอดตาราง "ดูเป็นตาราง" เดิมออก แต่จำไว้ว่าเปิดอยู่ไหม จะได้ไม่หุบเองตอนวาดใหม่
function takeTableToggle(container) {
  const old = container.querySelector("details.tv");
  const open = !!(old && old.open);
  old?.remove();
  return open;
}

// ---------- กราฟแท่งรายชั่วโมง (ชุดข้อมูลเดียว) ----------
function hourlyChart(container, hours, values, unit, emptyText) {
  const open = takeTableToggle(container);
  container.querySelector(".empty")?.remove();
  const box = chartBox(container);
  if (!values.length) { box.append(el("p", { class: "empty" }, "ไม่มีข้อมูลในช่วงนี้")); return; }
  // ทั้ง 24 ชม. เป็น 0 — กราฟแบน ๆ ไม่ได้บอกอะไร บอกเป็นข้อความแทน
  if (values.every((v) => !v)) { box.append(allClear(emptyText)); return; }
  const W = Math.round(box.clientWidth) || 640, narrow = W < 480;
  const H = narrow ? 170 : 200, L = 40, R = 6, T = 10, B = 26;
  const iw = W - L - R, ih = H - T - B;
  const max = niceMax(Math.max(0, ...values));
  const n = values.length, slot = iw / n, gap = slot > 8 ? 2 : 1, bw = Math.max(2, slot - gap);
  const every = slot * 6 >= 44 ? 6 : 12;   // ป้ายเวลาห่างกันอย่างน้อย ~44px ไม่ให้ซ้อนกัน
  const svg = sv("svg", { class: "bars", width: W, height: H, viewBox: `0 0 ${W} ${H}`, role: "img", "aria-label": container.querySelector("h2, h3").textContent });
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
    // ป้ายสุดท้ายชิดขวา ไม่ให้ล้นขอบกราฟ — ข้ามป้ายก่อนหน้าถ้าอยู่ใกล้เกินไป
    if (i === n - 1) svg.append(sv("text", { class: "axis-label", x: W - R, y: H - 8, "text-anchor": "end" }, labelHour(hours[i])));
    else if (i % every === 0 && (n - 1 - i) * slot >= 44) svg.append(sv("text", { class: "axis-label", x: L + i * slot + slot / 2, y: H - 8, "text-anchor": "middle" }, labelHour(hours[i])));
  });
  box.append(svg);
  container.append(el("details", { class: "tv", open }, el("summary", {}, "ดูเป็นตาราง"),
    table(["ชั่วโมง", unit], hours.map((h, i) => [labelHour(h), fmt(values[i])]), [1])));
}

// ---------- กราฟแท่งแนวนอน (ชุดข้อมูลเดียว) ----------
// จอแคบ: ชื่อประเทศอยู่บรรทัดบน แท่งอยู่บรรทัดล่างเต็มความกว้าง (ไม่ต้องกันที่ป้ายไว้ซ้าย)
function hbarChart(container, rows, unit) {
  const open = takeTableToggle(container);
  container.querySelector(".empty")?.remove();
  const box = chartBox(container);
  if (!rows.length) { box.append(allClear("ไม่มี IP ต่างประเทศพยายามเข้ามาในช่วงนี้")); return; }
  const W = Math.round(box.clientWidth) || 640, stacked = W < 480;
  const rowH = stacked ? 40 : 26, L = stacked ? 0 : 150, R = 48;
  const H = rows.length * rowH + 6;
  const max = Math.max(...rows.map((r) => r.value));
  const svg = sv("svg", { class: "bars", width: W, height: H, viewBox: `0 0 ${W} ${H}`, role: "img", "aria-label": container.querySelector("h2, h3").textContent });
  rows.forEach((r, i) => {
    const top = i * rowH + 3, bh = stacked ? 14 : rowH - 8, y = stacked ? top + 19 : top;
    const w = Math.max(2, ((W - L - R) * r.value) / max);
    svg.append(stacked
      ? sv("text", { class: "cat", x: 0, y: top + 12 }, r.label)
      : sv("text", { class: "cat", x: L - 8, y: y + bh / 2 + 4, "text-anchor": "end" }, r.label));
    const hit = sv("rect", { class: "hit", x: 0, y: i * rowH, width: W, height: rowH });
    // แนวนอน: ฐานอยู่ซ้าย ปลายข้อมูล (ขวา) โค้ง
    const rr = Math.min(4, bh / 2, w);
    const bar = sv("path", { class: "bar", d: `M${L},${y}H${L + w - rr}Q${L + w},${y} ${L + w},${y + rr}V${y + bh - rr}Q${L + w},${y + bh} ${L + w - rr},${y + bh}H${L}Z` });
    hit.addEventListener("mousemove", (e) => { bar.classList.add("active"); showTip(e, `${r.label} · ${fmt(r.value)} ${unit}`); });
    hit.addEventListener("mouseleave", () => { bar.classList.remove("active"); hideTip(); });
    svg.append(hit, bar, sv("text", { class: "val", x: L + w + 6, y: y + bh / 2 + 4 }, fmt(r.value)));
  });
  box.append(svg);
  container.append(el("details", { class: "tv", open }, el("summary", {}, "ดูเป็นตาราง"),
    table(["ประเทศ", unit], rows.map((r) => [r.label, fmt(r.value)]), [1])));
}

// ---------- ภาษาภาพของกราฟ/ตาราง (วาดทับแบบพื้นฐานด้านบน) ----------
// เปิดด้วย data-* บน #top ใน index.html — ไม่ระบุ = กราฟแท่ง/ตารางพื้นฐาน ("ดูเป็นตาราง" ยังมาจากแบบพื้นฐานเสมอ)
//   data-hourly = area · data-country = rank · data-ips = bars
//   data-auth = stats · data-sys = meters · data-hist = columns
// กติกาสี: ปริมาณ = น้ำเงินเฉดเดียว อ่อน → เข้ม · เขียว/เหลือง/แดงใช้กับสถานะเท่านั้น และมีไอคอนกำกับ
const vizOpt = (k) => ($("top") || document.body).dataset[k];
const vzHour = (iso) => new Date(iso).toLocaleTimeString("th-TH", { timeZone: TZ, hour: "2-digit", minute: "2-digit", hour12: false });
// tooltip จากคีย์บอร์ด: ไม่มีพิกัดเมาส์ ใช้กึ่งกลางของ element แทน
const tipAt = (node, text) => { const r = node.getBoundingClientRect(); showTip({ clientX: r.left + r.width / 2, clientY: r.top }, text); };
const total = (a) => a.reduce((x, y) => x + (y || 0), 0);
function hoverTip(node, text) {
  node.addEventListener("pointermove", (e) => showTip(e, text));
  node.addEventListener("pointerleave", hideTip);
  node.addEventListener("focus", () => tipAt(node, text));
  node.addEventListener("blur", hideTip);
}

function peakLine(hours, values, unit) {
  const max = Math.max(0, ...values), i = values.indexOf(max);
  return el("p", { class: "vz-peak" },
    el("span", {}, "สูงสุด ", el("b", {}, `${fmt(max)} ${unit}`), ` ตอน ${vzHour(hours[i])} น.`),
    el("span", {}, "รวม 24 ชม. ", el("b", {}, fmt(total(values)))));
}
function xLabels(svg, hours, xAt, H, W, R) {
  const n = hours.length, step = (xAt(1) - xAt(0)) || 1, every = step * 6 >= 44 ? 6 : 12;
  hours.forEach((h, i) => {
    if (i === n - 1) svg.append(sv("text", { class: "axis-label", x: W - R, y: H - 8, "text-anchor": "end" }, vzHour(h)));
    else if (i % every === 0 && (n - 1 - i) * step >= 44) svg.append(sv("text", { class: "axis-label", x: xAt(i), y: H - 8, "text-anchor": "middle" }, vzHour(h)));
  });
}
function yGrid(svg, max, L, R, T, ih, W) {
  for (const f of [0, 0.5, 1]) {
    const y = T + ih - ih * f;
    svg.append(sv("line", { class: "grid", x1: L, x2: W - R, y1: y, y2: y }));
    svg.append(sv("text", { class: "axis-label", x: L - 6, y: y + 4, "text-anchor": "end" }, fmt(max * f)));
  }
}

// รายชั่วโมง: พื้นที่ใต้เส้น + เส้นแนวตั้งตามเมาส์
function vzArea(box, label, hours, values, unit) {
  const W = Math.round(box.clientWidth) || 640, H = W < 480 ? 170 : 200, L = 40, R = 12, T = 14, B = 26;
  const iw = W - L - R, ih = H - T - B, n = values.length, max = niceMax(Math.max(0, ...values));
  const xAt = (i) => L + (n > 1 ? (i * iw) / (n - 1) : iw / 2), yAt = (v) => T + ih - (v / max) * ih;
  const svg = sv("svg", { class: "bars vz-area", width: W, height: H, viewBox: `0 0 ${W} ${H}`, role: "img", "aria-label": label });
  yGrid(svg, max, L, R, T, ih, W);
  const line = values.map((v, i) => `${i ? "L" : "M"}${xAt(i).toFixed(1)},${yAt(v).toFixed(1)}`).join("");
  svg.append(sv("path", { class: "vz-fill", d: `${line}L${xAt(n - 1)},${T + ih}L${xAt(0)},${T + ih}Z` }), sv("path", { class: "vz-line", d: line }));
  const pk = values.indexOf(Math.max(...values));
  svg.append(sv("circle", { class: "vz-dot", cx: xAt(pk), cy: yAt(values[pk]), r: 4.5 }));
  xLabels(svg, hours, xAt, H, W, R);
  const cross = sv("line", { class: "vz-cross", x1: 0, x2: 0, y1: T, y2: T + ih, visibility: "hidden" });
  const hot = sv("circle", { class: "vz-dot", r: 5, visibility: "hidden" });
  const hit = sv("rect", { class: "hit", x: L, y: T, width: iw, height: ih });
  svg.append(cross, hot, hit);
  hit.addEventListener("pointermove", (e) => {
    const r = svg.getBoundingClientRect();
    const i = Math.max(0, Math.min(n - 1, Math.round((e.clientX - r.left - L) / (iw / Math.max(1, n - 1)))));
    for (const [k, v] of [["x1", xAt(i)], ["x2", xAt(i)], ["visibility", "visible"]]) cross.setAttribute(k, v);
    for (const [k, v] of [["cx", xAt(i)], ["cy", yAt(values[i])], ["visibility", "visible"]]) hot.setAttribute(k, v);
    showTip(e, `${vzHour(hours[i])} น. · ${fmt(values[i])} ${unit}`);
  });
  hit.addEventListener("pointerleave", () => { cross.setAttribute("visibility", "hidden"); hot.setAttribute("visibility", "hidden"); hideTip(); });
  box.replaceChildren(svg, peakLine(hours, values, unit));
}

// ประเทศ: กระดานอันดับ
function vzRank(box, rows, all) {
  const max = Math.max(...rows.map((r) => r.value));
  box.replaceChildren(el("ol", { class: "vz-rank" }, rows.map((r, i) => {
    const fill = el("span", { class: "vz-rfill" });
    fill.style.width = `${(r.value / max) * 100}%`;
    return el("li", {},
      el("span", { class: "vz-rk" }, String(i + 1)),
      el("span", { class: "vz-rname" }, r.label),
      el("span", { class: "vz-rval" }, fmt(r.value), all ? el("span", { class: "vz-rpct" }, `${Math.round((r.value / all) * 100)}%`) : null),
      el("span", { class: "vz-rbar", "aria-hidden": "true" }, fill));
  })));
}

function vizCharts() {
  const d = DATA, se = d.series || {}, hours = se.hours || [], geo = d.stats.geoblock || {};
  if (vizOpt("hourly") === "area") for (const [id, vals, unit] of [["c-geo", se.geoblock_drops || [], "ครั้งที่ถูกบล็อก"], ["c-req", se.requests || [], "requests"]]) {
    const c = $(id), box = c && c.querySelector(".chart-box");
    if (box && vals.length && vals.some(Boolean)) vzArea(box, c.querySelector("h2, h3").textContent, hours, vals, unit);
  }
  const rows = (geo.top_countries || []).slice(0, 10).map((c) => ({ label: country(c.country), value: c.count }));
  const cbox = $("c-country") && $("c-country").querySelector(".chart-box");
  if (cbox && rows.length && vizOpt("country") === "rank") vzRank(cbox, rows, geo.logged_drops);
}

function vizTables() {
  const s = DATA.stats, ng = s.nginx || {}, sys = s.system || {};

  if (vizOpt("ips") === "bars" && (ng.top_ips || []).length) {
    const ips = ng.top_ips.slice(0, 8), max = Math.max(...ips.map((x) => x.requests));
    $("top-ips").replaceChildren(el("ol", { class: "vz-ips" }, ips.map((x) => {
      const fill = el("span", { class: "vz-rfill" });
      fill.style.width = `${(x.requests / max) * 100}%`;
      return el("li", {},
        el("code", {}, ip(x.ip)), el("span", { class: "vz-ipc" }, country(x.country)),
        el("span", { class: "vz-ipv" }, fmt(x.requests), el("span", { class: "vz-ipe" }, `4xx ${fmt(x.client_errors)}`)),
        el("span", { class: "vz-rbar", "aria-hidden": "true" }, fill));
    })));
  }

  if (vizOpt("auth") === "stats") {
    const ev = (s.ssh || {}).events || {}, wp = ng.wp_login || {};
    const items = [
      ["SSH login สำเร็จ", ev.accepted || 0, "public key", false],
      ["SSH user ไม่มีอยู่จริง", ev.invalid_user || 0, "", true],
      ["SSH user ไม่ได้รับอนุญาต", ev.not_allowed || 0, "เช่น root", true],
      ["WordPress login", wp.post_total || 0, "POST", false],
      ["WordPress login ผิด", wp.failed_total || 0, "", true],
      ...Object.entries((s.fail2ban || {}).by_jail || {}).map(([j, c]) => [`fail2ban ${j}`, c.Ban || 0, "ครั้งที่แบน", false]),
    ];
    $("auth").querySelector(".table-wrap")?.replaceWith(el("div", { class: "vz-stats" }, items.map(([label, v, note, bad]) =>
      el("div", { class: `vz-stat${bad && v ? " is-bad" : ""}` },
        el("span", { class: "vz-sv" }, fmt(v), bad && v ? el("span", { class: "vz-sw" }, icon("alert", 12, 3)) : null),
        el("span", { class: "vz-sl" }, label), note ? el("span", { class: "vz-sn" }, note) : null))));
  }

  if (vizOpt("sys") === "meters") {
    const meter = (label, pct) => {
      const warn = pct >= 90, fill = el("span", { class: "vz-mfill" });
      fill.style.width = `${Math.min(100, pct)}%`;
      return el("div", { class: `vz-meter${warn ? " warn" : ""}` },
        el("span", { class: "vz-ml" }, label), el("span", { class: "vz-mv" }, `${pct}%`, warn ? el("span", { class: "vz-mw" }, icon("alert", 12, 3), "ใกล้เต็ม") : null),
        el("span", { class: "vz-mbar", role: "meter", "aria-valuemin": "0", "aria-valuemax": "100", "aria-valuenow": String(pct), "aria-label": label }, fill));
    };
    const facts = [
      ["Load (1 นาที)", sys.load_1m != null ? sys.load_1m.toFixed(2) : "–"],
      ["Uptime", sys.uptime_hours == null ? "–" : sys.uptime_hours >= 48 ? `${(sys.uptime_hours / 24).toFixed(1)} วัน` : `${sys.uptime_hours} ชม.`],
      ...Object.entries(sys.ipset_entries || {}).map(([k, v]) => [`ช่วง IP ไทย ${k}`, fmt(v)]),
    ];
    $("system").querySelector(".table-wrap")?.replaceWith(el("div", { class: "vz-sys" },
      sys.mem_used_pct != null ? meter("RAM ใช้ไป", sys.mem_used_pct) : null,
      sys.disk_used_pct != null ? meter("Disk ใช้ไป", sys.disk_used_pct) : null,
      el("dl", { class: "vz-facts" }, facts.flatMap(([k, v]) => [el("dt", {}, k), el("dd", {}, v)]))));
  }

  if (vizOpt("hist") === "columns" && HISTORY.length) {
    const last = HISTORY.slice(-12), box = $("history"), old = box.querySelector(".table-wrap");
    const max = niceMax(Math.max(1, ...last.map((h) => h.geoblock_drops || 0)));
    const cols = el("ol", { class: "vz-cols", "aria-label": "ยอดบล็อกและระดับภัย 12 รอบล่าสุด" }, last.map((h, i) => {
      const st = STATUS[h.threat_level] || NO_STATUS;
      const lv = h.threat_level ? st.label : h.error ? "AI ผิดพลาด" : "ไม่ได้ใช้ AI";
      const text = `${whenShort(h.at)} · บล็อก ${fmt(h.geoblock_drops)} · ระดับ${lv} · เหตุการณ์ ${fmt(h.incidents)}`;
      const bar = el("span", { class: "vz-col" });
      bar.style.height = `${((h.geoblock_drops || 0) / max) * 100}%`;
      const li = el("li", { class: i === last.length - 1 ? "now" : null, tabindex: "0", "aria-label": text },
        el("span", { class: "vz-colv" }, fmt(h.geoblock_drops)), el("span", { class: "vz-colbox" }, bar),
        el("span", { class: `vz-colst ${st.cls}` }, icon(st.ico, 11, 3)),
        el("span", { class: "vz-colt" }, vzHour(h.at)));
      hoverTip(li, text);
      return li;
    }));
    box.replaceChildren(el("p", { class: "muted small sub" }, "ยอดบล็อกต่างประเทศต่อรอบ · ไอคอนใต้แท่ง = ระดับภัยจาก AI"), cols,
      old ? el("details", { class: "tv" }, el("summary", {}, "ดูเป็นตาราง (10 รอบล่าสุด)"), old) : null);
  }
}

// ---------- render ----------
let DATA = null, HISTORY = [];
let SUMMARY_OPEN = false;
const INC_OPEN = new Set();   // การ์ดเหตุการณ์ที่เปิด "หลักฐาน" ไว้ (คงไว้ข้ามการ render ใหม่)   // จำว่าเปิด "อ่านต่อ" ไว้ ไม่ให้หุบเองตอน render ใหม่ (สลับซ่อน IP / โหลดทุก 5 นาที)

function tile(label, value, note, cls) {
  return el("div", { class: `tile ${cls || ""}` }, el("div", { class: "label" }, label), el("div", { class: "value" }, value), note ? el("div", { class: "note" }, note) : null);
}
// การ์ดย่อ: สถานะรอง — มีไอคอน + สีเมื่อผิดปกติ (ไม่ใช้สีอย่างเดียว)
const TONE_ICO = { ok: "check", warn: "alert", crit: "x" };
function mini(label, value, note, tone) {
  return el("div", { class: `mini${tone ? ` tone-${tone}` : ""}` },
    el("div", { class: "label" }, label),
    el("div", { class: "value" }, tone ? el("span", { class: "dot" }, icon(TONE_ICO[tone], 12, 3)) : null, value),
    note ? el("div", { class: "note" }, note) : null);
}

// แถบสีระดับภัยย้อนหลัง (ซ้าย = เก่า, ขวาสุด = ล่าสุด)
function historyStrip() {
  const last = HISTORY.slice(-12);
  if (!last.length) return null;
  let start = HISTORY.length;
  while (start > 0 && HISTORY[start - 1].threat_level === "low") start--;
  const streak = HISTORY.length - start;
  return el("div", { class: "hstrip" },
    el("div", { class: "hstrip-head" }, el("span", {}, `ระดับภัย ${last.length} รอบล่าสุด`), el("span", {}, "ขวาสุด = รอบนี้")),
    el("div", { class: "cells", role: "list" }, last.map((h) => {
      const st = STATUS[h.threat_level];
      const label = `${when(h.at)} · ${st ? st.label : h.error ? "AI ผิดพลาด" : "ไม่ได้ใช้ AI"}`;
      return el("span", { class: `cell ${st ? st.cls : "st-none"}`, role: "listitem", title: label, "aria-label": label });
    })),
    streak >= 2 ? el("div", { class: "small streak" }, icon("check", 13, 3), `ต่ำติดต่อกัน ${fmt(streak)} รอบ`) : null);
}

function renderHero(f, m) {
  const level = f ? f.threat_level : null;
  const st = STATUS[level] || NO_STATUS;
  const incidents = f ? f.incidents || [] : [];
  const todo = incidents.filter((i) => !isInfo(i)).length;
  const info = incidents.length - todo;
  const review = f ? (f.ips_to_review || []).length : 0;

  let headline, sub;
  if (f) {
    headline = VERDICT[level] || "ไม่ทราบระดับภัย";
    // แยกเป็นสองท่อน ห้ามตัดกลางวลี (เช่น "ควร / แก้")
    sub = [el("span", { class: "nw" }, `AI ประเมินระดับภัย: ${st.label}`), " · ",
      el("span", { class: "nw" }, todo ? `มี ${todo} เรื่องที่ควรแก้` : "ไม่มีเรื่องที่ต้องแก้")];
  } else {
    headline = m.error ? "AI วิเคราะห์รอบนี้ไม่สำเร็จ" : "ยังไม่มีผลวิเคราะห์จาก AI";
    sub = "ตัวเลขและกราฟด้านล่างยังอัปเดตตามปกติ";
  }

  const body = [];
  if (f && f.summary_th) {
    const sum = el("p", { class: `hero-summary${SUMMARY_OPEN ? "" : " clamped"}`, id: "hero-summary" }, maskText(f.summary_th));
    const more = el("button", { type: "button", class: "linkish", "aria-controls": "hero-summary", "aria-expanded": String(SUMMARY_OPEN), hidden: true }, SUMMARY_OPEN ? "ย่อ" : "อ่านต่อ");
    more.addEventListener("click", () => {
      SUMMARY_OPEN = !SUMMARY_OPEN;
      sum.classList.toggle("clamped", !SUMMARY_OPEN);
      more.textContent = SUMMARY_OPEN ? "ย่อ" : "อ่านต่อ";
      more.setAttribute("aria-expanded", String(SUMMARY_OPEN));
    });
    // แสดงปุ่ม "อ่านต่อ" เฉพาะเมื่อข้อความยาวเกิน 4 บรรทัดจริง
    requestAnimationFrame(() => { more.hidden = !SUMMARY_OPEN && sum.scrollHeight <= sum.clientHeight + 1; });
    body.push(el("h3", {}, "สรุปจาก AI"), sum, more);
  } else if (m.error) {
    body.push(el("details", { class: "err" }, el("summary", {}, "ดูข้อความ error"), el("pre", {}, m.error)));
  }

  const chips = [];
  if (todo) chips.push(el("a", { class: "chip chip-todo", href: "#incidents-h" }, icon("flag", 14, 2.4), `ควรแก้ ${todo} เรื่อง`));
  if (info) chips.push(el("a", { class: "chip", href: "#incidents-h", title: "ถูกบล็อกแล้ว ไม่ต้องทำอะไร" }, `รับทราบ ${info} เรื่อง`));
  if (review) chips.push(el("a", { class: "chip", href: "#review-h", title: "AI เสนอให้ตรวจ — ระบบไม่แบนเอง" }, `IP ที่ควรตรวจ ${review}`));
  if (f && !chips.length) chips.push(el("span", { class: "chip chip-ok" }, icon("check", 14, 2.8), "ไม่พบเหตุการณ์ผิดปกติ"));
  if (chips.length) body.push(el("div", { class: "chips" }, chips));

  const hero = $("hero");
  hero.className = `hero lvl-${f && STATUS[level] ? level : "none"}`;
  // replaceChildren แปลง null เป็นข้อความ "null" จึงต้องกรองออกก่อน
  hero.replaceChildren(...[
    el("div", { class: "hero-main" },
      el("div", { class: "lamp" }, icon(st.ico, 30, 2.6)),
      el("div", {}, el("h2", { class: "hero-headline" }, headline), el("p", { class: "hero-sub" }, sub))),
    historyStrip(),
    body.length ? el("div", { class: "hero-body" }, body) : null,
  ].filter(Boolean));

  // แถบสถานะบนมือถือ: คำตัดสินแบบย่อ ใช้ตอนการ์ดใหญ่เลื่อนพ้นจอ
  if ($("sb-lamp")) {
    $("sb-lamp").className = `sb-lamp ${st.cls}`;
    $("sb-lamp").replaceChildren(icon(st.ico, 16, 2.8));
    $("sb-text").textContent = f ? `${headline} · ${todo ? `ควรแก้ ${todo} เรื่อง` : "ไม่มีเรื่องที่ต้องแก้"}` : headline;
  }
}

function drawCharts() {
  const d = DATA; if (!d) return;
  const se = d.series || {}, hours = se.hours || [], geo = d.stats.geoblock || {};
  hourlyChart($("c-geo"), hours, se.geoblock_drops || [], "ครั้งที่ถูกบล็อก", "ไม่มีการบล็อกใน 24 ชม.ล่าสุด");
  hourlyChart($("c-req"), hours, se.requests || [], "requests", "ไม่มี requests ใน 24 ชม.ล่าสุด");
  hbarChart($("c-country"), (geo.top_countries || []).slice(0, 10).map((c) => ({ label: country(c.country), value: c.count })), "ครั้ง");
  vizCharts();
}

function render() {
  const d = DATA; if (!d) return;
  const s = d.stats, ai = d.ai || {}, m = ai.meta || {}, f = ai.findings;
  const usage = d._usage || {};

  $("meta").textContent = `สแกนล่าสุด ${when(d.generated_at)} · ข้อมูล ${d.window.hours} ชม.ล่าสุด`;
  $("meta").title = `ช่วงข้อมูล ${when(d.window.from)} – ${when(d.window.to)}`;

  renderHero(f, m);

  // tiles
  const geo = s.geoblock, ng = s.nginx, sys = s.system || {};
  const banned = Object.values(s.fail2ban.currently_banned || {}).reduce((a, l) => a + l.length, 0);
  $("tiles").replaceChildren(
    tile("บล็อกต่างประเทศ", fmt(geo.logged_drops), `${fmt(geo.unique_ips)} IP · ${d.window.hours} ชม.`),
    tile("Requests ที่เข้าถึงเว็บ", fmt(ng.total_requests), ng.total_requests ? `${fmt(ng.unique_ips)} IP` : "ช่วงนี้ไม่มีคนเข้าเว็บ"),
    ng.wp_login.failed_total
      ? tile("WordPress login ผิด", fmt(ng.wp_login.failed_total), `จาก ${fmt(ng.wp_login.post_total)} ครั้ง`)
      : tile("WordPress login ผิด", "0", ng.wp_login.post_total ? `ไม่มีผิด (จาก ${fmt(ng.wp_login.post_total)} ครั้ง)` : "ไม่มีการพยายาม login", "is-ok"),
    banned ? tile("fail2ban แบนอยู่", fmt(banned), "IP") : tile("fail2ban แบนอยู่", "0", "ไม่มี IP ที่ต้องแบน", "is-ok"),
  );

  const svc = Object.entries(sys.services || {});
  const down = svc.filter(([, v]) => v !== "active").map(([k]) => k);
  const cert = sys.cert_days_left;
  // certbot ต่ออายุเองเมื่อเหลือ 30 วัน — ถ้าเหลือไม่ถึง 14 วันแปลว่าการต่ออายุน่าจะมีปัญหา
  const certTone = cert == null ? null : cert <= 0 ? "crit" : cert < 14 ? "warn" : "ok";
  const disk = sys.disk_used_pct;
  $("minis").replaceChildren(
    mini("บริการ", svc.length ? `${svc.length - down.length}/${svc.length}` : "–",
      svc.length ? (down.length ? `หยุด: ${down.join(", ")}` : "ทำงานครบ") : "", svc.length ? (down.length ? "crit" : "ok") : null),
    mini("ใบรับรอง HTTPS", cert != null ? `${cert} วัน` : "–",
      certTone === "ok" ? "ต่ออายุอัตโนมัติ" : certTone ? "ตรวจการต่ออายุ" : "", certTone),
    mini("Disk ใช้ไป", disk != null ? `${disk}%` : "–",
      sys.mem_used_pct != null ? `RAM ${sys.mem_used_pct}%` : "", disk == null ? null : disk >= 90 ? "warn" : "ok"),
    mini("ค่า AI สะสม", usage.est_cost_usd != null ? `$${usage.est_cost_usd.toFixed(2)}` : "–",
      usage.runs ? `${fmt(usage.runs)} รอบ` : ""),
  );

  // AI
  $("ai-meta").textContent = m.model_served
    ? `${m.model_served} · effort ${m.effort} · ${fmt(m.input_tokens)} + ${fmt(m.output_tokens)} token · ~$${(m.est_cost_usd || 0).toFixed(3)} · ${m.seconds}s`
    : (m.error ? "ผิดพลาด — ดูข้อความ error ในการ์ดด้านบน" : "");
  // ไม่มีผล AI: ย่อการ์ดเหลือบรรทัดเดียว แทนหัวข้อว่าง ๆ ที่มีแต่ "—"
  $("ai-card").classList.toggle("no-ai", !f);
  // เรื่องที่ควรแก้ขึ้นก่อน เรื่องที่แค่รับทราบไว้ท้าย แล้วเรียงตามความรุนแรง
  const incs = [...((f && f.incidents) || [])].sort((a, b) =>
    isInfo(a) - isInfo(b) || (SEV_ORDER[a.severity] ?? 9) - (SEV_ORDER[b.severity] ?? 9));
  // การ์ดกระชับ: เห็น "ควรทำ" ทันที ส่วนหลักฐาน/IP พับไว้ (เรื่องที่แค่รับทราบพับทั้งหมด)
  $("incidents").replaceChildren(...(incs.length
    ? incs.map((i) => {
        const info = isInfo(i), ips = (i.source_ips || []).map(ip), key = i.title_th;
        const more = el("details", { class: "inc-more", open: INC_OPEN.has(key) },
          el("summary", {}, info ? "รายละเอียด" : `หลักฐาน${ips.length ? ` · IP ต้นทาง ${ips.length}` : ""}`),
          el("dl", {},
            ips.length ? [el("dt", {}, "IP ต้นทาง"), el("dd", {}, ips.join(", "))] : null,
            el("dt", {}, "หลักฐาน"), el("dd", {}, maskText(i.evidence_th)),
            info ? [el("dt", {}, "ควรทำ"), el("dd", {}, maskText(i.recommended_action_th))] : null));
        more.addEventListener("toggle", () => { if (more.open) INC_OPEN.add(key); else INC_OPEN.delete(key); });
        return el("article", { class: `incident${info ? " info" : ""}` },
          el("div", { class: "row1" }, badge(i.severity),
            info ? el("span", { class: "tag tag-info" }, "รับทราบ") : el("span", { class: "tag tag-todo" }, icon("flag", 12, 2.6), "ควรแก้"),
            el("span", { class: "type" }, INCIDENT_TYPE[i.type] || i.type)),
          el("h4", { class: "title" }, maskText(i.title_th)),
          info ? null : el("p", { class: "inc-action" }, el("span", { class: "inc-k" }, "ควรทำ"), maskText(i.recommended_action_th)),
          more);
      })
    : [f ? allClear("ไม่พบเหตุการณ์ผิดปกติในรอบนี้") : el("p", { class: "empty" }, "—")]));
  $("review").replaceChildren(...(f && (f.ips_to_review || []).length
    ? f.ips_to_review.map((r) => el("li", {}, el("code", {}, ip(r.ip)), " — ", maskText(r.reason_th)))
    : [f ? allClear("ไม่มี IP ที่ต้องตรวจ", "li") : el("li", { class: "empty" }, "—")]));
  $("defenses").replaceChildren(...(f ? (f.defenses_working_th || []).map((t) => el("li", {}, maskText(t))) : []));
  $("ai-notes").textContent = f && f.notes_th ? `หมายเหตุจาก AI: ${maskText(f.notes_th)}` : "";

  drawCharts();

  // attacks — เป็นรายการแทนตาราง 4 คอลัมน์ ที่บนมือถือบีบจนคำแตกหลายบรรทัด
  const atk = Object.entries(ng.attack_patterns || {}).sort(([, a], [, b]) => b.count - a.count);
  $("attacks").replaceChildren(atk.length
    ? el("ul", { class: "atk" }, atk.map(([k, v]) => el("li", {},
        el("div", { class: "atk-head" }, el("span", { class: "atk-name" }, ATTACK_NAME[k] || k), el("span", { class: "atk-count" }, `${fmt(v.count)} ครั้ง`)),
        (v.top_ips || []).length ? el("div", { class: "atk-ips" }, el("span", { class: "muted" }, "IP หลัก "), v.top_ips.map((x) => el("code", {}, ip(x.ip)))) : null,
        (v.samples || [])[0] ? el("code", { class: "atk-sample" }, v.samples[0]) : null)))
    : allClear("ไม่พบรูปแบบการโจมตีใน request ช่วงนี้"));

  $("top-ips").replaceChildren(table(["IP", "ประเทศ", "requests", "4xx"],
    (ng.top_ips || []).slice(0, 8).map((x) => [{ mono: ip(x.ip), nowrap: true }, country(x.country), fmt(x.requests), fmt(x.client_errors)]), [2, 3],
    "ช่วงนี้ไม่มีคนเข้าเว็บ"));

  const ssh = s.ssh, f2b = s.fail2ban;
  const sshRows = [
    ["SSH login สำเร็จ (public key)", fmt(ssh.events.accepted || 0)],
    ["SSH user ที่ไม่มีอยู่จริง", fmt(ssh.events.invalid_user || 0)],
    ["SSH user ที่ไม่ได้รับอนุญาต (เช่น root)", fmt(ssh.events.not_allowed || 0)],
    ["WordPress login (POST)", fmt(ng.wp_login.post_total)],
    ["WordPress login ผิด", fmt(ng.wp_login.failed_total)],
    ...Object.entries(f2b.by_jail || {}).map(([j, c]) => [`fail2ban ${j}: แบน`, fmt(c.Ban || 0)]),
  ];
  const bannedRows = Object.entries(f2b.currently_banned || {}).flatMap(([j, l]) => l.map((x) => [j, { mono: ip(x.ip), nowrap: true }, country(x.country)]));
  const failed = (ssh.events.invalid_user || 0) + (ssh.events.not_allowed || 0) + (ng.wp_login.failed_total || 0);
  $("auth").replaceChildren(...[
    failed ? null : allClear("ไม่มีการเข้าระบบที่ผิดพลาดในช่วงนี้ (SSH และ WordPress)"),
    table(["รายการ", "จำนวน"], sshRows, [1]),
    el("h3", {}, "IP ที่ fail2ban แบนอยู่ตอนนี้"),
    table(["jail", "IP", "ประเทศ"], bannedRows, [], allClear("ไม่มี IP ที่ถูกแบนอยู่ตอนนี้")),
  ].filter(Boolean));

  // บริการเป็นป้ายเรียงกัน (8 แถวในตารางยาวเกินไปบนมือถือ) — ตัวที่หยุดขึ้นก่อน
  const svcSorted = [...svc].sort(([, a], [, b]) => (a === "active") - (b === "active"));
  $("system").replaceChildren(
    svc.length
      ? el("ul", { class: "svc" }, svcSorted.map(([k, v]) => {
          const on = v === "active";
          return el("li", { class: on ? "on" : "off" }, el("span", { class: "dot" }, icon(on ? "check" : "x", 12, 3)),
            k, el("span", { class: on ? "sr-only" : "svc-state" }, on ? " ทำงาน" : ` หยุด (${v})`));
        }))
      : el("p", { class: "empty" }, "ไม่มีข้อมูลบริการ"),
    table(["รายการ", "ค่า"], [
      ["Load (1 นาที)", sys.load_1m != null ? sys.load_1m.toFixed(2) : "–"],
      ["RAM ใช้ไป", sys.mem_used_pct != null ? `${sys.mem_used_pct}%` : "–"],
      ["Disk ใช้ไป", sys.disk_used_pct != null ? `${sys.disk_used_pct}%` : "–"],
      ["ช่วง IP ไทยใน ipset", Object.entries(sys.ipset_entries || {}).map(([k, v]) => `${k}: ${fmt(v)}`).join(" · ")],
      ["Uptime", sys.uptime_hours == null ? "–" : sys.uptime_hours >= 48 ? `${(sys.uptime_hours / 24).toFixed(1)} วัน` : `${sys.uptime_hours} ชม.`],
    ], [1]));

  $("history").replaceChildren(table(["เวลา", "ระดับ", "เหตุการณ์", "บล็อก", "ค่า AI"],
    HISTORY.slice(-10).reverse().map((h) => [{ text: whenShort(h.at), nowrap: true }, h.threat_level ? badge(h.threat_level) : (h.error ? "ผิดพลาด" : "ไม่ใช้ AI"), fmt(h.incidents), fmt(h.geoblock_drops), h.cost_usd ? `$${h.cost_usd.toFixed(3)}` : "–"]), [2, 3, 4], "ยังไม่มีประวัติการสแกน"));
  vizTables();
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

// เมื่อกล่องคำตัดสินเลื่อนพ้นจอ ให้แถบสถานะเลื่อนลงมาจากขอบบน — กดแล้วกลับขึ้นไปดูสรุป
function watchScroll() {
  const bar = $("statusbar");
  if (!bar || !("IntersectionObserver" in window)) return;
  bar.addEventListener("click", () => { $("top").scrollIntoView({ behavior: "smooth" }); });
  new IntersectionObserver(([e]) => {
    const show = !e.isIntersecting && e.boundingClientRect.top < 0;
    bar.classList.toggle("show", show);
    bar.inert = !show;
  }).observe($("hero"));
}

document.addEventListener("DOMContentLoaded", () => {
  watchScroll();
  $("mask").addEventListener("change", (e) => { MASK = e.target.checked; render(); });
  $("reload").addEventListener("click", load);
  // กราฟวาดตามความกว้างจริง จึงต้องวาดใหม่เมื่อความกว้างเปลี่ยน (หมุนจอ / ย่อหน้าต่าง)
  // เทียบเฉพาะความกว้าง — มือถือยิง resize ตอนแถบ address หด/ขยายด้วย
  let lastW = window.innerWidth, timer = 0;
  window.addEventListener("resize", () => {
    clearTimeout(timer);
    timer = setTimeout(() => { if (window.innerWidth !== lastW) { lastW = window.innerWidth; drawCharts(); } }, 150);
  });
  load();
  setInterval(load, 5 * 60 * 1000);
});
