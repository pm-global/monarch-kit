# TODO-2: Fix Two Pre-Existing Failing Tests

## Goal

Fix the two tests that were failing before TODO-1 work began. Both are test
bugs — no production code changes.

## Failures

### 1. `Export-GPOAudit` — sanitizes filenames

**File:** `Tests/Monarch.Tests.ps1` ~L3037  
**Assertion:** `$indexContent | Should -Match "href='Bad_Name_Test_Policy\.html'"`  
**Actual output:** `href='GPOs/Bad_Name_Test_Policy.html'`

The href correctly includes the `GPOs/` subdirectory prefix; the assertion
doesn't. One-character fix: add `GPOs/` to the pattern.

**Fix:** `href='GPOs/Bad_Name_Test_Policy\.html'`

---

### 2. `Invoke-DomainAudit` — Write-Warning with combine context

**File:** `Tests/Monarch.Tests.ps1` ~L5893–5937  
**Assertion:** `Should -Invoke Write-Warning -ModuleName Monarch -Times 1 -ParameterFilter { $Message -match 'combine' }`

**Root cause:** Pester does not count mock invocations that occur during
`BeforeAll` execution when `Should -Invoke` is asserted in a subsequent `It`
block. `Invoke-DomainAudit` runs in `BeforeAll`; the orchestrator calls
`Write-Warning` from inside the catch block during that run; the call is
invisible to `Should -Invoke` in the `It`.

This is not a pipeline-vs-InputObject issue (both behave identically).
The code at `Monarch.psm1:3162` is correct.

**Fix:** Move `Invoke-DomainAudit` out of `BeforeAll` and into the single
`It` block. The context has only one `It`, so no other assertions are
affected.

```powershell
# Before
BeforeAll {
    # ... mocks ...
    $script:result = Invoke-DomainAudit -Phase Discovery -OutputPath $script:outDir
}
It 'emits Write-Warning with combine context' {
    Should -Invoke Write-Warning -ModuleName Monarch -Times 1 -ParameterFilter { $Message -match 'combine' }
}

# After
BeforeAll {
    # ... mocks ...
    $script:outDir = Join-Path $TestDrive 'roast-exportfail'
}
It 'emits Write-Warning with combine context' {
    Invoke-DomainAudit -Phase Discovery -OutputPath $script:outDir
    Should -Invoke Write-Warning -ModuleName Monarch -Times 1 -ParameterFilter { $Message -match 'combine' }
}
```

## Definition of done

- Both tests pass.
- No other tests newly fail.
- No changes to `Monarch.psm1`.
