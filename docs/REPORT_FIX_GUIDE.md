# build_report failure and missing attachment: fix guide

Guide for agents. Scope: find and fix why the `build_report` task fails in Airflow while every
test passes, why the summary mail arrives without the report PDF, and make the report path
fail soft so a bad night still produces live evidence in the mail. Place this file in `docs/`.

Read `AGENTS.md` first, then `docs/REPORTING.md` sections 3, 10, 11 and 15. Those win on any
conflict. The look of the PDF is a separate job, see `docs/REPORT_REDESIGN.md`.

## 1. Symptoms and what is not known

Known:

- `make ci` and the unit tests are green.
- In Airflow, the task `build_report` of `banking_delta_daily` goes red.
- The summary mail arrives without the PDF attachment. Confirm whether the mail arrives at
  all, and whether the `.tex` sources are attached.

Not known yet: the traceback, the exit code, which try failed (retries is 1, so there are two
tries), whether the DAG run itself is red, and whether the mail body names a reason. Do not
guess. Section 4 collects the evidence, section 5 finds the failing layer.

## 2. Why green tests prove little

Green means the templates render. It does not mean the worker can compile, connect, write or
attach.

| What the worker needs | Covered by a test today |
| --- | --- |
| Python imports inside the Airflow image (`reports`, `src`, `jinja2`, `matplotlib`, `psycopg2`) | no, tests run in the dev environment |
| TeX Live, XeLaTeX, `latexmk`, fonts inside the image | no, `make ci` runs `report-fixture` with `--no-pdf`, and the `tex` tier is outside `ci` |
| Write access to `reports/build`, `reports/figures`, `reports/data` and the output volume as the `airflow` user | no |
| Collecting from PostgreSQL from inside the container network | no, fixtures are pure JSON and the collector tests use fakes |
| Real value types from the driver (`Decimal`, `datetime`, `None`) | no, fixtures contain none |
| Real history (first run, empty trends, zero median, run still `RUNNING`) | no, fixtures all have clean history |
| Real error text with odd characters | no, fixture text is tidy |
| The mail task finding the file the build task wrote | no |

The cause is almost certainly in this table. The job is to find which row, prove it with a
failing test, then fix it.

## 3. Rules for this work

1. Evidence before edits. No change without a log line, an exit code or a reproduction that
   points at it.
2. A fix ships with a regression test that failed first. Never weaken a test to get green.
3. Read only toward the warehouse. No `INSERT`, `UPDATE`, `CALL` or DDL from report code.
4. Never enable shell escape, never mount `/var/run/docker.sock`, never install MiKTeX.
5. Do not hide a failure with `|| true` or a bare `except Exception: pass`. A fallback must
   record its reason, and the mail must name it.
6. Never print environment values. List variable names only.
7. Never commit `.env`, real PDFs or real `context.json`.
8. Do not fix the open false `[FAILED]` banner bug and do not patch the timezone offset
   (`docs/TROUBLESHOOTING.md`, open issue 3).
9. Dependencies via `uv` only. Documentation prose uses no hyphens. One short header comment
   per code file. Windows safe code (`pathlib`, `encoding="utf-8"`).
10. One concern per branch (`feature/report-...`), small PRs, open the PR and stop.

| Action | Allowed without asking | Ask first |
| --- | --- | --- |
| Read Airflow task logs, list files, print variable names | yes | |
| Fixture builds (`make report-fixture`, `report-pdf`, `report-docker`, `make ci`) | yes | |
| Edit `reports/`, tests, fixtures, docs on a feature branch | yes | |
| `make report`, `report-incident`, live `--dag-id` builds, `airflow tasks test` against the real warehouse | | yes |
| Edit `airflow/Dockerfile`, compose files, the DAG, `.env.airflow.example` | | yes |
| Edit `notify.py` or `summary.py` | | yes |
| Rebuild or restart Airflow images and containers | | yes |

## 4. Step 0: collect evidence

Find the service that runs tasks in the compose file and write it down as `<worker>`. Confirm
paths against the compose file, the values below are the usual ones for the official image.

```powershell
docker compose ps
docker compose exec <worker> bash -lc "ls -d /opt/airflow/logs/dag_id=banking_delta_daily/run_id=*/task_id=build_report"
docker compose exec <worker> bash -lc "tail -n 150 '<log dir>/attempt=1.log'"
docker compose exec <worker> bash -lc "tail -n 150 '<log dir>/attempt=2.log'"
```

