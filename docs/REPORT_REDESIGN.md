# Report redesign: dense, designed PDFs

Guide for agents. Scope: the look, layout and information density of `report.pdf`,
`incident.pdf` and `weekly.pdf`, plus the data fixes that make the numbers on the page
trustworthy. Place this file in `docs/`.

Read `AGENTS.md` first, then `docs/REPORTING.md`. Those win on any conflict. This page changes
the presentation, not the safety contract. Delivery (the Airflow task, the mail attachment,
file names, run folders) is covered by `docs/REPORT_FIX_GUIDE.md` and is out of scope here.

## 1. Why this exists

The team's feedback: the PDFs look basic, show one thing per page, waste space and need a
rebuild that looks good and shows more in one go. They must stay dynamic: the report is built
by Airflow when a run finishes and is attached to the summary mail, and any minor or major
event changes what it shows.

Do the data fixes in section 2.1 before any visual work. A better looking report that prints
a false green cell is worse than the current one.

## 2. Audit of the current output

Reviewed samples: `incident.pdf` (fixture `critical_failed_run`), `report.pdf` (fixture
`healthy`) and `weekly.pdf` (the file actually holds an incident report, see D10).

### 2.1 Data and logic defects, fix first

| ID | What the PDF shows | Why it is wrong | Expected |
| --- | --- | --- | --- |
| D1 | critical_failed_run: page one `Tables ok 1/5, 2 failed, 2 skipped`, attention says `7 of 10 tables failed`, appendix says `3 succeeded, 7 failed, 0 skipped`. healthy: page one `5/6, 1 skipped`, appendix `10 succeeded, 0 failed, 0 skipped`, Volumes lists 6 tables. major_dq_fail: page one `2/5, 2 failed, 1 skipped`, appendix `8 succeeded, 2 failed, 0 skipped` | page one counts a subset of tables, the appendix counts the run | one definition, one source, the same numbers on every page |
| D2 | healthy: `Rows landed 54 500`, which is raw 2 500 plus staging 1 000 plus analytics 1 000 plus publish 50 000. major_dq_fail: KPI says `2 000` while R009 on the same report says `rows_landed=22500` | the same rows are counted once per layer, and the KPI and the rule use different definitions | one named definition per number, shared by the KPI and the rule |
| D3 | major_dq_fail: the DQ heatmap shows PASS for `12_lp_check_derived_attributes.sql` in analytics. The table below and rule R003 say FAIL with 12 violations. The heatmap also shows a WARNING for `01_lp_check_row_counts.sql` on marts that the table omits, and the KPI counts 3 checks | a false green, which breaks rule 6 of `docs/REPORTING.md` | heatmap, table, KPI, event and banner all derive from the same list of checks |
| D4 | major_dq_fail: the flow shows `marts_load`, `marts_tests` and `publish` as not run (`-`) but the timeline draws bars for them. Every bar starts at 0 although the axis says `seconds from run start` | the chart draws steps with no evidence and is a duration chart, not a timeline. Parallel extracts are not shown as parallel | bars only for steps with audit evidence, real start and end offsets |
| D5 | critical_failed_run: chapter 4 Data Quality prints `section unavailable, the source section raised`, while the appendix says the degraded section is `freshness`, which this kind does not render | DQ is empty because the run died at `extract_mongo`. That is "no gate ran", not a collection error | a separate idle state that names the reason |
| D6 | healthy and major_dq_fail: `no data for this section` prints at page scale on the Incidents chapter directly above an event table that has rows | a chart placeholder is printed over populated content | no placeholder when the chapter has content |
| D7 | healthy: the freshness bullet chart has three bars and no table names, the volumes dumbbell has no row labels, source versus landed lists `customers` twice (raw and staging) with no layer | unlabeled charts cannot be read | every row labeled `layer.table` |
| D8 | critical_failed_run: two identical MINOR `attempt_number=2` lines with no table name. The same runbook anchor prints five times and wraps mid word | the attention block drops the subject and repeats noise | grouped events with subjects, one runbook pointer per distinct action |
| D9 | `53% vs median` on a run that was 53 percent shorter than the median | the sign is lost | `-53%` or `+22%` with the median value |
| D10 | the uploaded `weekly.pdf` says `Report kind incident` and regenerates with `--fixture major_dq_fail`. Incident reports print `--kind daily` in the regeneration command | verify: either the wrong file was uploaded, or the latest copies overwrite each other. The regeneration helper ignores the kind | check `paths.latest_pdf` and the `--all-fixtures` order, and print the real kind |

