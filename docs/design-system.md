# Design System

Visual language for all monarch-kit output — HTML reports, console output in the interactive wrapper, and any future tools. Extracted from the Discovery Report reference implementation (report-v5.html).

---

## Design Principles

1. **Skimming is reading.** A reader giving the report zero focused attention still gets value. Headlines, numbers, colors, and position communicate before the text is read.
2. **Data-forward.** Every visual element carries information. No decoration for its own sake.
3. **Silence is success.** Clean domains, zero-error counts, and healthy systems are quiet. Visual weight is reserved for problems.
4. **As little design as possible.** Square corners, no card backgrounds where a border suffices, 1px dividers where 2px is unnecessary. Remove until removing would lose information.
5. **Screenshot-ready top.** The first 400px works as a standalone image in a Teams message or email.
6. **Print is not an afterthought.** The report prints cleanly to A4/Letter with no manual adjustment.
7. **Accent-resilient.** Admin-chosen accent colors cannot break readability. Accents are borders and small fills, never text backgrounds.

---

## Spacing System (Proximity Principle)

Four values. Four meanings. Every vertical margin and padding uses one of these. No exceptions.

| Token | Value | Meaning | Use |
|-------|-------|---------|-----|
| `--gap-micro` | 4px | Within a single component's text stack | domain-tag→description, label→value, wrapped flex row-gap |
| `--gap-tight` | 8px | Within a component group | card→card, section-label→cards, heading→metrics |
| `--gap-related` | 16px | Within a section, between different components | metrics→cards, stats→critical findings, container padding |
| `--gap-separate` | 32px | Between sections | critical→domains, domain→domain, content→output files |

If a gap doesn't fit one of these four, the content hierarchy is wrong — fix the hierarchy, not the spacing.

**Console translation:** Micro = no blank line. Tight = no blank line (indentation distinguishes). Related = one blank line. Separate = two blank lines.

---

## Type Scale

1.25 ratio. Five sizes. Every text element maps to exactly one.

| Token | Value | Use |
|-------|-------|-----|
| `--t1` | 30px | Report title |
| `--t2` | 24px | Stat numbers |
| `--t3` | 19px | Section headers (domain names) |
| `--t4` | 15px | Body text, card descriptions, summary toggles, domain metrics |
| `--t5` | 12px | Labels, metadata, table headers, captions, file tree |

**Line height:** Set per component, never inherited from body. Display elements (numbers, labels, headings) use `1`–`1.2`. Body text uses `1.3`–`1.4`. File trees use `1.8`.

**Console translation:** `--t1` = prominent text. `--t2`/`--t3` = bold/bright. `--t4` = default. `--t5` = `DarkGray` foreground.

---

## Color Palette

### Configurable Accents

Set in `Monarch-Config.psd1`. The report function reads these and injects into CSS variables.

| Key | Default | Use |
|-----|---------|-----|
| `ReportAccentPrimary` | `#2E5090` | Headers, links, section titles |
| `ReportAccentSecondary` | `#B85C14` | Reserved for future use |

### Severity (fixed — never configurable)

| Token | Value | Use |
|-------|-------|-----|
| `--severity-critical` | `#C62828` | Critical stat container fill, critical card left border, critical section label |
| `--severity-critical-light` | `#FFF5F5` | Critical card background tint |
| `--severity-advisory` | `#F9A825` | Advisory stat container fill |
| `--severity-advisory-text` | `#1A1A1A` | Text on advisory fill (dark on yellow for contrast) |

**Critical is red and non-configurable.** The signal for "immediate attention" must be visually consistent across every report from every environment. Admin accent customization cannot dilute this.

### Neutrals (fixed)

| Token | Value | Use |
|-------|-------|-----|
| `--bg-page` | `#FFFFFF` | Page background |
| `--bg-card` | `#F8F9FA` | Table header background only (not card fills) |
| `--text-1` | `#1A1A1A` | Primary text, domain metric labels and values |
| `--text-2` | `#555555` | Metadata, card domain tags, action hints, table headers |
| `--text-3` | `#888888` | Clean domains, file tree connectors, footer |
| `--border-1` | `#E0E0E0` | Domain section dividers (1px), table row borders, file tree connector |
| `--border-2` | `#CCCCCC` | Stats bottom border, table header border |

### Console Color Mapping

| HTML Token | Console Color |
|-----------|---------------|
| `--accent-primary` | `Cyan` |
| `--severity-critical` | `Red` |
| `--severity-advisory` | `Yellow` |
| `--text-1` | Default foreground |
| `--text-2` | `DarkGray` |
| `--text-3` | `DarkGray` |

---

## Component Grammar

### Card Weights

Square corners on all cards. The left border defines the element — rounded corners are decorative without a filled background to ground them. `--card-radius` is retained for stat containers only.

