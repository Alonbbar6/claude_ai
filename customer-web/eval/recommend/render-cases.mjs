#!/usr/bin/env node
// Renders cases.json as cases.md for human review (table + one section per case).
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const { cases, _about } = JSON.parse(readFileSync(join(here, "cases.json"), "utf8"));

const fence = (s) => {
  const longest = Math.max(2, ...[...String(s).matchAll(/`+/g)].map((m) => m[0].length));
  const f = "`".repeat(longest + 1);
  return `${f}\n${s}\n${f}`;
};
const exp = (e) =>
  [
    e.max_price != null ? `price < $${e.max_price}` : null,
    e.must_include?.length ? `must include ${e.must_include.join(", ")}` : null,
    e.must_not_include?.length ? `must not include ${e.must_not_include.join(", ")}` : null,
    `special: ${e.special}`,
  ].filter(Boolean).join("; ");

const counts = {};
for (const c of cases) for (const t of c.tags) counts[t] = (counts[t] ?? 0) + 1;

let md = `# Picked-for-you eval: proposed inputs (${cases.length} cases)\n\n${_about}\n\n`;
md += `Tag counts: ${Object.entries(counts).map(([k, v]) => `${k} ${v}`).join(" · ")}\n\n`;
md += `| id | tags | input | menu override | programmatic expectations |\n|---|---|---|---|---|\n`;
for (const c of cases) {
  const i = c.input;
  const input = `likes [${i.likes.join(", ")}] avoid [${i.avoid.join(", ")}]${i.craving ? ` craving "${i.craving.replace(/\|/g, "\\|")}"` : ""} ${i.lang}`;
  const menu = Object.keys(c.menu).length ? JSON.stringify(c.menu) : "real menu";
  md += `| ${c.id} | ${c.tags.join(", ")} | ${input} | ${menu} | ${exp(c.expected)} |\n`;
}
md += `\n`;
for (const c of cases) {
  md += `## ${c.id}\n\nTags: ${c.tags.join(", ")}\n\nInput sent to the app:\n\n${fence(JSON.stringify(c.input, null, 2))}\n\n`;
  if (Object.keys(c.menu).length) md += `Menu override: ${fence(JSON.stringify(c.menu))}\n\n`;
  md += `Expectations: ${exp(c.expected)}\n\nJudge guidance: ${c.expected.notes}\n\n`;
}
writeFileSync(join(here, "cases.md"), md);
console.log(`wrote cases.md (${cases.length} cases)`);