### 2.2 Design defects

- Page one is a plain stack of four equal cards, a table and a list. Nothing leads the eye and
  the lower third is empty.
- Pages are mostly white. critical_failed_run page 3 is one chart with a single bar and
  `0.0 to 1.0` ticks on a count axis. A healthy daily report runs six pages, while the spec
  says a healthy night fits page one plus the appendix.
- The flow diagram is one narrow column in major_dq_fail: extract nodes hide behind chain
  nodes and arrows cross diagonally. In critical_failed_run it prints as a plain list.
- Chart type sizes disagree: the layer bar chart is scaled up next to a tiny dumbbell, so the
  figures are not made at final printed size.
- Volumes shows the same six numbers four ways: dumbbell, layer bars, source versus landed
  bars and a table.
- The dumbbell draws one dashed line at the run level median (about 54 000) across tables
  that hold 1 000 rows each, so the scale is meaningless.
- The appendix lists open issues as a bare path.

## 3. Design direction

Subject: the nightly operations report of a banking data pipeline. Audience: the engineer who
opens the mail first thing in the morning, then the team lead who skims it. Job of page one:
say in ten seconds whether to act. Job of the later pages: give the evidence.

The memorable parts are the verdict line and the pipeline ribbon, which reads like a route map
of the night. Everything else stays quiet. Structure carries information: a border style means
a state, a hairline separates a decision from its evidence.

Avoid the generic dashboard kit: identical rounded cards with shadows, gradient washes,
tracked all caps labels above every heading, numbered markers where there is no sequence.
`docs/REPORTING.md` already forbids gradients, shadows, decorative images, pie and donut
charts, and 3D. Use sentence case labels.

### 3.1 Tokens

Keep the layer and status colours from `docs/REPORTING.md` section 9 exactly. Add neutrals.

| Token | Hex | Use |
| --- | --- | --- |
| ink | `#0F172A` | titles, KPI values |
| body | `#1E293B` | running text |
| muted | `#64748B` | labels, units, axis text |
| hairline | `#CBD5E1` | rules between blocks |
| wash | `#F8FAFC` | zebra rows, panel fill |

`bankingreport.sty` and `charts.py` change together, and the palette equality test is updated
in the same PR.

Type stays Inter plus JetBrains Mono. Proposed scale, list it in the PR and get sign off:

| Use | Size |
| --- | --- |
| body | 9 pt |
| table text | 8 pt |
| identifiers in mono | 7.5 pt |
| captions and axis text | 7.5 pt |
| KPI value | 20 pt SemiBold |
| verdict line | 14 pt SemiBold |
| section title | 12 pt SemiBold |

Nothing below 7 pt, including inside figures. Margins 16 mm left and right, 15 mm top, 18 mm
bottom, text width 178 mm.

Status encoding: always print the word, and let the border style carry the state so the page
works in greyscale.

| State | Border | Word |
| --- | --- | --- |
| ok | 0.6 pt solid | OK |
| warn | 0.9 pt solid | WARN |
| bad | 1.4 pt solid | FAIL |
| critical | 1.4 pt solid on the critical fill | CRITICAL |
| idle, skipped | 0.6 pt dashed | NOT RUN or SKIPPED |

### 3.2 Page one layout

