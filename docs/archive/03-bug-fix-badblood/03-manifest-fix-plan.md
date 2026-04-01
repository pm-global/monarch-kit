# Step 4 Plan -- Build Honest File Manifest

## Problem

The file tree section in the Discovery report is broken in three ways:

1. **No existence verification.** Paths collected from function results are rendered into HTML without checking if the files/directories actually exist on disk. If a function claims it wrote a file but didn't (error swallowed, early return, conditional skip), the report shows a phantom entry.

2. **No working links.** The current code renders `<span class='folder'>` and plain `<div class='tree-item'>` text. The reference implementation (`report-v5.html`) uses `<a href="..." class="folder">` for folders and `<a href="...">` for linkable files. The CSS already supports this (`.file-tree a.folder:hover`, `.file-tree .tree-item a`) but the code never generates `<a>` tags.

3. **OutputPaths returns directories, not files.** `Export-GPOAudit` returns folder paths (`OutputPaths.Summary`, `.HTML`, `.XML`, etc.) -- these are directories containing files, not individual file paths. The current collection loop adds these directory paths as if they were files, producing entries like `00-SUMMARY` with no children. The reference shows these as folder groups with actual file children underneath.

### The Rule

**When the report is done, the file tree in the HTML must be a 1:1 match of what's on disk under OutputPath.** No empty folders. No empty files. No phantom entries. No missing entries. Whether this is achieved by not creating empties in the first place or by cleaning up after -- doesn't matter. The end state is what matters: report matches disk.

### Scope Boundary

This plan fixes manifest construction and rendering in `New-MonarchReport` only, plus a cleanup pass on the output directory. It does NOT change function return contracts or the orchestrator. Functions already return the paths they have -- the report must work with what it gets.

---

## Current Code (Monarch.psm1 lines 2784-2810)

```powershell
# Collection -- trusts all claimed paths, no verification
$allPaths = @()
foreach ($r in $resultsList) {
    if ($r.PSObject.Properties['OutputPaths'] -and $r.OutputPaths) {
        $r.OutputPaths.PSObject.Properties | Where-Object { $_.Value } | ForEach-Object { $allPaths += $_.Value }
    }
    if ($r.PSObject.Properties['CSVPath'] -and $r.CSVPath) { $allPaths += $r.CSVPath }
    if ($r.PSObject.Properties['OutputFiles'] -and $r.OutputFiles) { $allPaths += @($r.OutputFiles) }
}
# Grouping + rendering -- plain text, no links, no verification
if ($allPaths.Count -gt 0) {
    $groups = @{}
    foreach ($p in $allPaths) {
        $rel = if ($OutputPath -and $p.StartsWith($OutputPath)) { ... } else { $p }
        $parts = $rel -split '[/\\]'
        $folder = if ($parts.Count -gt 1) { $parts[0] } else { '.' }
        # ... groups by first path segment, renders as plain text
    }
}
```

### Three property patterns to handle

| Source Property | Type | Contains | Used by |
|----------------|------|----------|---------|
| `OutputFiles` | `string[]` | Absolute file paths | `New-DomainBaseline` |
| `OutputPaths` | `PSCustomObject` | Absolute directory paths (values may be `$null`) | `Export-GPOAudit` |
| `CSVPath` | `string` | Single absolute file path (or `$null`) | `Find-DormantAccount` |

---

## Design Decisions

**D1: Scan disk, don't trust claims.** Instead of collecting paths from function results and verifying them, scan the OutputPath directory tree directly after all functions complete. This is Decision 3(b) from bb-fix-plan.md -- what's actually on disk is the source of truth. Function claims are irrelevant when you can just look.

**D2: Clean up empties before scanning.** Before building the manifest, remove empty files (0 bytes) and empty directories from OutputPath. The orchestrator pre-creates directories like `01-Baseline`, `02-GPO-Audit`, etc. -- if a function wrote nothing into one, the empty directory must not appear in the report or on disk.

**D3: Generate `<a href>` links for files and folders.** Match the reference implementation:
- Folders: `<a href="01-Baseline/" class="folder">01-Baseline/</a>`
- Files: `<a href="relative/path">filename</a>` inside tree-item div
- All hrefs are relative to the report file's directory (which is `$OutputPath`), forward slashes

**D4: Preserve the existing grouping algorithm.** Group by first path segment. The fix is upstream (what goes INTO the path list) and downstream (HTML rendering), not the grouping itself.

**D5: Empty manifest = no section.** If zero files exist under OutputPath (excluding the report itself), the Output Files section is omitted entirely.

---

## Pass 1 -- Cleanup + Disk Scan + Verification (code change)

**What changes:** Replace lines 2784-2792 in `New-MonarchReport` with disk-based collection.

