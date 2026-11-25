# Banking-Delta-Lakehouse project site

Static landing page for the daily lakehouse pipeline.

## Static hosting

- Entry point: `site/index.html`
- Styles: `site/style/`
- Behaviour: `site/scripts/site.js`
- Favicon: `site/favicon.svg`
- Build step: none
- External network: Google Fonts only (`Inter`, `JetBrains Mono`)

Serve `site/` from any plain file server or GitHub Pages. All content and links are present in the HTML; JavaScript only adds the theme toggle, menus, scroll spy, replay console, detail drawer and copy feedback.

## Verification

From the repository root:

```bash
node tools/check_layout.mjs --out docs/site-qa
```

The checker reports page and internal horizontal scroll, visible text overlaps, SVG text issues, console errors and failed requests at 360, 768, 1024, 1440 and 1920 pixels.

## Streamlit fallback

`site/site.py` still wraps the static page in an iframe for the existing Streamlit deployment. It does not own the page content.

All displayed figures come from the repository. `REPO_UNDERSTANDING.md` records the verified facts and discrepancies with file and line references; `SITE_AUDIT.md` records the before-state and root causes.
