// Static checks for index.html: JSON, JS syntax, dead links, stale facts, stale copy.
// Usage: node site/check_site.mjs   (exit code 1 when anything fails)
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";

const ROOT = path.resolve(import.meta.dirname, "..");
const html = readFileSync(path.join(ROOT, "index.html"), "utf8");

const failures = [];
const fails = (msg) => failures.push(msg);
const ok = (label) => console.log(`ok    ${label}`);

const scripts = [...html.matchAll(/<script([^>]*)>([\s\S]*?)<\/script>/g)].map(
  ([, attrs, body]) => ({
    id: (attrs.match(/\bid="([^"]+)"/) || [])[1] || "",
    type: (attrs.match(/\btype="([^"]+)"/) || [])[1] || "",
    body,
  }),
);

// 1. JSON blocks
const jsonBlocks = new Map();
for (const s of scripts.filter((s) => s.type === "application/json")) {
  try {
    jsonBlocks.set(s.id, JSON.parse(s.body));
  } catch (err) {
    if (s.id === "live-data" || s.id === "site-facts") {
      if (!/__(LIVE_DATA|SITE_FACTS)__/.test(s.body)) fails(`#${s.id}: ${err.message}`);
    } else {
      fails(`#${s.id}: not valid JSON (${err.message})`);
    }
  }
}
const facts = jsonBlocks.get("site-facts-fallback");
if (!facts) fails("missing #site-facts-fallback");
else ok(`site-facts-fallback parses (${Object.keys(facts).length} facts)`);

for (const id of ["live-data", "site-facts"]) {
  if (!scripts.some((s) => s.id === id)) fails(`missing #${id} script block`);
}
ok("live-data and site-facts placeholders present");

// 2. Main script compiles
const main = scripts.find((s) => s.type !== "application/json");
if (!main) fails("no inline application script found");
else {
  try {
    new Function(main.body);
    ok("inline script parses");
  } catch (err) {
    fails(`inline script: ${err.message}`);
  }
}

// 3. Every fact the page reads exists in the fallback JSON
const read = new Set();
if (main) {
  for (const m of main.body.matchAll(/(?:FACTS|num)\(\s*['"]([^'"]+)['"]\s*\)/g)) read.add(m[1]);
  for (const m of main.body.matchAll(/FACTS\[\s*['"]([^'"]+)['"]\s*\]/g)) read.add(m[1]);
}
for (const m of html.matchAll(/data-fact="([^"]+)"/g)) read.add(m[1]);
const missing = [...read].filter((k) => !(k in (facts || {}))).sort();
if (missing.length) fails(`facts referenced but not defined: ${missing.join(", ")}`);
else ok(`all ${read.size} referenced facts are defined`);

// 4. Local href/src targets exist
const skip = /^(#|https?:|mailto:|data:|javascript:)/;
const targets = new Set();
for (const m of html.matchAll(/\b(?:href|src)="([^"]+)"/g)) {
  if (!skip.test(m[1])) targets.add(m[1].split("#")[0]);
}
const dead = [...targets].filter((t) => t && !existsSync(path.join(ROOT, t)));
if (dead.length) fails(`dead local links: ${dead.join(", ")}`);
else ok(`all ${targets.size} local links resolve`);

// 5. In-page anchors exist
const ids = new Set([...html.matchAll(/\bid="([^"]+)"/g)].map((m) => m[1]));
const anchors = [...html.matchAll(/\bhref="#([^"]+)"/g)].map((m) => m[1]);
const badAnchors = [...new Set(anchors.filter((a) => !ids.has(a)))];
if (badAnchors.length) fails(`anchors with no target: ${badAnchors.join(", ")}`);
else ok(`all ${new Set(anchors).size} anchors resolve`);

// 6. Every `make <target>` used on the page exists in the Makefile
const makefile = readFileSync(path.join(ROOT, "Makefile"), "utf8");
const known = new Set(
  [...makefile.matchAll(/^([A-Za-z0-9_-]+):/gm)].map((m) => m[1]),
);
const used = new Set([...html.matchAll(/\bmake ([A-Za-z0-9_-]+)/g)].map((m) => m[1]));
const unknownMake = [...used].filter((t) => !known.has(t)).sort();
if (unknownMake.length) fails(`make targets not in Makefile: ${unknownMake.join(", ")}`);
else ok(`all ${used.size} make targets exist`);

// 7. Copy from the previous project must not survive the rebrand
const stale = [
  ["Fleet dbt Warehouse", /Fleet dbt/],
  ["old repository", /Fleet-dbt-warehouse/],
  ["dbt", /\bdbt\b/],
  ["bronze/silver/gold", /\b(bronze|silver)\b/],
  ["Kafka streaming", /\bKafka\b/],
  ["fleet sources", /fleet_registry|fleet_operations/],
];
const staleHit = stale.filter(([, re]) => re.test(html)).map(([label]) => label);
if (staleHit.length) fails(`stale copy still present: ${staleHit.join(", ")}`);
else ok("no stale copy from the previous project");

console.log("");
if (failures.length) {
  for (const f of failures) console.error(`FAIL  ${f}`);
  process.exit(1);
}
console.log("index.html checks passed");