```text
┌────────────────────────────────────────────────────────────────────┐
│ Banking Delta Lakehouse   daily   run id (mono)   env   sha   time │ 1 header strip
├────────────────────────────────────────────────────────────────────┤
│ ACTION REQUIRED  Analytics gate failed on 12 rows. Marts were not  │ 2 verdict line
│                  published, yesterday's marts stand.               │
├──────────┬──────────┬──────────┬──────────┬──────────┬──────────────┤
│ Tables   │ Rows     │ DQ gates │ Duration │ Freshest │ Retries      │ 3 KPI strip
│ 8 of 10  │ 22.5k    │ 2 of 4   │ 1h 06m   │ 2h 38m   │ 0            │   value, context
│ ▁▂▃▅▆▇   │ ▁▂▃▅▆▇   │          │ +22%     │ of 24h   │              │   14 run sparkline
├──────────┴──────────┴──────────┴──────────┴──────────┴──────────────┤
│ [pre]▶[mongo][dbx][mysql]▶[raw tests]▶[stg load]▶...▶[publish]▶[fin]│ 4 pipeline ribbon
├───────────────────────────────────────┬────────────────────────────┤
│ What needs attention                  │ Gates                      │ 5 and 6
│ MAJOR R003 analytics ...              │ DQ matrix, check x layer   │
│ MAJOR R004 publish ...                │ Freshness bullets, named   │
│ MINOR R007 x2 raw.a, raw.b            │                            │
├───────────────────────────────────────┴────────────────────────────┤
│ Last 14 runs: duration line with median band, status dots, rows    │ 7 trend strip
├────────────────────────────────────────────────────────────────────┤
│ Next actions: 1 ... 2 ...   runbook pointer printed once           │ 8 next actions
└────────────────────────────────────────────────────────────────────┘
```

| Block | Content | Source | Notes |
| --- | --- | --- | --- |
| 1 | kind, run key, env, git sha, generated time with zone | `meta` | the run key is in mono |
| 2 | verdict label plus one sentence of cause and one of consequence | `verdict`, `events`, `steps` | text comes from templates in `config/report.yaml` filled from fields, never free text from the warehouse |
| 3 | six KPI cells split by hairlines, each with a value, a context line and a 14 run sparkline where history exists | `kpis`, `trends` | section 4.1 defines every number |
| 4 | all 13 steps with state and duration | `steps` | geometry in section 4.3 |
| 5 | top five events grouped by rule and layer, each with subject, message and one line of impact | `events` | section 4.2 |
| 6 | DQ matrix and freshness bullets | `dq`, `freshness` | one panel, labels always `layer.table` |
| 7 | duration line with median band and status dots, rows landed bars under it on the same x axis | `trends` | drawn small, about 40 mm high |
| 8 | at most four ordered actions, the runbook link printed once | `next_actions` | wording lives in config, section 5 |

Healthy night: blocks 5 and 8 collapse to one sentence and the space goes to blocks 6 and 7.
The healthy daily report is two pages: page one plus the appendix.

Incident kind: page one keeps blocks 1 to 4, then replaces 5 to 8 with
- Blast radius: what did not publish, which marts are stale, age of the last good publish
  (from `publish` state and `freshness`).
- First failure: step, attempt number, error category, redacted message cut to 300 characters
  (from `steps`, `tables`, `errors`).
- What changed against the last good run: rows, duration, tables (from `trends`).
- Next actions.

### 3.3 Later pages

| Kind | Pages after page one |
| --- | --- |
| daily | Gantt timeline, Volumes (one chart plus one table), Freshness, DQ table, appendix |
| incident | event blocks with evidence, DQ detail or the idle note, Gantt, appendix |
| weekly | 28 run status strip, duration trend with median band, recurring events by `event_id` (days seen, last seen, severity), median duration per step, DQ failures per check, freshness breaches, appendix |

Page budget for this redesign: healthy daily 2, daily with events 3 to 4, incident 2 to 4,
weekly 3 to 5. `docs/REPORTING.md` says both "daily 4 to 8" and "healthy daily fits page one
plus the appendix"; update it so the two statements agree with this table.

## 4. Component specs

### 4.1 KPI definitions

Compute every number once, in Python, into `context["kpis"]`. Templates only print.

