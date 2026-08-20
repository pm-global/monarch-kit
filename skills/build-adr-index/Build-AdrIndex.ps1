#Requires -Version 5.1
<#
.SYNOPSIS
    Builds docs/adr/README.md as a dependency-ordered index of this repo's ADRs.
.DESCRIPTION
    Reads the depends-on and superseded-by frontmatter of every ADR, sorts the active
    records so a record always follows the records it depends on, and writes the index.
    The script builds the whole index from the ADR files and overwrites the previous
    index, so a second call is safe and nothing accumulates.
#>
[CmdletBinding()]
param(
    [string]$AdrPath = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' 'docs' 'adr'))
)

$ErrorActionPreference = 'Stop'

function Read-AdrFile {
    param([Parameter(Mandatory)][System.IO.FileInfo]$File)

    $text = Get-Content -Path $File.FullName -Raw
    $frontmatter = [regex]::Match($text, '(?s)\A---\r?\n(.*?)\r?\n---')
    if (-not $frontmatter.Success) {
        throw "$($File.Name) has no frontmatter. Add depends-on and superseded-by."
    }

    $fields = $frontmatter.Groups[1].Value
    $dependsLine = [regex]::Match($fields, '(?m)^depends-on:\s*(.*)$').Groups[1].Value
    $supersededLine = [regex]::Match($fields, '(?m)^superseded-by:\s*(.*)$').Groups[1].Value

    [PSCustomObject]@{
        Number       = [regex]::Match($File.Name, '^\d+').Value
        Title        = [regex]::Match($text, '(?m)^#\s+(.+)$').Groups[1].Value.Trim()
        DependsOn    = @([regex]::Matches($dependsLine, '\d+') | ForEach-Object { $_.Value })
        SupersededBy = [regex]::Match($supersededLine, '\d+').Value
        FileName     = $File.Name
    }
}

function Sort-AdrByDependency {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Adrs)

    $remaining = [System.Collections.ArrayList]@($Adrs)
    $placed = @{}
    $ordered = @()

    while ($remaining.Count -gt 0) {
        $ready = @($remaining |
            Where-Object { @($_.DependsOn | Where-Object { -not $placed.ContainsKey($_) }).Count -eq 0 } |
            Sort-Object Number)

        # An empty ready set means a cycle, or a depends-on pointing at an ADR that is
        # absent or superseded. Name the records so the author can find the break.
        if ($ready.Count -eq 0) {
            $stuck = ($remaining | ForEach-Object { "ADR-$($_.Number)" }) -join ', '
            throw "Cannot order these ADRs. Check depends-on for a cycle or a missing record: $stuck"
        }

        foreach ($adr in $ready) {
            $ordered += $adr
            $placed[$adr.Number] = $true
            $remaining.Remove($adr)
        }
    }

    $ordered
}

function Format-AdrLine {
    param([Parameter(Mandatory)][object]$Adr, [string]$Note)

    $line = "- **[ADR-$($Adr.Number)]($($Adr.FileName))** — $($Adr.Title)"
    if ($Note) { $line += " _($Note)_" }
    $line
}

$adrs = @(Get-ChildItem -Path $AdrPath -Filter '*.md' |
    Where-Object { $_.Name -match '^\d{4}-' } |
    ForEach-Object { Read-AdrFile -File $_ })

if ($adrs.Count -eq 0) {
    throw "No ADRs found in $AdrPath."
}

$active = @($adrs | Where-Object { -not $_.SupersededBy })
$superseded = @($adrs | Where-Object { $_.SupersededBy } | Sort-Object Number)

$referenced = @{}
foreach ($adr in $active) {
    foreach ($number in $adr.DependsOn) { $referenced[$number] = $true }
}

$independent = @($active | Where-Object {
    $_.DependsOn.Count -eq 0 -and -not $referenced.ContainsKey($_.Number)
} | Sort-Object Number)

$chained = @($active | Where-Object { $independent -notcontains $_ })

$lines = @(
    '# Architecture decision records'
    ''
    '`skills/build-adr-index/Build-AdrIndex.ps1` builds this file. Do not edit it by hand.'
    ''
    'The records appear in dependency order, so a record always follows the records it'
    'depends on. The file numbers carry no meaning beyond the order the records were written.'
    ''
    '## Decisions'
    ''
)

foreach ($adr in Sort-AdrByDependency -Adrs $chained) {
    $note = if ($adr.DependsOn.Count -gt 0) {
        'depends on ' + (($adr.DependsOn | ForEach-Object { "ADR-$_" }) -join ', ')
    }
    $lines += Format-AdrLine -Adr $adr -Note $note
}

if ($independent.Count -gt 0) {
    $lines += @('', '## Independent decisions', '', 'These records sit outside every dependency chain.', '')
    foreach ($adr in $independent) { $lines += Format-AdrLine -Adr $adr }
}

if ($superseded.Count -gt 0) {
    $lines += @('', '## Superseded', '')
    foreach ($adr in $superseded) {
        $lines += Format-AdrLine -Adr $adr -Note "superseded by ADR-$($adr.SupersededBy)"
    }
}

Set-Content -Path (Join-Path $AdrPath 'README.md') -Value ($lines -join "`n") -Encoding UTF8

[PSCustomObject]@{
    Recorded    = $adrs.Count
    Chained     = $chained.Count
    Independent = $independent.Count
    Superseded  = $superseded.Count
}
