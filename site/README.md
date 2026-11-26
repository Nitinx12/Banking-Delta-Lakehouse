# site - landing page helpers

Helpers behind the project landing page: `index.html` (the page itself) and `app.py`
(the Streamlit host that serves it plus a read-only audit panel).

| Path | What it is |
| --- | --- |
| `index.html` | The landing page: architecture, layers, entry points, DQ gates, runbook, insights. |
| `site_render.py` | Turns `index.html` into what the iframe shows: inlines small `assets/…` files as data URIs, rewrites repo document links to GitHub, injects the facts and live-audit JSON blocks. |
| `site_audit.py` | The fixed `QUERIES` allowlist over the `audit` schema (`fn_pipeline_summary`, `fn_table_runs`, `fn_dq_summary`, `v_dq_latest`), plus the payload builder and a redacting error formatter. |
| `check_site.mjs` | Static checks on `index.html`: JSON blocks parse, the inline script compiles, every `data-fact` is defined, local links/anchors resolve, `make <target>` names exist, and no copy from the previous project leaked in. |

Nothing here runs the pipeline; the page only reads the `audit` schema.

## Run

```bash
streamlit run app.py                       # site + live audit panel
node site/check_site.mjs                   # static checks on index.html
```

Live data needs a `[postgres]` block in `.streamlit/secrets.toml` (read-only user with
`SELECT` on `audit`). Without it the page falls back to its labelled demo snapshot and
`app.py` says so in the second tab.

## Docs

MkDocs builds to `site_build/` (`mkdocs.yml` → `site_dir`), so the name `site/` stays
free for these helpers. Pages publish `site_build/` from `.github/workflows/pages.yml`.
