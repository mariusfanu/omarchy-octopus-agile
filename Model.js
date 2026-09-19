// Octopus Agile model — pure logic, no Qt dependencies so it runs under
// `node` for tests as well as inside QML (`import "Model.js" as Model`).

var PRODUCT_FALLBACK = "AGILE-24-10-01";

var REGIONS = [
  { value: "A", label: "A – East England" },
  { value: "B", label: "B – East Midlands" },
  { value: "C", label: "C – London" },
  { value: "D", label: "D – Merseyside & N Wales" },
  { value: "E", label: "E – West Midlands" },
  { value: "F", label: "F – North East England" },
  { value: "G", label: "G – North West England" },
  { value: "H", label: "H – Southern England" },
  { value: "J", label: "J – South East England" },
  { value: "K", label: "K – South Wales" },
  { value: "L", label: "L – South West England" },
  { value: "M", label: "M – Yorkshire" },
  { value: "N", label: "N – South Scotland" },
  { value: "P", label: "P – North Scotland" }
];

function regionLabel(code) {
  var c = String(code || "").toUpperCase();
  for (var i = 0; i < REGIONS.length; i++) {
    if (REGIONS[i].value === c) return REGIONS[i].label;
  }
  return String(code || "");
}

function isValidRegion(code) {
  var c = String(code || "").toUpperCase();
  for (var i = 0; i < REGIONS.length; i++) {
    if (REGIONS[i].value === c) return true;
  }
  return false;
}

function normalizeRegion(code, fallback) {
  var c = String(code || "").toUpperCase();
  if (isValidRegion(c)) return c;
  var f = String(fallback || "C").toUpperCase();
  if (isValidRegion(f)) return f;
  return "C";
}

// Latest AGILE import product from /v1/products/ (filters out
// AGILE-OUTGOING, AGILE-BB, etc). Returns "" when unparseable.
function parseLatestAgileProduct(raw) {
  try {
    var data = JSON.parse(String(raw || "{}"));
    var results = data.results || [];
    var best = "";
    for (var i = 0; i < results.length; i++) {
      var code = String(results[i] && results[i].code || "");
      if (!/^AGILE-\d/.test(code)) continue;
      if (code.indexOf("OUTGOING") >= 0 || code.indexOf("BB-") >= 0) continue;
      if (code > best) best = code;
    }
    return best;
  } catch (e) {
    return "";
  }
}

// Parse /standard-unit-rates/ response into ascending slots:
// [{ fromMs, toMs, fromIso, toIso, price }]
function parseRates(raw) {
  try {
    var data = JSON.parse(String(raw || "{}"));
    var results = data.results || [];
    var out = [];
    for (var i = 0; i < results.length; i++) {
      var r = results[i];
      if (!r || !r.valid_from || !r.valid_to) continue;
      var fromMs = Date.parse(r.valid_from);
      var toMs = Date.parse(r.valid_to);
      var price = parseFloat(r.value_inc_vat);
      if (isNaN(fromMs) || isNaN(toMs) || isNaN(price)) continue;
      out.push({
        fromMs: fromMs,
        toMs: toMs,
        fromIso: String(r.valid_from),
        toIso: String(r.valid_to),
        price: price
      });
    }
    out.sort(function(a, b) { return a.fromMs - b.fromMs; });
    return out;
  } catch (e) {
    return [];
  }
}

function findCurrent(rates, nowMs) {
  var list = rates || [];
  for (var i = 0; i < list.length; i++) {
    if (list[i].fromMs <= nowMs && nowMs < list[i].toMs) return list[i];
  }
  return null;
}

function findNext(rates, nowMs) {
  var list = rates || [];
  var best = null;
  for (var i = 0; i < list.length; i++) {
    if (list[i].fromMs > nowMs && (!best || list[i].fromMs < best.fromMs)) best = list[i];
  }
  return best;
}