| KPI | Definition |
| --- | --- |
| Tables | latest attempt per table for the pipeline run, as `finish_pipeline_run` does: ok, failed, skipped, total. The appendix uses the same four numbers |
| Rows | rows landed at the raw layer, with rows published at the publish layer as the context line. Never sum across layers. Rule R009 uses the same definition |
| DQ gates | checks that passed out of all checks, with warnings and failures counted separately |
| Duration | run duration with a signed delta against the trailing median, and the median value |
| Freshest | the worst table age as a share of its window, and the number of breaches |
| Retries | tables with `attempt_number` above 1 |

If the run row counts and the table list disagree, print the table list numbers, add an event
that says so, and never print two different totals on the same report.

### 4.2 Events

Group events with the same rule and layer into one row: `R007 x2 raw.card_transactions,
raw.support_tickets`. Always show the subject. Print one runbook pointer per distinct action in
the Next actions block, not one per row. Wrap long identifiers with `ident` and long messages
with `breakable`.

### 4.3 Pipeline ribbon

Two bands, no diagonal arrows, no overlapping boxes.

| Band | Nodes | Layout |
| --- | --- | --- |
| extract | `preflight`, then `extract_mongo`, `extract_databricks`, `extract_mysql` stacked, then `raw_tests` | left to right, extracts in three lanes with a fan out and fan in bracket |
| transform | `staging_load`, `staging_tests`, `analytics_load`, `analytics_tests`, `marts_load`, `marts_tests`, `publish`, `finalize_audit` | one row of eight, about 19 mm wide with 3 mm gaps, 173 mm in total |

Starting numbers, adjust after rasterizing: step name on two lines if needed, duration under
it, node height 11 mm. Node fill is the layer colour, border and word carry the state. A step
with no audit evidence shows `NOT RUN` with the dashed border, never a duration and never ok.
Add a unit test in `tests/unit/reports/test_flow.py`: no two node boxes overlap and every edge
is axis aligned.

### 4.4 Timeline

Rows in DAG order. Bars use real start and end offsets from `audit.table_runs`, so parallel
extracts overlap. Retries are hatched, failures outlined, steps without evidence get no bar and
a grey `no evidence` tick. Show minutes on the axis once a run passes ten minutes.

### 4.5 Volumes

One chart: horizontal dumbbell, rows today against the median for that table, rows labeled
`layer.table`. If no per table median exists, draw no line. Remove the layer bars chart. Keep
source versus landed as a small table with a gap column and highlight a nonzero gap, which is
what `publish_reconcile` exists for.

### 4.6 DQ matrix

Rows are checks, columns are layers, each cell prints PASS, WARN, FAIL or `n/a`. Build the
matrix and the table from the same list so they cannot disagree. A WARNING check is a row in
both.

### 4.7 Empty, idle and unavailable

Three different situations, three different outputs.

| Situation | Output |
| --- | --- |
| the collector raised for a section | `\sectionunavailable{name}`, red outline, names the section that failed |
| the section is empty because the run stopped earlier | new `\sectionidle{name}{reason}`, grey dashed outline, reason computed from the steps, for example `run stopped at extract_mongo, no DQ gate ran` |
| the section has nothing to say and the kind allows dropping it | the chapter is not printed (`drop_when_empty`) |

A chart level placeholder is a single line, 12 mm high at most, and is never printed above
populated content.

### 4.8 Charts

- Make every figure at its final printed size: full width 178 mm (7.0 in), half width 86 mm
  (3.4 in), and include it with no scaling.
- Same font everywhere, at least 7 pt, Inter registered from `fonts/`.
- Integer ticks on every count axis.
- Direct labels instead of legends, thin dashed lines for median and threshold, bars start at
  zero, at most four colours per chart.
- Sparklines are TikZ paths drawn from numbers that Python validated as floats and passed
  through `raw`. Warehouse text never goes through `raw`.

## 5. Contract changes

The new fields break the schema, so bump `schema_version` to 2 and update the schema, all five
fixtures, the templates and the tests in the same PR.

