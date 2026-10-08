#!/usr/bin/env node
// Baselines on the test split, so a trained model has something to beat.
//
//   node datasets/barmade-forecast/evaluate.mjs [--data out] [--predictions my_preds.csv]
//
// Baselines:
//   usage      14-day trailing average (what the BarMade API's /api/inventory/forecast does)
//              and 7-day trailing average -> next-7-day usage
//   run-out    closing_stock / avg_usage_14d -> days_to_runout; runout_within_7d as a classifier
//   ready time the iOS ReadyTimeModel prior (p50) and its p75/p90 band -> coverage
//
// --predictions: a CSV with columns date,ingredient_id,usage_next_7d_pred[,days_to_runout_pred]
// is scored with the same metrics next to the baselines.

import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const args = Object.fromEntries(process.argv.slice(2).map((a, i, all) => (a.startsWith("--") ? [a.slice(2), all[i + 1]] : [])).filter((x) => x.length));
const DATA = resolve(args.data ?? join(here, "out"));

function readCsv(path) {
  const [head, ...lines] = readFileSync(path, "utf8").trim().split("\n");
  const cols = head.split(",");
  return lines.map((l) => {
    const vals = [];
    let cur = "", q = false;
    for (const ch of l) {
      if (ch === '"') q = !q;
      else if (ch === "," && !q) { vals.push(cur); cur = ""; }
      else cur += ch;
    }
    vals.push(cur);
    return Object.fromEntries(cols.map((c, i) => [c, vals[i] === "" ? null : isNaN(Number(vals[i])) ? vals[i] : Number(vals[i])]));
  });
}

const splits = JSON.parse(readFileSync(join(DATA, "splits.json"), "utf8"));
const inTest = (date) => date >= splits.test.from && date <= splits.test.to;
const daily = readCsv(join(DATA, "inventory_daily.csv")).filter((r) => inTest(r.date));
const kitchen = readCsv(join(DATA, "kitchen_times.csv")).filter((r) => inTest(r.business_date) && !r.cancelled);

const mean = (xs) => xs.reduce((a, b) => a + b, 0) / xs.length;
const mae = (pairs) => mean(pairs.map(([a, b]) => Math.abs(a - b)));
const fmt = (n, d = 2) => Number(n).toFixed(d);

console.log(`Test split ${splits.test.from}..${splits.test.to}: ${daily.length} ingredient-days, ${kitchen.length} kitchen timings\n`);

// ---- usage forecast ----------------------------------------------------------------
const usageRows = daily.filter((r) => r.usage_next_7d !== null);
const scoreUsage = (name, pred) => {
  const pairs = usageRows.map((r) => [pred(r), r.usage_next_7d]);
  // Scale-free: error relative to each ingredient's typical weekly usage.
  const wape = pairs.reduce((s, [p, y]) => s + Math.abs(p - y), 0) / pairs.reduce((s, [, y]) => s + Math.abs(y), 0);
  console.log(`  ${name.padEnd(34)} MAE ${fmt(mae(pairs), 1).padStart(8)} units/7d   WAPE ${fmt(wape * 100, 1)}%`);
};
console.log("Next-7-day usage per ingredient:");
scoreUsage("14-day average (BarMade API)", (r) => r.avg_usage_14d * 7);
scoreUsage("7-day average", (r) => r.avg_usage_7d * 7);
// Note: "same weekdays last week" summed over 7 days is the 7-day average again; a
// weekday-aware model has to beat that by predicting *which* days are heavy, not the total.

