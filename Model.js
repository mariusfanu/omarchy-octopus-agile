// Octopus Agile model — pure logic, no Qt dependencies so it runs under
// `node` for tests as well as inside QML (`import "Model.js" as Model`).

var PRODUCT_FALLBACK = "AGILE-24-10-01";

// Product codes come from the network (discovery) or shell.json (override)
// and are interpolated into the API URL path, so only accept the shape
// Octopus actually uses. Anything else falls back to PRODUCT_FALLBACK.
var PRODUCT_RE = /^AGILE-[A-Z0-9-]{1,40}$/;

// Auto-discovery is stricter still: only dated import products, so that a
// plain string compare picks the newest and a stray code such as
// "AGILE-99-ZZZZ" cannot win and pin the widget to a 404ing tariff.
var DISCOVERY_RE = /^AGILE-\d{2}-\d{2}-\d{2}$/;

// Hard ceiling on slots kept from one response. We request 48h (96 slots);
// this stops a hostile body from fanning out into thousands of chart items.
var MAX_SLOTS = 200;

// Agile settles half-hourly. Accept a little slack either side but reject
// second-long or day-long slots, which would otherwise let one response
// drive a notification per clock tick or stay "current" forever.
var MIN_SLOT_MS = 15 * 60 * 1000;
var MAX_SLOT_MS = 60 * 60 * 1000;

// p/kWh. Real Agile prices sit roughly in -20..100; anything past this is
// garbage and would overflow stats/bar maths into Infinity or NaN.
var MAX_ABS_PRICE = 10000;

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

function isValidProduct(code) {
  return PRODUCT_RE.test(String(code || ""));
}

function normalizeProduct(code, fallback) {
  var c = String(code || "");
  if (isValidProduct(c)) return c;
  var f = String(fallback || "");
  return isValidProduct(f) ? f : PRODUCT_FALLBACK;
}

function parseLatestAgileProduct(raw) {
  try {
    var data = JSON.parse(String(raw || "{}"));
    var results = Array.isArray(data.results) ? data.results : [];
    var best = "";
    for (var i = 0; i < results.length; i++) {
      var code = results[i] && results[i].code;
      if (typeof code !== "string" || !DISCOVERY_RE.test(code)) continue;
      if (code > best) best = code;
    }
    return best;
  } catch (e) {
    return "";
  }
}

function parseRates(raw) {
  try {
    var data = JSON.parse(String(raw || "{}"));
    var results = Array.isArray(data.results) ? data.results : [];
    var out = [];
    for (var i = 0; i < results.length; i++) {
      var r = results[i];
      // Type-check before coercing so one malformed row (e.g. an object
      // with a non-callable toString) is skipped instead of throwing out
      // of the loop and discarding the whole response.
      if (!r || typeof r !== "object") continue;
      if (typeof r.valid_from !== "string" || typeof r.valid_to !== "string") continue;
      var v = r.value_inc_vat;
      if (typeof v !== "string" && typeof v !== "number") continue;
      var fromMs = Date.parse(r.valid_from);
      var toMs = Date.parse(r.valid_to);
      var price = parseFloat(v);
      if (!isFinite(fromMs) || !isFinite(toMs) || !isFinite(price)) continue;
      var span = toMs - fromMs;
      if (span < MIN_SLOT_MS || span > MAX_SLOT_MS) continue;
      if (Math.abs(price) > MAX_ABS_PRICE) continue;
      out.push({
        fromMs: fromMs,
        toMs: toMs,
        fromIso: r.valid_from,
        toIso: r.valid_to,
        price: price
      });
    }
    out.sort(function(a, b) { return a.fromMs - b.fromMs; });
    // Drop duplicates and overlaps: keep the earliest slot in any clash.
    var clean = [];
    for (var j = 0; j < out.length && clean.length < MAX_SLOTS; j++) {
      if (clean.length > 0 && out[j].fromMs < clean[clean.length - 1].toMs) continue;
      clean.push(out[j]);
    }
    return clean;
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

function cheapestWindow(rates, slots, fromMs) {
  var list = rates || [];
  var n = parseInt(slots, 10);
  if (!(n > 0) || list.length < n) return null;
  var start = (fromMs === undefined || fromMs === null) ? -Infinity : fromMs;
  var best = null;
  var bestAvg = Infinity;
  for (var i = 0; i + n <= list.length; i++) {
    if (list[i].fromMs < start) continue;
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
  var s = n.toFixed(1);
  if (s === "-0.0") s = "0.0";
  return s + "p";
}

function isOn(value, fallback) {
  if (value === undefined || value === null || value === "") return fallback === true;
  if (value === false || value === 0 || value === "0" || value === "false" || value === "off" || value === "Off")
    return false;
  if (value === true || value === 1 || value === "1" || value === "true" || value === "on" || value === "On")
    return true;
  return fallback === true;
}

function priceTrend(currentPrice, nextPrice) {
  var c = parseFloat(currentPrice);
  var n = parseFloat(nextPrice);
  if (isNaN(c) || isNaN(n)) return "unknown";
  if (c.toFixed(1) === n.toFixed(1)) return "flat";
  return n > c ? "up" : "down";
}

function trendArrow(trend) {
  if (trend === "up") return "↑";
  if (trend === "down") return "↓";
  return "";
}

function pillLabel(currentPrice, nextPrice, showTrend, loading) {
  if (currentPrice === undefined || currentPrice === null || currentPrice === "")
    return loading ? " …" : " —";
  var text = " " + formatPrice(currentPrice);
  if (showTrend) {
    var arrow = trendArrow(priceTrend(currentPrice, nextPrice));
    if (arrow) text += " " + arrow;
  }
  return text;
}

function clampInt(value, fallback, min, max) {
  var n = parseInt(value, 10);
  if (isNaN(n)) n = fallback;
  if (n < min) n = min;
  if (n > max) n = max;
  return n;
}

function nextNotifiableSlot(rates, nowMs, leadMs, below) {
  var list = rates || [];
  var lead = Number(leadMs);
  var cap = parseFloat(below);
  if (!(lead > 0) || isNaN(cap)) return null;
  var latest = nowMs + lead;
  var best = null;
  for (var i = 0; i < list.length; i++) {
    var s = list[i];
    if (!s || s.fromMs <= nowMs || s.fromMs > latest) continue;
    var p = parseFloat(s.price);
    if (isNaN(p)) continue;
    if (p >= 0 && p >= cap) continue;
    if (!best || s.fromMs < best.fromMs) best = s;
  }
  return best;
}

function pad2(n) {
  return (n < 10 ? "0" : "") + n;
}

function formatTime(ms) {
  var d = new Date(ms);
  return pad2(d.getHours()) + ":" + pad2(d.getMinutes());
}

function formatRange(startMs, endMs) {
  return formatTime(startMs) + "–" + formatTime(endMs);
}

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
    MAX_SLOTS: MAX_SLOTS,
    MIN_SLOT_MS: MIN_SLOT_MS,
    MAX_SLOT_MS: MAX_SLOT_MS,
    MAX_ABS_PRICE: MAX_ABS_PRICE,
    REGIONS: REGIONS,
    isValidProduct: isValidProduct,
    normalizeProduct: normalizeProduct,
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
    isOn: isOn,
    priceTrend: priceTrend,
    trendArrow: trendArrow,
    pillLabel: pillLabel,
    clampInt: clampInt,
    nextNotifiableSlot: nextNotifiableSlot,
    formatTime: formatTime,
    formatRange: formatRange,
    barHeight: barHeight,
    tariffCode: tariffCode
  };
}
