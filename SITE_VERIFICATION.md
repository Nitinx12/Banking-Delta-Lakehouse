# Site verification

## Delivered

- Static site: `site/index.html`, `site/style/`, `site/scripts/site.js`, `site/favicon.svg`.
- Design system: `site/style/tokens.css` with fluid typography, spacing, radii, dark-first light theme, cyan-violet accents, glass surfaces and no `!important`.
- Interaction: manual theme with guarded `localStorage`, six-link nav with More menu, scroll spy, mobile menu with focus trap and Escape, measured SVG connectors, detail drawer, illustrative replay console, scrubber and copy feedback.
- Documentation: `REPO_UNDERSTANDING.md`, `SITE_AUDIT.md`, `site/README.md`, `tools/check_layout.mjs`, before and after screenshots/reports in `docs/site-qa/`.

## Layout verification

Command: `node tools/check_layout.mjs --out docs/site-qa --prefix after`

| Width | Horizontal scroll | Internal scrollers | Text overlaps | SVG issues | Console errors | Failed requests | CLS | Transfer excl. fonts |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 360 | no | 0 | 0 | 0 | 0 | 0 | 0 | 81,776 B |
| 768 | no | 0 | 0 | 0 | 0 | 0 | 0 | 81,186 B |
| 1024 | no | 0 | 0 | 0 | 0 | 0 | 0 | 81,186 B |
| 1440 | no | 0 | 0 | 0 | 0 | 0 | 0 | 81,186 B |
| 1920 | no | 0 | 0 | 0 | 0 | 0 | 0 | 81,186 B |

All five widths passed. CLS is below 0.05 and transfer without fonts is below 300 KB. Google Fonts uses `display=optional` so delayed font loading cannot shift layout.

Screenshots: `docs/site-qa/after-360.png`, `docs/site-qa/after-768.png`, `docs/site-qa/after-1440.png`. Full data: `docs/site-qa/after-report.json`.

## Mode verification

- JavaScript disabled: all five widths passed (`docs/site-qa/nojs-report.json`); content and relative links remain visible.
- Reduced motion: 360 and 1440 passed (`docs/site-qa/reduced-report.json`); packets and typewriter effects are disabled.
- Keyboard only: 360 and 1440 passed (`docs/site-qa/keyboard-report.json`); first Tab reaches the skip link and menu focus remains trapped until Escape.

## Fact recheck

Displayed figures were rechecked against `REPO_UNDERSTANDING.md`: 3 source systems, 10 landing tables, 10 gated steps, 44 DQ checks, 7 dimensions, 4 facts, 8 marts, 3 DAGs, schedules `0 2 * * *` / `0 */3 * * *` / `0 8 * * 1`, Python 3.13, PySpark 3.5.x, Streamlit 1.66.1 and Plotly 7.x. The publish text now states the actual full-overwrite implementation instead of MERGE.

## Limitation

Lighthouse was not run because adding it would require a new dependency and no dependency was added. The measurable Lighthouse inputs available without a dependency—CLS, transfer weight, console errors, failed requests, responsive overflow, text overlap and keyboard access—passed.