// ---- run-out ------------------------------------------------------------------------
const runRows = daily.filter((r) => r.days_to_runout !== null);
const toDays = (v) => (v === "30+" ? 30 : v);
const scoreRunout = (name, predDays) => {
  const pairs = runRows.map((r) => [Math.min(30, predDays(r)), toDays(r.days_to_runout)]);
  let tp = 0, fp = 0, fn = 0;
  for (const r of runRows) {
    const p = Math.min(30, predDays(r)) <= 7, y = r.runout_within_7d === 1;
    if (p && y) tp++; else if (p && !y) fp++; else if (!p && y) fn++;
  }
  const prec = tp / Math.max(1, tp + fp), rec = tp / Math.max(1, tp + fn);
  console.log(`  ${name.padEnd(34)} MAE ${fmt(mae(pairs), 1)} days   run-out≤7d precision ${fmt(prec * 100, 0)}% recall ${fmt(rec * 100, 0)}%  (${runRows.filter((r) => r.runout_within_7d === 1).length} positives)`);
};
console.log("\nDays until run-out (no further deliveries):");
scoreRunout("stock / 14-day average (API)", (r) => (r.avg_usage_14d > 0 ? r.closing_stock / r.avg_usage_14d : 30));
scoreRunout("stock / 7-day average", (r) => (r.avg_usage_7d > 0 ? r.closing_stock / r.avg_usage_7d : 30));

// ---- expiry / waste ------------------------------------------------------------------
const wasteRows = daily.filter((r) => r.waste_next_7d !== null);
const wastePairs = wasteRows.map((r) => [Math.max(0, r.expiring_within_7d_qty - r.avg_usage_7d * 7), r.waste_next_7d]);
console.log("\nWaste in the next 7 days:");
console.log(`  ${"expiring − 7d usage (naive)".padEnd(34)} MAE ${fmt(mae(wastePairs), 1)} units   (actual mean ${fmt(mean(wasteRows.map((r) => r.waste_next_7d)), 1)})`);

// ---- ready time ------------------------------------------------------------------------
const prior = (r) => {
  const items = Math.max(1, r.item_count);
  if (r.prep_prior_min <= 3) return Math.max(0.5, r.prep_prior_min + 0.5 * (items - 1));
  return r.prep_prior_min + 1.2 * items + 1.8 * r.busy_open_tickets + (r.is_rush ? 2 : 0) + (r.is_weekend ? 1 : 0);
};
const honest = kitchen.filter((r) => !r.forgotten);
const p50 = honest.map((r) => [Math.max(1, prior(r)), r.minutes_to_ready]);
const cover = (q) => mean(honest.map((r) => (r.minutes_to_ready <= Math.max(1, prior(r)) * (1 + q.spread) + q.add ? 1 : 0)));
console.log("\nKitchen ready time (forgotten tickets excluded):");
console.log(`  ${"iOS prior p50".padEnd(34)} MAE ${fmt(mae(p50), 2)} min   p75 band covers ${fmt(cover({ spread: 0.25, add: 1 }) * 100, 0)}%   p90 band covers ${fmt(cover({ spread: 0.5, add: 2 }) * 100, 0)}%`);
console.log(`  forgotten tickets in test: ${kitchen.length - honest.length} (label \`forgotten\`; exclude or detect)`);