| Field | Purpose |
| --- | --- |
| `kpis` | the numbers in section 4.1 |
| `steps[].start_offset_s`, `steps[].end_offset_s`, `steps[].evidence` | the true timeline and the no evidence state |
| `tables[].label`, `tables[].median_rows` | `layer.table` labels and the per table median |
| `dq[].status` | one canonical enum used by every consumer, with WARNING rows included |
| `verdict.headline`, `verdict.consequence` | the two sentences in block 2 |
| `next_actions` | the ordered actions in block 8, one per distinct runbook anchor |

`tables[].median_rows` needs one more read only `SELECT` over the last `trend_runs` runs. The
read only guard test must still pass.

## 6. Build plan

One concern per branch (`feature/report-...`), small PRs, tests with the code, open the PR and
stop. Add dependencies with `uv` only. Any new TeX package also goes into
`reports/apt-packages.txt` and must compile in `make report-docker`.

| Phase | Deliverable | Done when |
| --- | --- | --- |
| 0 | build every fixture, rasterize the pages, keep the PNGs outside the repo, write D1 to D10 as failing tests | each defect has a test that fails today |
| 1 | data fixes D1 to D5 and D8 to D10, schema 2, fixtures, `kpis`, `next_actions` | consistency tests pass on every fixture, no visual change yet |
| 2 | tokens, style file, macros `\verdictline`, `\kpistrip`, `\ribbon`, `\gatepanel`, `\eventrow`, `\sectionidle`, `\sparkline` | style file compiles in the container, palette test passes |
| 3 | charts and flow from sections 4.3 to 4.8 | no overlap test passes, every figure labeled, placeholders small |
| 4 | page one for daily, then incident, then weekly | page budgets hold, section 7 checks pass |
| 5 | docs sync: `docs/REPORTING.md` sections 5, 6 and 9, `reports/README.md`, `docs/TESTING.md` | every changed behaviour is documented |

## 7. Acceptance and visual QA

1. `make ci` green and `make report-docker` green: every fixture compiles, the log has no `!`
   error and no overfull box, page budgets hold.
2. Consistency tests on every fixture: the KPI counts equal the appendix counts, the heatmap
   cell equals the table status, a step without evidence has no timeline bar, every event
   subject appears in the attention block, the verdict equals the maximum event severity.
3. Mutation test: flip one DQ status in a copy of a fixture and assert that the matrix, table,
   KPI, event and banner all change together.
4. Look at the pages. Rasterize with `pdftoppm -r 110 -png` when poppler is installed, open
   every page of every fixture and check: no overlapping or clipped text, no page more than 40
   percent blank except the last, one typeface across text and figures, nothing under 7 pt. If
   no rasterizer exists, ask a human instead of skipping this step.
5. Greyscale check: convert a page to greyscale and confirm every state is still readable by
   its word and border.
6. Determinism: build twice, the `.tex` is byte identical.
7. Ten second test: someone who has not seen the report answers "healthy or not, what broke,
   what next" from page one alone.

## 8. Rules that stay in force

- Read only. No row values, PII, secrets or connection strings in context, figures, LaTeX, logs
  or mail.
- Every value is escaped by default, shell escape stays off, `raw` is for Python built values
  only.
- Unknown is never rendered as success. A failed report never turns a green run red.
- Thresholds and severity mappings change only with human approval.
- Output is deterministic. Dependencies via `uv` only. Windows safe paths and `encoding="utf-8"`.
- Style: one short header comment per file, no comments between code lines, `ruff` clean, SQL
  with uppercase keywords, one column per line and four space indent.
- Documentation prose uses no hyphens. Do not edit or import `reports/legacy/`.
- Do not change the Airflow DAG, `notify.py`, `summary.py`, compose files or the Dockerfile as
  part of this work. Ask first.

## 9. Decisions for a human

List these in the PR and wait for an answer.

1. The type scale and margins in section 3.1, and the 7 pt floor. Dense A4 pages are hard to
   read at phone width, so confirm where the mail is read.
2. The wording templates for `verdict.headline`, `verdict.consequence` and `next_actions`.
   They live in `config/report.yaml`, where severity and threshold changes already need
   approval.
3. The per table median query.
4. Resolving the contradictory page budget statements in `docs/REPORTING.md`.
5. Whether `schema_version` 2 may land before the weekly digest is redesigned.
