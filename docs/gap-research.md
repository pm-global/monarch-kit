# Research Brief: monarch-kit

**Raw idea:** PowerShell module for Active Directory auditing.
**Domain:** Active Directory auditing and administration on Windows/PowerShell.
**Problem class:** Read environment state, analyze it, and produce a trustworthy audit report with optional file outputs.
**Research date:** 2026-03-30
**Key finding:** The core architecture is already aligned with the domain, but the highest-value improvements are trust, deployability, and run-state visibility rather than more audit checks.

## Platform Constraints

**Platform:** Windows PowerShell 5.1+ with the ActiveDirectory module; GroupPolicy and DnsServer are optional.

- PowerShell 5.1+ and Windows host support are required for the module. Source: project docs.
- ActiveDirectory is the core dependency; GroupPolicy and DnsServer are optional runtime checks. Source: project docs.
- RSAT is the usual way to get the AD PowerShell module on Windows clients, while Windows Server can install the tools as features/roles. Source: Microsoft and community docs.
- Direct AD cmdlet access is the primary execution model, so host readiness and domain connectivity matter before any useful audit work can happen. Source: project docs and AD module setup guidance.

Implications: The design should assume a domain-joined Windows admin environment, not a portable cross-platform utility. Preflight validation is essential because missing modules, missing RSAT, or weak connectivity can fail the run before discovery starts.

## Established Patterns

### Read-only discovery
- How it works: Query AD, GPO, DNS, and policy state directly, then emit structured findings.
- Optimizes for: Safety, simplicity, and broad compatibility.
- Sacrifices: Live remediation and deeper workflow automation.
- Common in: Audit modules and security posture tools.

### Orchestrated phase pipeline
- How it works: A top-level runner executes domain-specific checks in sequence, isolates failures, and produces one report.
- Optimizes for: Reliable execution and consistent output.
- Sacrifices: Pure modularity if orchestration becomes too central.
- Common in: Larger audit suites.

### Baseline comparison
- How it works: Compare live configuration to a known-good baseline or standard.
- Optimizes for: Drift detection and compliance review.
- Sacrifices: Context; a difference is not always a problem.
- Common in: GPO and security baseline tools.

### Graph / path analysis
- How it works: Collect relationship data and analyze privilege paths or attack paths.
- Optimizes for: Security insight and privilege visibility.
- Sacrifices: Simplicity and readability for general administrators.
- Common in: Attack-path tooling.

Default recommendation: Keep read-only discovery and orchestrated reporting as the core. Add baseline comparison and graph-style analysis only if they remain clearly separated from the main audit path.
Anti-patterns: One-score-only reporting, opaque severity labels without evidence, and tightly coupling detection with interpretation.

## Known Failure Modes

- Replication lag and timestamp floors: `lastLogonTimestamp` can lag real activity, so dormancy logic needs a safety window and per-DC cross-checks near the threshold. Impact: false dormant-account findings. Mitigation: threshold buffer plus near-cutoff verification.
- Missing module/features: without RSAT or the required Windows modules, AD cmdlets fail early. Impact: no scan or partial scan. Mitigation: preflight environment validation.
- Optional subsystem absence: DNS/GPO-related checks can fail if optional modules are not present. Impact: partial report coverage. Mitigation: graceful degradation and clear warnings.
- Permissions variance: read access may be enough for some discovery, but not all environments expose the same breadth of data. Impact: incomplete findings or access-denied noise. Mitigation: per-call error handling and a warnings model.
- Overconfident security scoring: broad posture tools are useful when they explain evidence, not when they only produce a score. Impact: misleading remediation priorities. Mitigation: separate raw observation from interpretation and make confidence visible.
- Partial outages during run: a DC, service, or API may become unavailable mid-audit. Impact: uneven report completeness. Mitigation: orchestrator-level failure isolation with explicit degraded-state reporting.

## Available Building Blocks

### Libraries
- ActiveDirectory module: core AD querying cmdlets.
- GroupPolicy module: GPO export and review workflows.
- DnsServer module: AD-integrated DNS inspection when present.
- Pester: standard PowerShell unit test framework.

### APIs / Services
- On-prem AD via PowerShell cmdlets: primary data source for discovery.
- GPO backups and exports: useful for comparison and audit workflows.
- Domain controller discovery: standard AD discovery with optional health scoring.

