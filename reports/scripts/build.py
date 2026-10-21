"""Build one report: load context, evaluate severity, render, chart, compile."""

from __future__ import annotations

import argparse
import json
import re
import shutil
import statistics
import sys
from pathlib import Path
from typing import Any

import jsonschema

from . import charts, collect, compile as compile_mod, flow, paths, render, severity

EXIT_OK = 0
EXIT_UNEXPECTED = 1
EXIT_INVALID = 2
EXIT_COMPILE_FAILED = 3

_SEVERITY_RANK = {"CRITICAL": 0, "MAJOR": 1, "MINOR": 2, "INFO": 3, "UNKNOWN": 4}
_RESULT_KEYS = ("kind", "verdict", "pages", "path", "degraded")
_LEFTOVER_TAG = re.compile(r"\\(VAR|BLOCK)\{")

_CHAPTER_TEMPLATES = {
    "summary": "01_summary.tex.j2",
    "flow": "02_flow.tex.j2",
    "timeline": "03_timeline.tex.j2",
    "volumes": "04_volumes.tex.j2",
    "dq": "05_dq.tex.j2",
    "freshness": "06_freshness.tex.j2",
    "incidents": "07_incidents.tex.j2",
    "trends": "08_trends.tex.j2",
    "appendix": "09_appendix.tex.j2",
}
_CHART_BUILDERS = {
    "task_timeline": lambda context: charts.task_timeline(context.get("steps") or []),
    "volumes_dumbbell": lambda context: charts.volumes_dumbbell(
        context.get("tables") or [], _median(context.get("trends") or [], "rows_landed")
    ),
    "layer_rows": lambda context: charts.layer_rows(context.get("tables") or []),
    "dq_heatmap": lambda context: charts.dq_heatmap(context.get("dq") or []),
    "freshness_bullet": lambda context: charts.freshness_bullet(
        context.get("freshness") or []
    ),
    "error_categories": lambda context: charts.error_categories(
        context.get("errors") or []
    ),
    "trend_duration": lambda context: charts.trend_duration(
        context.get("trends") or []
    ),
    "trend_failures": lambda context: charts.trend_failures(
        context.get("trends") or []
    ),
    "publish_reconcile": lambda context: charts.publish_reconcile(
        context.get("tables") or []
    ),
}


class RenderError(RuntimeError):
    """A template did not render completely."""


def _median(rows: list[dict[str, Any]], key: str) -> int | None:
    """Median of one numeric field across the trend rows."""
    values = [row[key] for row in rows if row.get(key) is not None]
    if not values:
        return None
    return int(statistics.median(values))


def _total_rows(context: dict[str, Any]) -> int:
    """Rows landed across every table of the run."""
    return sum(int(t.get("rows_landed") or 0) for t in context.get("tables") or [])


def _kpis(context: dict[str, Any]) -> dict[str, dict[str, str]]:
    """The four cards on page one: tables, rows, data quality and duration."""
    tables = context.get("tables") or []
    ok = sum(1 for t in tables if t.get("status") == "SUCCESS")
    failed = sum(1 for t in tables if t.get("status") == "FAILED")
    skipped = len(tables) - ok - failed
    total = len(tables)
    dq = context.get("dq") or []
    dq_ok = sum(1 for row in dq if str(row.get("status", "")).upper() == "PASS")
    dq_failed = len(dq) - dq_ok
    duration = (context.get("run") or {}).get("duration_s")
    baseline = _median(context.get("trends") or [], "duration_s")
    if duration is None:
        duration_card = {"value": "n/a", "subtitle": "run duration", "state": "idle"}
    elif baseline:
        change = int(round((float(duration) / baseline - 1) * 100))
        duration_card = {
            "value": render.fmt_dur(duration),
            "subtitle": f"{change:+d}% vs median {render.fmt_dur(baseline)}",
            "state": "warn" if change > 50 else "ok",
        }
    else:
        duration_card = {
            "value": render.fmt_dur(duration),
            "subtitle": "run duration",
            "state": "ok",
        }
    return {
        "tables_ok": {
            "value": f"{ok}/{total}",
            "subtitle": f"{failed} failed, {skipped} skipped",
            "state": "bad" if failed else "ok",
        },
        "rows_landed": {
            "value": render.fmt_int(_total_rows(context)),
            "subtitle": "rows landed",
            "state": "ok" if total else "idle",
        },
        "dq_passed": {
            "value": f"{dq_ok}/{len(dq)}",
            "subtitle": f"{dq_failed} not passing",
            "state": "bad" if dq_failed else "ok",
        },
        "duration": duration_card,
    }


