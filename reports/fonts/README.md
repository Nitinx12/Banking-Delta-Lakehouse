# Bundled fonts

The report ships its own font files because CI and the Airflow image have no
network to fetch fonts. Both families are open licence (SIL Open Font License
1.1) and every file here has its licence text next to it.

| File | Family | Face | Licence |
| --- | --- | --- | --- |
| `Inter-Regular.ttf` | Inter | Regular | `Inter-OFL.txt` |
| `Inter-Italic.ttf` | Inter | Italic | `Inter-OFL.txt` |
| `Inter-SemiBold.ttf` | Inter | SemiBold (the bold face of the report) | `Inter-OFL.txt` |
| `Inter-SemiBoldItalic.ttf` | Inter | SemiBold Italic | `Inter-OFL.txt` |
| `JetBrainsMono-Regular.ttf` | JetBrains Mono | Regular | `JetBrainsMono-OFL.txt` |
| `JetBrainsMono-Bold.ttf` | JetBrains Mono | Bold | `JetBrainsMono-OFL.txt` |

Sources, both fetched from the upstream release page of the project:

| Family | Version | Release | Licence file |
| --- | --- | --- | --- |
| Inter | 4.1 | https://github.com/rsms/inter/releases/tag/v4.1 (`extras/ttf/`, `LICENSE.txt`) | `Inter-OFL.txt` |
| JetBrains Mono | 2.304 | https://github.com/JetBrains/JetBrainsMono/releases/tag/v2.304 (`fonts/ttf/`, `OFL.txt`) | `JetBrainsMono-OFL.txt` |

How they are used:

- `reports/template/bankingreport.sty` loads them with `fontspec` under XeLaTeX.
  A missing file falls back to TeX Gyre Heros and TeX Gyre Cursor, then to Latin
  Modern, so the build never fails because of a font.
- `reports/scripts/charts.py` registers the same files with matplotlib, so the
  charts and the document use one typeface.
- `reports/latexmkrc` sets `$pdf_mode = 5` (XeLaTeX), which `fontspec` needs.

Never replace a file with a build from an unknown source and never drop a
licence text. To update a family, take the new release from the upstream page
above, copy the faces and the licence text, and update the version above.