// The iPhone's learned model: ReadyTimeModel.fit, ported from Swift. Fitted on the
// kitchen's last 14 days of tickets before each day (what the app sees on the API),
// including forgotten ones under 90 min, exactly as the app does.
const allKitchen = readCsv(join(DATA, "kitchen_times.csv")).filter((r) => !r.cancelled);
const median = (xs) => { const s = [...xs].sort((a, b) => a - b); return s.length % 2 ? s[(s.length - 1) / 2] : (s[s.length / 2 - 1] + s[s.length / 2]) / 2; };
function fit(samples) {
  const usable = samples.filter((s) => s.expected > 0 && s.minutes >= 0.5 && s.minutes <= 90);
  const m = { kitchenFactor: 1, spread: 0.25, n: usable.length };
  if (!usable.length) return m;
  const n = usable.length, K = 5;
  const ratios = usable.map((s) => s.minutes / s.expected);
  const med = median(ratios);
  m.kitchenFactor = (n * med + K) / (n + K);
  const mad = median(ratios.map((x) => Math.abs(x - med))) * 1.4826;
  m.spread = Math.min(0.6, Math.max(0.15, (n * mad + K * 0.25) / (n + K)));
  return m;
}
const learnedPredict = (m, r) => {
  const q50 = Math.max(1, prior(r) * m.kitchenFactor);
  return { p50: q50, p75: q50 * (1 + m.spread) + 1, p90: q50 * (1 + 2 * m.spread) + 2 };
};
function scoreLearned(label, rows, windowDays = 14) {
  const byDate = new Map();
  for (const r of allKitchen) (byDate.get(r.business_date) ?? byDate.set(r.business_date, []).get(r.business_date)).push(r);
  const dates = [...byDate.keys()].sort();
  const cache = new Map();
  const modelFor = (date) => {
    if (cache.has(date)) return cache.get(date);
    const i = dates.indexOf(date);
    const window = dates.slice(Math.max(0, i - windowDays), i).flatMap((d) => byDate.get(d));
    const m = fit(window.map((r) => ({ minutes: r.minutes_to_ready, expected: prior(r) })));
    cache.set(date, m);
    return m;
  };
  const target = rows.filter((r) => !r.forgotten);
  const pri = target.map((r) => [Math.max(1, prior(r)), r.minutes_to_ready]);
  const lrn = target.map((r) => [learnedPredict(modelFor(r.business_date), r).p50, r.minutes_to_ready]);
  const cov = (q) => mean(target.map((r) => (r.minutes_to_ready <= learnedPredict(modelFor(r.business_date), r)[q] ? 1 : 0)));
  console.log(`  ${label.padEnd(34)} prior MAE ${fmt(mae(pri), 2)} → learned MAE ${fmt(mae(lrn), 2)} min   learned p75 covers ${fmt(cov("p75") * 100, 0)}%  p90 ${fmt(cov("p90") * 100, 0)}%   (${target.length} tickets)`);
}
const valRows = allKitchen.filter((r) => r.business_date >= splits.val.from && r.business_date <= splits.val.to);
const afterSlow = valRows.filter((r) => r.kitchen_factor === 1 && r.business_date > valRows.find((x) => x.kitchen_factor > 1)?.business_date);
for (const w of [3, 7, 14, 28]) {
  console.log(`\nKitchen ready time — the iPhone's learned model, rolling ${w}-day fit:`);
  scoreLearned("test split (normal kitchen)", honest, w);
  scoreLearned("slow-cook weeks (val split)", valRows.filter((r) => r.kitchen_factor > 1), w);
  scoreLearned("2 weeks after the kitchen recovers", afterSlow.slice(0, Math.round(afterSlow.length * 14 / 28)), w);
}

// ---- your predictions -------------------------------------------------------------------
if (args.predictions) {
  const preds = new Map(readCsv(resolve(args.predictions)).map((p) => [`${p.date}|${p.ingredient_id}`, p]));
  console.log(`\nYour predictions (${args.predictions}):`);
  const have = (r) => preds.get(`${r.date}|${r.ingredient_id}`);
  if (usageRows.some(have)) {
    const pairs = usageRows.filter(have).map((r) => [have(r).usage_next_7d_pred, r.usage_next_7d]);
    const wape = pairs.reduce((s, [p, y]) => s + Math.abs(p - y), 0) / pairs.reduce((s, [, y]) => s + Math.abs(y), 0);
    console.log(`  ${"usage_next_7d_pred".padEnd(34)} MAE ${fmt(mae(pairs), 1).padStart(8)} units/7d   WAPE ${fmt(wape * 100, 1)}%  (${pairs.length} rows)`);
  }
  if (runRows.some((r) => have(r)?.days_to_runout_pred != null)) {
    scoreRunout("days_to_runout_pred", (r) => have(r)?.days_to_runout_pred ?? 30);
  }
}
