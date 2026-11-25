# Site audit

## Method

`tools/check_layout.mjs` launched headless Chrome/Edge through the DevTools Protocol, loaded `site/index.html` at five widths, measured layout in-page, captured full-page screenshots, and wrote machine-readable results to `docs/site-qa/report.json`. No dependency was added; the checker uses Node built-ins and an installed Chrome/Edge binary.

Command: `node tools/check_layout.mjs --out docs/site-qa`

## Before measurements

| Width | Page horizontal scroll | Internal horizontal scrollers | Visible text overlaps | SVG text issues | Console errors | Failed requests | Screenshot |
|---:|---:|---:|---:|---:|---:|---:|---|
| 360 | no | 9 | 0 | 18 | 0 | 0 | `docs/site-qa/before-360.png` |
| 768 | no | 6 | 0 | 18 | 0 | 0 | `docs/site-qa/before-768.png` |
| 1024 | no | 2 | 0 | 18 | 0 | 0 | `docs/site-qa/before-1024.png` |
| 1440 | no | 3 | 0 | 18 | 0 | 0 | `docs/site-qa/before-1440.png` |
| 1920 | no | 3 | 0 | 18 | 0 | 0 | `docs/site-qa/before-1920.png` |

The page-level scroll test passes only because overflow is hidden inside scroll containers. The site still fails the “no horizontal scroll wrapper” requirement: `.navlinks`, `.diagram-scroll`, `.tablewrap` and one `pre` all scroll horizontally at the smaller widths (`docs/site-qa/report.json:11-83,335-375,615-623,831-847,1014-1030`).

## Measured SVG defects

The checker found the same 18 SVG issues at every width. The main categories are:

- Text escaping the SVG viewport: hero subtitle `MySQL · Mongo · Databricks` and flow label `SQL connector → parquet → Spark` (`docs/site-qa/report.json:86-114`).
- Node text exceeding its own box: `3 tables · incr created_at` in `dbxpub` and `publish_marts.py` in `publish` (`docs/site-qa/report.json:115-126`).
- Edge/gate labels intersecting node text or node boxes: `mongo spark connector`, `SQL connector → parquet → Spark`, `SELECT`, `staging-tests`, `analytics-tests` (`docs/site-qa/report.json:127-180`).

## Root causes

### 1. Diagrams use hard-coded SVG coordinates inside horizontal scrollers

The hero SVG has a fixed `viewBox="0 0 1040 160"` and hand-placed text at fixed x/y coordinates (`site/index.html:75-97`). The flagship diagram uses a much larger fixed `viewBox="0 0 1600 900"` with hundreds of literal coordinates for lanes, edges, labels, nodes, gates and packets (`site/index.html:130-306`). The CSS then forces `min-width: 1420px` / `900px` inside `.diagram-scroll` (`site/style/diagrams.css:31-46`), so the apparent fit is a scroll effect rather than a responsive layout.

This explains the escaped labels, text-over-node intersections and the persistent internal horizontal scrollers at every tested width. The rebuild must generate geometry from a data model with measured boxes, guaranteed gaps, edge pills and a sub-900px vertical stepper.

### 2. The navigation bar is overpopulated and hidden-scrolling

There are 15 top-level nav links (`site/index.html:26-42`). `.navlinks` is a horizontal scroller with hidden scrollbar and a mask (`site/style/components.css:43-54`); links are `white-space: nowrap` (`site/style/components.css:56-63`). At 360px the nav scroll width is 1047px against a 287px client width (`docs/site-qa/report.json:13-19`). This hides destinations and conflicts with the planned 5–6 links plus mobile hamburger/focus trap.

### 3. The daily timeline and tables are horizontal-scroll wrappers

The ten-step timeline is a 10-column grid with `repeat(10, minmax(150px, 1fr))` (`site/style/components.css:354-359`) and is wrapped in `.tablewrap` with `overflow-x: auto` (`site/style/components.css:279-284`, `site/index.html:337-348`). Source, audit, orchestration and docs tables use the same wrapper pattern (`site/index.html:465-477,530-540,609-621,701-718`). At 360px the timeline wrapper is 327px against a 319px client and the source table is 556px against 319px (`docs/site-qa/report.json:36-59`). The rebuild must let these components wrap or become vertical on small screens.

### 4. Content and links depend on JavaScript that is not present in the HTML

Repo and doc links have placeholder `href="#docs"` / `href="#repository"` values until `site.js` rewrites them (`site/index.html:705-715`, `site/scripts/site.js:174-184`). Drawer content is filled only by JS (`site/index.html:730-738`, `site/scripts/site.js:291-301`). `.reveal` elements start at `opacity: 0` and require JS to add `.in` (`site/style/base.css:176-185`, `site/scripts/site.js:366-383`). Without JS, key links are inert or wrong and some content is invisible; the rebuild must make all content and links present in static HTML.

### 5. The site is embedded in Streamlit rather than served as plain static files

`site/site.py` is a Streamlit entrypoint that renders the landing page as an iframe (`site/site.py:1-16`), and `site/README.md` describes the page as one self-contained iframe with CSS/JS inlined at runtime (`site/README.md:1-23`). `site.js` even resizes the parent iframe (`site/scripts/site.js:166-172`). This conflicts with the required plain-file/GitHub Pages delivery and adds an unnecessary runtime layer.

### 6. Theme and visual system are incomplete

`tokens.css` follows only `prefers-color-scheme` and has no manual toggle or persisted choice (`site/style/tokens.css:1-83`). The current shell uses a radial glow (`site/style/base.css:21-29`), glass-like cards (`site/style/components.css:76-92`) and the right colour families, but it lacks the manual dark/light control, tokenized spacing scale, fluid design system, and deliberate cyan-violet accent treatment requested for the rebuild.

### 7. Style hygiene is poor

The current HTML has 20 inline `style=` attributes (`site/index.html:61,349,371,373,400,402,425,442,444,449,451,478,480,483,514,530,581,606,607,609`). Six `!important` declarations remain in `site/style/streamlit.css:11-13,97-103`. These must be replaced with named classes and tokenized rules.

### 8. At least one published fact is wrong

The publish section says keyed tables are MERGEd and non-keyed tables use INSERT OVERWRITE (`site/index.html:492-493,500,508`), but `publish_marts.py` forces an empty `where`, logs a full overwrite, and always executes `_overwrite_sql` (`src/jobs/publish_marts.py:485-489,518-520`). The rebuilt site must describe the actual local Parquet → UC volume → Delta overwrite path.

## Suspect causes to fix first

1. Replace both fixed-coordinate SVG diagrams with measured HTML/CSS or generated SVG geometry; delete the `min-width` scrollers.
2. Reduce nav to 5–6 stable links and add a real mobile menu with focus trap and Escape handling.
3. Convert the timeline, tables and code chips to wrapping/stacked layouts; remove `.tablewrap` as a scroll mechanism.
4. Put real hrefs and all visible content into static HTML; JS should only enhance replay, highlighting and drawer behaviour.
5. Add manual dark/light toggle with safe `localStorage`, tokenized spacing/colour/radius, no inline styles and no `!important`.
6. Correct the publish description and keep every displayed number aligned with `REPO_UNDERSTANDING.md`.