**Algorithm:**

```
1. Remove empty files (0 bytes) under $OutputPath recursively
2. Remove empty directories under $OutputPath recursively (leaf-first)
   - Exclude the report file itself from cleanup consideration
3. Scan $OutputPath with Get-ChildItem -File -Recurse
   - Exclude the report HTML file (00-Discovery-Report.html)
4. Convert each file's FullName to a path relative to $OutputPath
5. $verifiedPaths = the resulting relative path list
```

**Why scan instead of verify claims:**
- Simpler -- one Get-ChildItem call vs three property-type branches plus per-path Test-Path
- Correct by construction -- impossible to show a file that doesn't exist
- Catches files that functions wrote but didn't report (bonus)
- Future-proof -- new file-producing functions don't need special handling

**Edge cases:**
- Report file itself: excluded from the scan by name match
- Orchestrator-created directories with no content: removed by cleanup, never appear
- `CSVPath` pointing to directory instead of file (Find-DormantAccount quirk): if the directory has files, they appear; if empty, it's cleaned up

---

## Pass 2 -- Relative Paths + Link Generation (code change)

**What changes:** Replace lines 2793-2810 with link-aware rendering.

**Algorithm:**

```
1. $verifiedPaths already contains relative paths from Pass 1
2. Group by first segment -- existing logic, keep it
3. Render with links:
   - Folder line: <a href="FOLDER/" class="folder">FOLDER/</a>
   - File item: <div class='tree-item'><a href="FOLDER/CHILD">CHILD</a></div>
   - href values use forward slashes (HTML convention)
```

**CSS already exists** in report-v5.html but is missing from Monarch.psm1's minified CSS (lines 2672-2676). Add:
- `a.folder:hover` rule (color + underline)
- `.tree-item a` color/decoration rules
- Print media rule: `.file-tree a::after { content: " (" attr(href) ")"; }`

---

## Pass 3 -- Pester Tests

**New tests in the `New-MonarchReport` Describe block:**

### Context: 'File tree matches disk -- verified files only'

Setup:
- Create $TestDrive output directory structure
- Create real files in some subdirectories (e.g., `01-Baseline/domain-info.csv` with content)
- Create one empty subdirectory (e.g., `03-Privileged-Access/` with nothing in it)
- Create one empty file (0 bytes) in another directory
- Create mock orchestrator results (no file properties needed -- scan is disk-based)
- Call New-MonarchReport

Tests:
1. **Real files appear in tree** -- HTML contains filenames of files that exist with content
2. **Empty directory excluded** -- HTML does not contain the empty directory name
3. **Empty file excluded** -- HTML does not contain the 0-byte filename
4. **Folder links are `<a>` tags with href** -- match `<a href='FOLDER/' class='folder'>`
5. **File links are `<a>` tags with href** -- match `<a href='FOLDER/FILE'>`
6. **Report file excluded from tree** -- `00-Discovery-Report.html` does not appear

### Context: 'File tree omitted when no output files exist'

Setup:
- Empty output directory (or only the report file exists)

Tests:
7. **No output-section div in HTML**

### Context: 'Disk cleanup removes empties'

Setup:
- Create directory structure with empty dirs and 0-byte files alongside real files
- Call New-MonarchReport

Tests:
8. **Empty directories removed from disk** -- Test-Path on empty dir returns $false after report generation
9. **Empty files removed from disk** -- Test-Path on 0-byte file returns $false
10. **Real files untouched** -- Test-Path on content-bearing files returns $true

---

## Files Modified

| File | Change |
|------|--------|
| `Monarch.psm1` lines 2672-2676 | Add missing CSS rules for file tree links + print |
| `Monarch.psm1` lines 2784-2810 | Replace with: cleanup empties, scan disk, group, render with links |
| `Tests/Monarch.Tests.ps1` | Add file tree test contexts to New-MonarchReport Describe block |

---

## What This Does NOT Change

- Function return contracts (OutputFiles, OutputPaths, CSVPath stay as-is)
- Orchestrator directory creation or function call logic
- Any other section of the report (dispositions, advisories, critical findings, etc.)
- The design system file tree visual spec (already matches what we're building toward)

---

## Validation Criteria (for the implementer)

After all 3 passes:
1. All existing Pester tests still pass (no regressions)
2. New file tree tests pass
3. Generated HTML file tree matches report-v5.html structure: `<a>` tags for folders and files, relative hrefs, CSS hover/print rules present
4. Phantom paths never appear in the tree
5. Empty directories and empty files are gone from disk after report generation
6. **The file tree in the HTML is a 1:1 match of the OutputPath directory contents on disk** (excluding the report file itself)
