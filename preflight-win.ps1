# preflight-win.ps1 — environment check for monarch-kit on Windows
# Run from the monarch-kit repo root: .\preflight-win.ps1
# Use -AndMonarch to run the main kit after preflight succeeds
#
#

param(
    [switch]$AndMonarch,
    [string]$Phase = 'Discovery',
    [string]$OutputPath
)

# --- 1. Remove cached module ---
Remove-Module Monarch -Force -ErrorAction SilentlyContinue

# --- 2. PowerShell version ---
Write-Host 'preflight: checking PowerShell version...' -ForegroundColor DarkGray
$psv = $PSVersionTable.PSVersion
Write-Host "  $($psv.Major).$($psv.Minor).$($psv.Build)"
if ($psv.Major -lt 5 -or ($psv.Major -eq 5 -and $psv.Minor -lt 1)) {
    Write-Host 'preflight FAILED: PowerShell version too old' -ForegroundColor Red
    Write-Host "  ↳ found $psv, need 5.1 or later" -ForegroundColor Red
    Write-Host '  ↳ fix: upgrade to PowerShell 5.1 or later' -ForegroundColor Yellow
    return
}

# --- 3. OS type ---
Write-Host 'preflight: checking Windows edition...' -ForegroundColor DarkGray
$os = Get-CimInstance Win32_OperatingSystem
$productType = $os.ProductType  # 1=Workstation, 2=DC, 3=Server
$osLabel = switch ($productType) { 1 { 'Workstation' } 2 { 'Domain Controller' } 3 { 'Server' } default { 'Unknown' } }
Write-Host "  $($os.Caption) ($osLabel)"
$isServer = $productType -ne 1

# --- 4. ActiveDirectory module (required) ---
Write-Host 'preflight: checking ActiveDirectory module...' -ForegroundColor DarkGray
$ad = Get-Module -ListAvailable ActiveDirectory | Select-Object -First 1
if ($ad) {
    Write-Host "  $($ad.Name) $($ad.Version)"
} else {
    Write-Host 'preflight FAILED: ActiveDirectory module not installed' -ForegroundColor Red
    Write-Host '  ↳ monarch-kit requires RSAT AD tools' -ForegroundColor Red
    if ($isServer) {
        Write-Host '  ↳ fix: Install-WindowsFeature RSAT-AD-PowerShell' -ForegroundColor Yellow
    } else {
        Write-Host '  ↳ fix: Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0' -ForegroundColor Yellow
    }
    return
}

# --- 5. GroupPolicy module (optional) ---
Write-Host 'preflight: checking GroupPolicy module (optional -- GPO functions need this)...' -ForegroundColor DarkGray
$gp = Get-Module -ListAvailable GroupPolicy | Select-Object -First 1
if ($gp) {
    Write-Host "  $($gp.Name) $($gp.Version)"
} else {
    Write-Host 'preflight NOTE: GroupPolicy module not installed -- GPO audit functions will be skipped' -ForegroundColor Yellow
    if ($isServer) {
        Write-Host '  ↳ install: Install-WindowsFeature GPMC' -ForegroundColor Yellow
    } else {
        Write-Host '  ↳ install: Add-WindowsCapability -Online -Name Rsat.GroupPolicy.Management.Tools~~~~0.0.1.0' -ForegroundColor Yellow
    }
}

# --- 6. DnsServer module (optional) ---
Write-Host 'preflight: checking DnsServer module (optional -- DNS functions need this)...' -ForegroundColor DarkGray
$dns = Get-Module -ListAvailable DnsServer | Select-Object -First 1
if ($dns) {
    Write-Host "  $($dns.Name) $($dns.Version)"
} else {
    Write-Host 'preflight NOTE: DnsServer module not installed -- DNS audit functions will be skipped' -ForegroundColor Yellow
    if ($isServer) {
        Write-Host '  ↳ install: Install-WindowsFeature RSAT-DNS-Server' -ForegroundColor Yellow
    } else {
        Write-Host '  ↳ install: Add-WindowsCapability -Online -Name Rsat.Dns.Tools~~~~0.0.1.0' -ForegroundColor Yellow
    }
}

# --- 7. Pester version (optional) ---
Write-Host 'preflight: checking Pester version (optional -- needed for running tests)...' -ForegroundColor DarkGray
$pester = Get-Module -ListAvailable Pester | Sort-Object Version -Descending | Select-Object -First 1
if ($pester -and $pester.Version.Major -ge 5) {
    Write-Host "  Pester $($pester.Version)"
} else {
    $found = if ($pester) { "found Pester $($pester.Version)" } else { 'not installed' }
    Write-Host "preflight NOTE: Pester 5+ not available ($found) -- you can't run the test suite" -ForegroundColor Yellow
    Write-Host '  ↳ install: Install-Module -Name Pester -Force -SkipPublisherCheck' -ForegroundColor Yellow
}

# --- 8. Import Monarch module ---
Write-Host 'preflight: importing Monarch module...' -ForegroundColor DarkGray
try {
    Import-Module "$PSScriptRoot\Monarch.psd1" -Force -ErrorAction Stop
} catch {
    Write-Host 'preflight FAILED: Import-Module Monarch.psd1' -ForegroundColor Red
    Write-Host "  ↳ $($_.Exception.Message)" -ForegroundColor Red
    Write-Host '  ↳ fix: ensure you are running this from the monarch-kit repo root' -ForegroundColor Yellow
    return
}

# --- 9. Verify exported functions ---
Write-Host 'preflight: verifying exported functions...' -ForegroundColor DarkGray
$funcs = @((Get-Module Monarch).ExportedFunctions.Keys)
Write-Host "  $($funcs.Count) functions exported"
if ($funcs.Count -eq 0) {
    Write-Host 'preflight FAILED: module loaded but exported 0 functions' -ForegroundColor Red
    Write-Host '  ↳ Monarch.psd1 FunctionsToExport may be empty or wrong' -ForegroundColor Red
    Write-Host '  ↳ fix: check Monarch.psd1 FunctionsToExport list' -ForegroundColor Yellow
    return
}

# --- 10. Success ---
Write-Host "preflight OK: Monarch loaded ($($funcs.Count) functions), PowerShell $($psv.Major).$($psv.Minor), Windows $osLabel" -ForegroundColor Green

# --- 11. Run main kit if -AndMonarch specified ---
if ($AndMonarch) {
    Write-Host 'preflight: running Monarch...' -ForegroundColor DarkGray
    $invokeParams = @{ Phase = $Phase }
    if ($OutputPath) { $invokeParams['OutputPath'] = $OutputPath }
    Invoke-DomainAudit @invokeParams
}