The Airflow UI works as well: the DAG, the run, the task `build_report`, Logs, and every try.
For run states use `airflow tasks states-for-dag-run`, and confirm the exact syntax for Airflow
3.3.2 with `--help`.

Record this and paste it in the PR:

```text
# Evidence for the build_report failure
run id:
try 1 exit code or exception:
try 2 exit code or exception:
last 40 log lines of the failing try (redacted):
DAG run state:
is build_report upstream of fail_if_any_failed (yes or no):
did the mail arrive, is a reason in the body, are .tex files attached:
```

Exit codes: the builder returns 0 built, 2 render or schema error, 3 compile failed even in
safe mode, and 1 for usage or an unexpected error. Airflow adds 126 (cannot execute), 127
(command not found) and 137 (killed, usually memory). A timeout shows as `AirflowTaskTimeout`
at 15 minutes.

## 5. Step 1: bisect with a ladder

Run inside the worker, as the same user and with the same environment as the task. Stop at the
first rung that fails. That rung names the layer of the cause.

```bash
# Ladder run inside the worker as the task user.
cd <project root in the image>
id && pwd && which python latexmk xelatex
printenv | cut -d= -f1 | sort | grep -E '^(PG_|REPORT_|ALERT_|SMTP|HOME$|LANG$|TEXMF|XDG|MPLCONFIGDIR|PYTHONPATH)'
python -c "import reports.scripts.build; print('import ok')"
kpsewhich fontspec.sty tcolorbox.sty pgf.sty booktabs.sty longtable.sty
fc-list | grep -i inter
touch reports/build/.w reports/figures/.w reports/data/.w "${REPORT_OUTPUT_DIR:-reports/output}/.w"
python -m reports.scripts.build --kind daily --fixture healthy --no-pdf
python -m reports.scripts.build --kind daily --fixture healthy
```

| Rung | Command | If it fails the cause is in |
| --- | --- | --- |
| 1 | `which python latexmk xelatex`, `id`, `pwd` | image contents, user, working directory |
| 2 | variable names | missing or misnamed environment variables |
| 3 | `import reports.scripts.build` | Python environment, `PYTHONPATH`, files not copied |
| 4 | `kpsewhich` and `fc-list` | TeX packages and fonts |
| 5 | `touch` on the four directories | permissions and volumes |
| 6 | fixture build with `--no-pdf` | render, schema, templates |
| 7 | fixture build with PDF | compile, fonts, TeX, timeout |
| 8 | live build, ask first | database access, real data shapes |
| 9 | the mail step | attachment path, size, MIME, recipients |

Rungs 1 to 7 prove the image. If they all pass and the task still fails, the problem is the
live data path (rung 8) or the task wiring. If rung 7 passes in the container but the task
fails, compare the task command, working directory and environment with what you ran.

For rung 8 you may run `airflow tasks test banking_delta_daily build_report <logical date>`
once the human approves it. It reads the real warehouse.

Print `which python` and `python -c "import sys, jinja2; print(sys.executable)"` as well: `uv sync`
creates a project environment, and Airflow tasks may run another interpreter that never saw
the `reports` group.

## 6. Failure catalogue

Each row is a hypothesis to confirm with the log, not a conclusion.