def _attention(events: list[dict[str, Any]], limit: int = 5) -> list[dict[str, Any]]:
    """The events a human has to read, worst first."""
    ranked = [event for event in events if event.get("severity") != "INFO"]
    ranked.sort(
        key=lambda event: (
            _SEVERITY_RANK.get(str(event.get("severity")), 4),
            str(event.get("rule", "")),
            str(event.get("subject", "")),
        )
    )
    return ranked[:limit]


def _load_context(args: argparse.Namespace, kind: str) -> dict[str, Any]:
    """Fixture or database context; the fixture path is the hermetic route."""
    if args.fixture:
        path = paths.fixture_path(args.fixture)
        if not path.is_file():
            raise LookupError(f"unknown fixture: {args.fixture}")
        return json.loads(path.read_text(encoding="utf-8"))
    if args.dag_id:
        return collect.collect(
            kind=kind, dag_id=args.dag_id, dag_run_id=args.dag_run_id
        )
    raise LookupError("pass --fixture or --dag-id")


def _chapters_for(
    kind: str, context: dict[str, Any], config: dict[str, Any]
) -> list[str]:
    """Chapters of one kind, minus the ones that would be empty."""
    spec = config["kinds"][kind]
    drop = set(spec.get("drop_when_empty") or [])
    empty = {
        "dq": not context.get("dq"),
        "incidents": not context.get("events"),
        "timeline": not context.get("steps"),
        "volumes": not context.get("tables"),
        "freshness": not context.get("freshness"),
        "trends": not context.get("trends"),
    }
    return [
        name for name in spec["chapters"] if name not in drop or not empty.get(name)
    ]


def _regeneration(args: argparse.Namespace, kind: str) -> str:
    """The command that rebuilds this exact report."""
    if args.fixture:
        return f"python -m reports.scripts.build --kind {kind} --fixture {args.fixture}"
    run = f" --dag-run-id {args.dag_run_id}" if args.dag_run_id else ""
    return f"python -m reports.scripts.build --kind {kind} --dag-id {args.dag_id}{run}"


def _assert_rendered(build_dir: Path) -> None:
    """Fail when a rendered chapter still holds a Jinja tag."""
    for path in sorted(build_dir.glob("*.tex")):
        found = _LEFTOVER_TAG.search(path.read_text(encoding="utf-8"))
        if found:
            raise RenderError(
                f"unrendered template tag in {path.name}: {found.group(0)}"
            )


def _render(
    env: Any,
    template_vars: dict[str, Any],
    chapter_names: list[str],
    build_dir: Path,
) -> None:
    """Write meta, manifest and every enabled chapter into the build folder."""
    build_dir.mkdir(parents=True, exist_ok=True)
    for name in chapter_names:
        template = env.get_template(_CHAPTER_TEMPLATES[name])
        stem = Path(_CHAPTER_TEMPLATES[name]).stem.removesuffix(".tex")
        (build_dir / f"{stem}.tex").write_text(
            template.render(template_vars), encoding="utf-8"
        )
    (build_dir / "meta.tex").write_text(
        env.get_template("meta.tex.j2").render(template_vars), encoding="utf-8"
    )
    (build_dir / "manifest.tex").write_text(
        env.get_template("manifest.tex.j2").render(
            {
                **template_vars,
                "chapters": [
                    Path(_CHAPTER_TEMPLATES[name]).stem.removesuffix(".tex")
                    for name in chapter_names
                ],
            }
        ),
        encoding="utf-8",
    )
    _assert_rendered(build_dir)


