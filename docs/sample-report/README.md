# Sample reports

Three samples, each with a different role. Read this before you treat any of them as correct.

The filenames are poor. They stay as they are because
`docs/validation/effort-03-report-vs-code.txt` anchors seventeen findings to v5 and seventeen
to v9 by filename. A rename would invalidate finished work.

## `demo_report_v5.html`

A fabricated mockup. It was the design target for the report, and it was never implemented.
`docs/reference/report-design-system.md` was extracted from it.

Treat it as an unmet aspiration, not as a description of the tool. The renderer does not
diverge from v5 through regression. It never matched v5 at all.

## `demo_report_v7_badblood/`

The first real report. It was produced by running the module against a lab domain infected
with BadBlood, a script that installs compromised accounts and other hostile data to exercise
security tools.

The full tree stays, including the GPO, XML, and CSV subfolders. Those subfolders are the only
evidence in the repository that `Export-GPOAudit` survives deliberately broken Group Policy
Objects.

The lab was a virtual machine domain, so the finding content has limited value. The value is
the shape of the output under hostile input.

## `demo_report_v9.html`

A real report from a client domain, anonymized. It shows what the module produces today.

**This is the baseline.** Measure changes against v9.

## v10

v10 is defined as v9 plus whatever of v5 is still wanted. The gap list in
`docs/validation/effort-03-report-vs-code.txt` is the input to that work.

When v10 exists, the module gets run against BadBlood again and the v7 tree is replaced whole.