| Log signature | Likely cause | Check | Fix |
| --- | --- | --- | --- |
| `ModuleNotFoundError: reports` or `src` | the task runs from another working directory, `reports/` or `src/` is not in the image, `reports/__init__.py` missing | `ls reports/__init__.py src`, the `bash_command` | `cd` to the project root in `report_command()` and set `PYTHONPATH`, copy both folders in the Dockerfile (ask first) |
| `ModuleNotFoundError: jinja2`, `jsonschema`, `yaml`, `matplotlib`, `psycopg2` | the `reports` dependency group is not in the interpreter that runs the task | `which python`, `uv.lock` has the group | `uv sync --frozen --group reports` into the environment Airflow uses, or run the builder with `uv run --frozen --group reports`, then rebuild the image (ask first) |
| exit 127, `latexmk: not found`, `FileNotFoundError: latexmk` | TeX Live is not in the worker image, so `compile.latexmk_available()` is false | `which latexmk xelatex` | install the package list through the Dockerfile snippet in `docs/REPORTING.md` section 11, rebuild (ask first) |
| `fontspec` error, `xelatex: not found`, `The font "Inter-Regular.ttf" cannot be found` | `latexmkrc` sets XeLaTeX but `texlive-xetex` or `fontconfig` is missing, `reports/fonts/` was not copied (check `.dockerignore`), or the file name case differs because Windows ignores case and Linux does not | `ls reports/fonts`, `fc-list`, `.dockerignore` | add the packages to `apt-packages.txt`, copy the fonts, match the case exactly |
| `File 'tcolorbox.sty' not found` or any other `.sty` | a TeX package missing from the image | `kpsewhich <name>.sty` in a full TeX container, then `apt-file search <name>.sty` | add the owning apt package to `apt-packages.txt` and compile in `make report-docker`. Typical owners are `texlive-latex-extra`, `texlive-pictures`, `texlive-latex-recommended`, but confirm each one |
| `File 'bankingreport.sty' not found` | `latexmk` ran from the wrong directory | the `workdir` passed by `compile.py` | run from `reports/` so the repo `latexmkrc` applies |
| `PermissionError` or `Errno 13` on `reports/build`, `reports/figures`, `reports/data/context.json` or the output directory | the image copied the repo as root while tasks run as `airflow`, and only the `output/` folder was moved to a volume | rung 5 | `COPY --chown`, create the folders at build time, mount the volume with write access for the task user (ask first). Moving only `REPORT_OUTPUT_DIR` does not move `build/`, `figures/` or `data/` |
| `Fontconfig error: No writable cache directories`, `Matplotlib is building the font cache`, or a very slow first run | no writable `HOME`, cache or `MPLCONFIGDIR` | time of rung 7 | set `HOME`, `XDG_CACHE_HOME`, `MPLCONFIGDIR` and `TEXMFVAR` to a writable path and warm the caches at image build with `fc-cache -f`, one `xelatex` compile and `import matplotlib.pyplot` |
| `AirflowTaskTimeout` at 15 minutes, `subprocess.TimeoutExpired` after 600 s | first run cache build, a stuck TeX run, a slow collector query | timestamps in the log | warm the caches, fix the slow step, keep the timeouts from `docs/REPORTING.md` |
| exit 137 or `Killed` | the worker ran out of memory | container limits | raise the limit or cut figure memory (ask first) |
| `OSError: No space left on device` | the TeX image or the output volume is full, runs are not pruned | `df -h`, `REPORT_RETENTION_DAYS` | prune, resize the volume, confirm `prune_runs` runs |
| `psycopg2.OperationalError`, `connection refused`, `could not translate host name` | `PG_HOST=localhost` inside a container points at the container itself, or the network name is wrong | variable names, the compose network, the host name the other tasks use | use the host name the other tasks use. Confirm the failure degrades, section 9 |
| `UndefinedTable` or `UndefinedColumn` for `audit.*` | the queries drifted from `sql/scripts/02_audit_tables.sql` or a view such as `audit.v_dq_latest` is missing in that database | the DDL against the query | take column names from the DDL, never from this page |
| `TypeError: Object of type Decimal is not JSON serializable` (or `datetime`, `UUID`, `timedelta`) | the driver returns types that fixtures never contain | rung 8 with a fake cursor in a test | coerce once at the collector boundary, section 7 |
| `jsonschema.ValidationError` (exit 2) | real data breaks the schema: null `duration_s` or `ended_at` on a `RUNNING` run, an enum value that no fixture has, a timestamp with a different shape | the validation message and path | fix the collector first. Change the schema only when the real data is legitimate, and bump `schema_version` with every fixture |
| `StatisticsError: no median for empty data`, `ZeroDivisionError`, `max() arg is an empty sequence` | empty trends on a first run, a zero median, a run with no tables | section 7 fixtures | handle empty and zero in `severity.py` and `build.py`, add fixtures |
| `jinja2.UndefinedError` (exit 2) | the live context lacks a key that fixtures have | the key in the message | give the collector a default for that key, never loosen `StrictUndefined` |
| `FileNotFoundError` on `.git/HEAD` | `_meta()` reads the git sha from `.git`, which `.dockerignore` removes from the image | `ls .git` | fall back to a `GIT_SHA` environment value, then `unknown`. Never fail on metadata |
| `ZoneInfoNotFoundError: Asia/Kolkata` | the image has no tz database | `python -c "import zoneinfo; zoneinfo.ZoneInfo('Asia/Kolkata')"` | `uv add --group reports tzdata`, or install `tzdata` in the image (ask first) |
| `UnicodeEncodeError`, `UnicodeDecodeError`, `charmap` | a locale that is not UTF 8, or a missing `encoding="utf-8"` | `echo $LANG`, grep for `open(` without an encoding | set `LANG=C.UTF-8` and `PYTHONUTF8=1`, add `encoding="utf-8"` everywhere |
| `! Undefined control sequence`, `Missing $ inserted`, `Text line contains an invalid character` | a real audit message that no fixture imitates, such as a control character, a NUL, a very long unbroken string, or text that reached a `raw` filter | the `.tex` line named in the log, the redacted source text | strip control characters in `tex_escape`, cap and break long strings, keep warehouse text off `raw`, add the string to the hostile text test |
| exit 1 or 2 with the task still red after a clean ladder | the task command differs from what you ran: quoting of the run id, a missing `cd`, `{{ dag.dag_id }}` or `{{ run_id }}` not templated | the rendered command in the task instance details | build the command in `report_command()`, quote ids, and keep `airflow/tests/test_commands.py` green |