### Testing / Mocking
- Pester mocks: suitable for isolating AD cmdlets so tests can run without a live domain.
- Orchestrator tests: important for partial failure, degraded paths, and report-generation behavior.

Landscape note: The ecosystem is mature but specialized. There is no single framework that replaces direct AD cmdlets, so serious tools usually layer domain logic on top of Microsoft modules.

## Prior Art

### BloodHound
- Scope: AD and identity relationship analysis, now extending beyond AD in newer directions.
- Structure: graph-driven collection and analysis.
- Strengths: Attack-path discovery and privilege visibility.
- Weaknesses: Graph complexity can overwhelm non-specialists.
- Relevant learning: Relationship-heavy views should be separated from plain audit findings.

### PingCastle
- Scope: Broad AD security assessment and remediation prioritization.
- Structure: scan-and-report posture tool.
- Strengths: Security-focused summary reporting.
- Weaknesses: Broad posture tools can hide the evidence behind the score.
- Relevant learning: Graded findings are useful only when criteria are transparent.

### Microsoft Policy Analyzer
- Scope: GPO and baseline comparison.
- Structure: import-and-compare utility.
- Strengths: Fast drift analysis.
- Weaknesses: Only as useful as the reference baseline.
- Relevant learning: Comparison workflows are distinct from discovery workflows.

Calibration: Your current function set is already in the same class as mature audit tools. What still needs work is the surrounding operational layer that makes the tool easier to deploy, validate, and trust.

## Expert Response Forecast

### Likely praise
- The architecture is aligned with the domain because it is read-only, structured, and orchestrated.
- The domain partitioning reflects real admin mental models rather than arbitrary feature slicing.
- The return-contract discipline is strong and should make downstream automation easier.

### Likely criticism
- The report needs explicit trust metadata: what was checked, what failed, what was skipped, and how reliable each result is.
- A preflight/readiness path is missing or underemphasized.
- Progress, status, and silent-mode behavior need to be defined more clearly.
- Orchestrator-level tests and failure-path tests are more important now than additional leaf-function tests.
- The report should clearly mark degraded sections instead of looking complete when data sources were missing.

### Likely deemed lower value
- More generic scoring before the evidence and confidence model is explicit.
- Additional audit checks before the deployment, validation, and run-state UX are improved.
- Any output that obscures raw evidence behind a score or one-line verdict.

## What To Improve First

### 1. Preflight and readiness
Add a first-class environment validation command that checks PowerShell version, AD module availability, optional modules, domain reachability, and likely permission fit before discovery begins.

### 2. Run-state visibility
Provide concise progress/status output during orchestrated runs, with verbose detail available and a silent mode for automation.

### 3. Degraded-state reporting
Make missing modules, partial outages, and skipped sections explicit in the structured output and the HTML report.

### 4. Orchestrator tests
Add tests for DC resolution fallback, partial failures, optional module absence, report generation after degradation, and silent/verbose behavior.

### 5. Deployment guidance
Add a short first-run guide that explains RSAT, supported hosts, permissions expectations, and a known-good invocation.

## What The Existing Design Already Gets Right

- The separation between observation and interpretation is exactly the right boundary for AD auditing.
- Structured objects as the primary output are the right foundation for downstream automation.
- Optional modules that degrade gracefully are better than hard failures in mixed environments.
- A central orchestrator is the correct place to normalize domain resolution and error handling.
- Returning file paths alongside structured objects is the right model for export-producing functions.

## Missing Or Irrelevant

### Missing
- A formal preflight/readiness command.
- A run-state model for progress, warnings, degraded sections, and silent mode.
- Explicit confidence or detection tiers for any fields that are inherently imperfect.
- More integration-style tests around the orchestrator and report generation.
- A deployment/readiness guide that mirrors real admin usage.

### Lower priority for now
- Expanding to graph-heavy analysis before the core audit workflow is hardened.
- Adding more generic scoring without evidence and confidence semantics.
- Collapsing remediation or monitoring into the discovery path.

## Quality Bar For The Next Iteration

A reviewer should be able to answer these questions from the report alone:
1. Was the environment valid enough to trust the results?
2. What was checked, what was skipped, and why?
3. Which findings are robust versus incomplete or approximate?
4. What should an admin do first after reading the report?

If the answer to any of those is unclear, the software is still missing the trust layer that makes AD audit tooling feel credible in production.