def _draw_figures(
    context: dict[str, Any], figures_dir: Path
) -> dict[str, render.RawTeX]:
    """One figure per chart; a failing chart degrades only itself."""
    figures: dict[str, render.RawTeX] = {}
    charts.apply_style(paths.REPORTS_DIR / "fonts")
    for name, builder in _CHART_BUILDERS.items():
        try:
            figures[name] = charts.figure_include(builder(context), name, figures_dir)
        except Exception as exc:  # noqa: BLE001 - a missing figure degrades one figure
            print(f"figure {name} failed: {type(exc).__name__}", file=sys.stderr)
            figures[name] = render.RawTeX("")
    return figures


def _compile_kind(
    kind: str,
    out_root: Path,
    run_key: str,
    epoch: str | None,
) -> tuple[bool, Path | None, int | None]:
    """Compile one kind and publish the PDF to the run folder and the latest copy."""
    jobname = Path(paths.PDF_NAMES[kind]).stem
    log_path = paths.BUILD_DIR / f"{jobname}.log"
    source = paths.BUILD_DIR / f"{jobname}.pdf"
    if source.exists():
        source.unlink()
    ok = compile_mod.compile_pdf(
        paths.REPORTS_DIR,
        jobname=jobname,
        log_path=log_path,
        epoch=epoch,
    )
    if not ok or not source.is_file():
        return False, None, None
    target = paths.run_dir(run_key, out_root) / paths.PDF_NAMES[kind]
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy(source, target)
    latest = paths.latest_pdf(kind, out_root)
    latest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy(source, latest)
    return True, target, compile_mod.page_count(log_path)


def _build_kind(
    args: argparse.Namespace,
    env: Any,
    context: dict[str, Any],
    kind: str,
    config: dict[str, Any],
    out_root: Path,
    run_key: str,
    template_vars: dict[str, Any],
    figures: dict[str, render.RawTeX],
    flow_data: dict[str, Any] | None,
) -> dict[str, Any]:
    """Render, compile and, on failure, retry in safe mode without figures."""
    chapter_names = _chapters_for(kind, context, config)
    variables = {
        **template_vars,
        "meta": {**(context.get("meta") or {}), "kind": kind},
        "figures": figures,
        "flow": flow_data,
    }
    _render(env, variables, chapter_names, paths.BUILD_DIR)
    verdict = context["verdict"]["severity"]
    if args.no_pdf:
        return {
            "kind": kind,
            "verdict": verdict,
            "pages": None,
            "path": None,
            "degraded": False,
            "built": True,
        }
    epoch = compile_mod.source_date_epoch((context.get("run") or {}).get("ended_at"))
    ok, target, pages = _compile_kind(kind, out_root, run_key, epoch)
    if ok:
        return {
            "kind": kind,
            "verdict": verdict,
            "pages": pages,
            "path": str(target) if target else None,
            "degraded": False,
            "built": True,
        }
    safe_vars = {**variables, "figures": {}, "flow": None, "degraded": True}
    _render(env, safe_vars, chapter_names, paths.BUILD_DIR)
    ok, target, pages = _compile_kind(kind, out_root, run_key, epoch)
    return {
        "kind": kind,
        "verdict": verdict,
        "pages": pages if ok else None,
        "path": str(target) if (ok and target) else None,
        "degraded": True,
        "built": ok,
    }