## 7. Real data traps that fixtures never contain

Add these as tests and fixtures in the same PR as the fix. All fixture contents are invented,
none is copied from the warehouse.

| Trap | Test |
| --- | --- |
| driver types `Decimal`, tz aware `datetime`, `UUID`, `timedelta`, `None` | a fake cursor returns them, `collect()` output passes `json.dumps` and the schema. Coerce in one `_jsonable` function at the boundary |
| first ever run, empty `trends` | new fixture `empty_history`, severity and charts handle empty and zero medians |
| `build_report` runs while the run is still `RUNNING`, `ended_at` null | new fixture `running`, the verdict is UNKNOWN and nothing divides by a null duration |
| no `table_runs` rows | new fixture `no_tables`, the report builds and says so |
| database unreachable | new fixture `db_unreachable`, the verdict is CRITICAL through R015 and a report still builds |
| hostile text in error messages | a test feeds `\input{x}`, `\write18`, `%`, `{`, `}`, a NUL, tabs, newlines, an emoji and 10 000 characters through `tex_escape` and a full compile |
| no `.git`, no `GIT_SHA` | `_meta()` returns `unknown` and never raises |
| read only repository path | the builder writes only to the configured directories, run as a non root user |

## 8. The attachment path

Even when `build_report` is green, the mail can arrive without the PDF. Check each item.

| Check | What goes wrong |
| --- | --- |
| The mail finds files only through `paths.run_key` and `output/runs/RUN_KEY/` | a second implementation of the key in `summary.py` or `notify.py` produces another folder name. Import the one function |
| The stale copy | `paths.latest_pdf` is a stable `<output>/<kind>.pdf`. If the mail task reads that file, a failed build attaches yesterday's PDF, which is a false reassurance. Attach only the run folder file, and check that `context.json` in that folder carries the same `dag_run_id` |
| Volume visibility | with several workers or containers the mail task may not see the file. The named volume `report_output` must be mounted in every service that builds or mails. Write a file in `<worker>` and list it from the scheduler |
| Size | `REPORT_MAX_ATTACH_MB` (default 10) skips the file and the body must say so. A normal report is far below 1 MB, so a huge file means a bug |
| MIME structure | add the text body, the HTML alternative and the attachment, then assert in a test that `iter_attachments()` returns the PDF with `application/pdf` |
| Missing file | spec says a warning in the body, never an exception. If the mail has no attachment and no warning, that is a bug |
| Recipients | an empty `REPORT_EMAIL_TO` must fall back to `ALERT_EMAIL_TO`, not override it with nothing |
| Visibility of the send | log the attachment names and byte sizes at INFO, never content |
| `.tex` sources | if the mail currently attaches `.tex` files too, ask a human whether that is intended. `docs/REPORTING.md` specifies the PDF only |

Also confirm that `send_pipeline_summary` is `all_done` and that `build_report` is not upstream
of `fail_if_any_failed`. A red `build_report` task is acceptable only if the DAG run state and
the failure gate are unaffected, as `docs/REPORTING.md` section 11 requires.

## 9. Fail soft: always send live evidence

The intent is that something always arrives. When the full report cannot be built, a smaller
one is built, and the mail names why. The ladder:

| Level | Output | When | The mail says |
| --- | --- | --- | --- |
| 0 | full PDF with charts and flow | normal | verdict, top events |
| 1 | safe mode PDF, no charts, no flow, marked degraded | figure or TikZ failure (exists today) | degraded and the reason |
| 2 | text only PDF through pdfLaTeX and Latin Modern, no fontspec, no TikZ, no matplotlib | XeLaTeX or font failure | degraded, which stage failed |
| 3 | no PDF, plain text and HTML body with verdict, top events, failing step, reason, plus the redacted `context.json` attached | no TeX at all, compile failure at every level | report unavailable and the reason |
| 4 | the builder cannot start | import error, missing module | report unavailable, reason from the status file or the exit code |