| Weight | Left Border | Background | Use |
|--------|------------|------------|-----|
| Critical | 4px `--severity-critical` | `--severity-critical-light` | Critical findings |
| Advisory | 3px `--severity-advisory` | none (page background) | Advisory items in domain sections |
| Neutral | 3px `--border-2` | none (page background) | Function errors, informational items |

**Card internal spacing:** All MICRO (4px) between text elements inside the card. Card padding: TIGHT (8px) vertical, RELATED (16px) horizontal.

**Console translation:** Critical = `[CRITICAL]` prefix in Red, indented 2 spaces. Advisory = `[ADVISORY]` prefix in Yellow, indented 2 spaces. Neutral = indented 2 spaces, no prefix.

### Stat Containers

Horizontal pill layout with border-radius. Number + label side by side.

| Style | Background | Text Color |
|-------|-----------|------------|
| Critical fill | `--severity-critical` | White |
| Advisory fill | `--severity-advisory` | `--severity-advisory-text` (dark) |
| Outline | 2px `--border-1` border, no fill | `--text-1` (number), `--text-2` (label) |
| Outline zero | 2px `--border-1` border, no fill | `--text-3` (both) |

**Console translation:** `Critical: 2 | Advisory: 7 | Functions: 26 | Errors: 0` — single line, count in respective color.

### Section Labels

Uppercase, letter-spaced, `--t5` size. Used for "Critical Findings", "Function Errors", "Output Files". Spacing to content below: TIGHT (8px). The label belongs to the group it introduces, not floating above it.

### Domain Metrics

Labels and values both use `--text-1`. Only values are bold (`font-weight: 600`). The label earns equal visual presence — the colon and reading order distinguish label from value, not color. Flex wrap with `column-gap: 24px`, `row-gap: 4px` (micro) so wrapped rows stay visually grouped.

### Domain Section Dividers

1px `--border-1`. Confirms boundary without drawing attention. The heading claims the border immediately (TIGHT padding above heading, SEPARATE space above the border).

---

## Table Guidelines

- Default all cells to `white-space: nowrap` — prevents column data from wrapping
- Opt-in to wrapping with `.wrap-ok` class only for cells with legitimately long content (display names, descriptions)
- Use "Age" format for time-since values, not timestamps with "ago" suffix. "22 hours" not "22 hours ago" — reports exist in the present, the suffix is redundant
- Column headers: uppercase, letter-spaced, `--t5` size, `--text-2` color
- Row hover: `--bg-card` background
- Status values use semantic colors: `.status-healthy` (green), `.status-warning` (amber), `.status-failed` (critical red)
- If a table would require wrapping at 960px viewport, it has too many columns — split or use a different presentation
- Expandable tables use `<details>` with a summary line that includes count breakdown: "View 12 replication links (8 healthy, 1 warning, 3 failed)"

---

## Metadata Guidelines

**DC source:** The DC name appears without a prefix. The selection method (health-scored vs fallback) only surfaces when the fallback was used. Absence of annotation means healthy selection — consistent with silence-is-success.

**Timestamps:** Always include timezone abbreviation. The report is a point-in-time document — timezone is part of the timestamp's meaning.

---

## Layout

- Max-width: 960px, centered with auto margins
- Container padding: 40px (reduces to 16px below 600px viewport)
- Single column, top to bottom — no sidebar, no multi-column
- Domain sections ordered by severity when findings exist (safety-critical first)
- Domains with no findings collapsed to a single "No findings: ..." line

---

## File Tree

- Pure directory listing — no counts, no promoted links, no navigation hints
- Folder names are clickable links (open the directory)
- Files with meaningful targets are clickable links
- Tree structure uses left border + indentation, not box-drawing characters
- `::before` pseudo-element for the `─` connector (never wraps separately)
- Built dynamically from the orchestrator's results — only files that were actually generated appear

---

## Print

- `@media print` strips background fills, converts colored borders to grayscale
- Critical border: 4px black. Advisory border: 3px gray.
- Stat containers get a 1px border (fills removed)
- File tree links print their `href` path in parentheses after the link text
- Domain sections avoid page-break splits
- Headings never orphaned at bottom of page
- `<details>` elements should be set to `open` by the report generator before the print-optimized version is written — CSS cannot reliably force-open them
- Narrow viewport rule (600px breakpoint) also benefits print layout

---

## Report Information Hierarchy

1. **First screen (executive):** Title, metadata, stat containers, critical findings table
2. **Middle (operational):** Domain sections with findings, ordered by severity. Clean domains as a single muted line.
3. **Bottom (reference):** Function errors (if any), output file tree, footer

This hierarchy applies to all report types. Future report phases (Remediation, Monitoring, Cleanup) follow the same structure with different domain content.

---

**Reference implementation:** `report-v5.html` in the repo is the canonical visual reference. When in doubt about how a design decision should be applied, check the reference implementation.