def build_report(args: argparse.Namespace) -> int:
    """Render and compile one report; returns the process exit code."""
    config = paths.load_report_config()
    context = _load_context(args, args.kind or "daily")
    kind = args.kind or str(context["meta"].get("kind") or "daily")
    if kind not in config["kinds"]:
        print(f"unknown kind: {kind}", file=sys.stderr)
        return EXIT_INVALID
    schema = json.loads(paths.CONTEXT_SCHEMA.read_text(encoding="utf-8"))
    try:
        jsonschema.validate(context, schema)
    except jsonschema.ValidationError as exc:
        print(f"context invalid: {exc.message}", file=sys.stderr)
        return EXIT_INVALID
    if args.strict and context.get("sections_failed"):
        print(f"sections degraded: {context['sections_failed']}", file=sys.stderr)
        return EXIT_INVALID

    thresholds = config["thresholds"]
    context["meta"]["kind"] = kind
    evaluated = severity.evaluate(
        context,
        volume_ratio=float(thresholds["volume_deviation_ratio"]),
        duration_ratio=float(thresholds["duration_regression_ratio"]),
    )
    context_file = paths.context_path()
    context_file.parent.mkdir(parents=True, exist_ok=True)
    context_text = json.dumps(evaluated, indent=2, sort_keys=True) + "\n"
    context_file.write_text(context_text, encoding="utf-8")
    run_key = (
        f"fixture__{paths.fixture_path(args.fixture).stem}"
        if args.fixture
        else paths.run_key(args.dag_run_id or args.dag_id)
    )
    out_root = Path(args.out) if args.out else paths.output_root()
    run_dir = paths.run_dir(run_key, out_root)
    run_dir.mkdir(parents=True, exist_ok=True)
    (run_dir / "context.json").write_text(context_text, encoding="utf-8")

    figures: dict[str, render.RawTeX] = {}
    flow_data: dict[str, Any] | None = None
    if not args.no_charts:
        figures = _draw_figures(evaluated, paths.FIGURES_DIR)
        if evaluated.get("steps"):
            flow_data = flow.build_flow(evaluated["steps"])

    env = render.make_env(paths.TEMPLATE_DIR, paths.CHAPTERS_DIR)
    template_vars = {
        **evaluated,
        "kpis": _kpis(evaluated),
        "attention": _attention(evaluated.get("events") or []),
        "regeneration": _regeneration(args, kind),
        "degraded": False,
    }
    kinds = [kind]
    if kind == "daily" and evaluated["verdict"]["severity"] in {"MAJOR", "CRITICAL"}:
        kinds.append("incident")
    results = []
    for target_kind in kinds:
        result = _build_kind(
            args,
            env,
            evaluated,
            target_kind,
            config,
            out_root,
            run_key,
            template_vars,
            figures,
            flow_data,
        )
        results.append(result)
        if not result["built"]:
            break
    if results and not results[-1]["built"]:
        print(
            f"compile failed for {results[-1]['kind']}, see {paths.BUILD_DIR}",
            file=sys.stderr,
        )
        print(json.dumps({k: results[-1][k] for k in _RESULT_KEYS}, sort_keys=True))
        return EXIT_COMPILE_FAILED
    paths.prune_runs(root=out_root)
    print(json.dumps({k: results[-1][k] for k in _RESULT_KEYS}, sort_keys=True))
    return EXIT_OK


def main(argv: list[str] | None = None) -> int:
    """CLI entry; never raises past this point."""
    parser = argparse.ArgumentParser(description="build one banking report")
    parser.add_argument("--kind", choices=["daily", "incident", "weekly"], default=None)
    parser.add_argument("--fixture", default=None, help="fixture name or path")
    parser.add_argument("--all-fixtures", action="store_true")
    parser.add_argument("--dag-id", default=None)
    parser.add_argument("--dag-run-id", default=None)
    parser.add_argument("--no-pdf", action="store_true")
    parser.add_argument("--no-charts", action="store_true")
    parser.add_argument("--strict", action="store_true")
    parser.add_argument("--out", default=None, help="output root for the PDFs")
    args = parser.parse_args(argv)
    try:
        if args.all_fixtures:
            worst = EXIT_OK
            for fixture in paths.fixture_paths():
                sub = argparse.Namespace(**vars(args))
                sub.fixture = fixture.stem
                sub.all_fixtures = False
                code = build_report(sub)
                worst = max(worst, code)
            return worst
        return build_report(args)
    except LookupError as exc:
        print(f"usage error: {exc}", file=sys.stderr)
        return EXIT_INVALID
    except RenderError as exc:
        print(f"render error: {exc}", file=sys.stderr)
        return EXIT_INVALID
    except Exception as exc:  # noqa: BLE001 - CLI boundary, one line per failure
        print(f"build failed: {type(exc).__name__}: {exc}", file=sys.stderr)
        return EXIT_UNEXPECTED


if __name__ == "__main__":
    raise SystemExit(main())