Proposal, needs approval because it touches the DAG command and the mail code:

- A small standard library only entry, `reports/scripts/run_report.py`, imports the builder
  inside a `try`, walks the ladder, and always writes
  `output/runs/RUN_KEY/report_status.json` with `state`, `stage`, `exit_code` and a redacted
  reason of at most 300 characters.
- The task runs that entry. It exits 0 when levels 0 to 3 produced something, and 1 only for
  level 4, so a red task is a real signal and the DAG run stays unaffected.
- `send_pipeline_summary` reads `report_status.json` and names the state and reason in the
  body. It attaches whatever the status file lists.
- A database that is unreachable builds a CRITICAL report through R015 (status unknown),
  never an exit 1.

## 10. Tests to add

| Test | Guards against | Tier |
| --- | --- | --- |
| image smoke: build the Airflow worker image, run the fixture build inside it as the `airflow` user with a read only repo mount except the configured directories | missing imports, TeX, fonts, permissions | docker, nightly or on image change |
| collector coerces `Decimal`, `datetime`, `UUID`, `None` | JSON serialization crash | unit |
| fixtures `empty_history`, `running`, `no_tables`, `db_unreachable` build and validate | live data edge cases | unit |
| hostile text goes through `tex_escape` and compiles | LaTeX errors from real messages | `tex` |
| `_meta()` without `.git` | metadata crash | unit |
| fallback ladder: force each level to fail and assert the next one runs and `report_status.json` is written | silent loss of the report | unit |
| mail: attachment present with `application/pdf`, oversize skipped with a reason in the body, missing file still sends with a warning, stale file never attached, empty `REPORT_EMAIL_TO` falls back | lost or false mail | unit |
| mail and builder share one `run_key` function | folder name drift | unit |
| DAG integrity: `build_report` is `all_done`, after `finalize_audit`, before `send_pipeline_summary`, not upstream of the failure gate, retries 1, timeout 15 minutes | wiring regressions | unit |
| a read only guard: the collector issues only `SELECT` | accidental writes | unit |

Mark every test (`unit`, `smoke`, `tex`) or it never runs. Ask a human about running the image
smoke test in CI, because it costs build time.

## 11. Verification protocol

Done only when all of these hold. Quote every approval in the PR.

1. Rungs 1 to 7 pass in the worker image as the task user.
2. `airflow tasks test banking_delta_daily build_report <logical date>` exits 0 and prints the
   one line JSON result (`kind`, `verdict`, `pages`, `path`, `degraded`). Approval required.
3. The PDF sits in `output/runs/RUN_KEY/` and is visible from the scheduler and from the
   container that sends the mail.
4. A real mail arrives with `Banking-Delta_daily_<YYYYMMDD>_<VERDICT>.pdf`, and the verdict
   matches `audit.pipeline_runs.status` through the mapping in `docs/REPORTING.md` section 6.
5. Drills, in a disposable environment:
   - point `PG_HOST` at an invalid host: a mail still arrives and names the reason, with a
     CRITICAL report or the level 3 body;
   - make `latexmk` unavailable in a throwaway container: a level 3 mail arrives;
   - run a seeded failing fixture run: `incident.pdf` is attached;
   - a read only repository mount: the build still succeeds.
6. Every test in section 10 exists, was seen failing before the fix, and passes now.
7. Docs updated in the same PRs: `docs/TROUBLESHOOTING.md` (the symptom and cause found),
   `docs/AIRFLOW.md`, `docs/DEPLOYMENT.md` (image, volumes, variables), `docs/TESTING.md`.

## 12. Report to the human

```text
# build_report fix report
Failing rung and layer:
Root cause with the log line:
Fix and the test that failed first:
Fallback level exercised in the drills:
Attachment path audit, item by item:
Approvals quoted:
Open decisions:
```

## 13. Decisions for a human

1. Fail soft policy and task colour: exit 0 for levels 0 to 3 and 1 for level 4, as proposed in
   section 9, or keep the task red on any degradation.
2. TeX Live in the Airflow worker image (recommended in `docs/REPORTING.md`) against a separate
   builder service. This is still an open decision in section 16 of that file and is the most
   likely reason the image lacks TeX.
3. Running the container compile in CI, with its build time cost.
4. Whether `.tex` sources stay attached to the mail.
5. Recipients and whether incident PDFs go to a wider list.