// Cheapest consecutive window of `slots` half-hour slots at/after fromMs.
// Returns { startMs, endMs, avg, min, max, slots } or null.
function cheapestWindow(rates, slots, fromMs) {
  var list = rates || [];
  var n = parseInt(slots, 10);
  if (!(n > 0) || list.length < n) return null;
  var start = (fromMs === undefined || fromMs === null) ? -Infinity : fromMs;
  var best = null;
  var bestAvg = Infinity;
  for (var i = 0; i + n <= list.length; i++) {
    if (list[i].fromMs < start) continue;
    // Require contiguity (30-min slots back to back).
    var contiguous = true;
    var sum = 0;
    var min = Infinity;
    var max = -Infinity;
    for (var j = 0; j < n; j++) {
      var s = list[i + j];
      if (j > 0 && s.fromMs !== list[i + j - 1].toMs) { contiguous = false; break; }
      sum += s.price;
      if (s.price < min) min = s.price;
      if (s.price > max) max = s.price;
    }
    if (!contiguous) continue;
    var avg = sum / n;
    if (avg < bestAvg) {
      bestAvg = avg;
      best = {
        startMs: list[i].fromMs,
        endMs: list[i + n - 1].toMs,
        avg: avg,
        min: min,
        max: max,
        slots: list.slice(i, i + n)
      };
    }
  }
  return best;
}

function cheapestWindows(rates, nowMs) {
  return {
    h1: cheapestWindow(rates, 2, nowMs),
    h2: cheapestWindow(rates, 4, nowMs),
    h3: cheapestWindow(rates, 6, nowMs)
  };
}

function stats(rates) {
  var list = rates || [];
  if (list.length === 0) return { min: 0, max: 0, avg: 0, count: 0 };
  var min = Infinity, max = -Infinity, sum = 0;
  for (var i = 0; i < list.length; i++) {
    var p = list[i].price;
    if (p < min) min = p;
    if (p > max) max = p;
    sum += p;
  }
  return { min: min, max: max, avg: sum / list.length, count: list.length };
}

function levelForPrice(price) {
  var p = parseFloat(price);
  if (isNaN(p)) return "unknown";
  if (p < 0) return "plunge";
  if (p < 10) return "cheap";
  if (p < 18) return "moderate";
  if (p < 25) return "high";
  return "peak";
}

function colorForPrice(price) {
  var level = levelForPrice(price);
  if (level === "plunge") return "#22d3ee";
  if (level === "cheap") return "#4ade80";
  if (level === "moderate") return "#a3e635";
  if (level === "high") return "#facc15";
  if (level === "peak") return "#f87171";
  return "#9ca3af";
}

function formatPrice(p) {
  if (p === undefined || p === null || p === "") return "—";
  var n = parseFloat(p);
  if (isNaN(n)) return "—";
  return n.toFixed(1) + "p";
}

function pad2(n) {
  return (n < 10 ? "0" : "") + n;
}

// Local HH:MM for epoch ms (used in node tests; QML prefers Qt.formatDateTime).
function formatTime(ms) {
  var d = new Date(ms);
  return pad2(d.getHours()) + ":" + pad2(d.getMinutes());
}

function formatRange(startMs, endMs) {
  return formatTime(startMs) + "–" + formatTime(endMs);
}

// 0..1 bar height for chart, floored so tiny/negative values stay visible.
function barHeight(price, min, max) {
  var lo = parseFloat(min), hi = parseFloat(max), p = parseFloat(price);
  if (isNaN(lo) || isNaN(hi) || isNaN(p)) return 0.1;
  if (hi <= lo) return 0.5;
  var span = hi - lo;
  var h = (p - lo) / span;
  if (h < 0.08) h = 0.08;
  if (h > 1) h = 1;
  return h;
}

function tariffCode(product, region) {
  return "E-1R-" + product + "-" + String(region || "C").toUpperCase();
}

if (typeof module !== "undefined") {
  module.exports = {
    PRODUCT_FALLBACK: PRODUCT_FALLBACK,
    REGIONS: REGIONS,
    regionLabel: regionLabel,
    isValidRegion: isValidRegion,
    normalizeRegion: normalizeRegion,
    parseLatestAgileProduct: parseLatestAgileProduct,
    parseRates: parseRates,
    findCurrent: findCurrent,
    findNext: findNext,
    cheapestWindow: cheapestWindow,
    cheapestWindows: cheapestWindows,
    stats: stats,
    levelForPrice: levelForPrice,
    colorForPrice: colorForPrice,
    formatPrice: formatPrice,
    formatTime: formatTime,
    formatRange: formatRange,
    barHeight: barHeight,
    tariffCode: tariffCode
  };
}
