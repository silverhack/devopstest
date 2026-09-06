[CmdletBinding()]
param(
    [string[]]$Path = @(
        (Join-Path $PSScriptRoot 'contract')
        (Join-Path $PSScriptRoot 'unit')
        (Join-Path $PSScriptRoot 'smoke')
    ),

    [string]$OutputPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'logs'),

    [switch]$CI,

    [switch]$CodeCoverage,

    [Alias('Tag')]
    [string[]]$IncludeTag = @(),

    [string[]]$ExcludeTag = @('Integration', 'Slow')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$loadedPester = Get-Module -Name Pester
if ($loadedPester -and $loadedPester.Version.Major -ne 6) {
    throw "Monkey365 tests require Pester 6.x. Pester $($loadedPester.Version) is already loaded."
}

if (-not $loadedPester) {
    $pesterModule = Get-Module -Name Pester -ListAvailable |
        Where-Object { $_.Version.Major -eq 6 } |
        Sort-Object Version -Descending |
        Select-Object -First 1

    if (-not $pesterModule) {
        throw 'Monkey365 tests require Pester 6.x. Install it with: Install-Module Pester -RequiredVersion 6.0.0 -Scope CurrentUser'
    }

    Import-Module $pesterModule.Path -Force -ErrorAction Stop
}

$repoRoot = (Split-Path $PSScriptRoot -Parent)
$artifactRoot = [System.IO.Path]::GetFullPath($OutputPath)
New-Item -Path $artifactRoot -ItemType Directory -Force | Out-Null

$configuration = New-PesterConfiguration
$configuration.Run.Path = $Path
$configuration.Run.PassThru = $true
$configuration.Run.Exit = $false
$configuration.Run.TestExtension = '.Tests.ps1'
$configuration.Run.RepoRoot = $repoRoot

$configuration.Filter.Tag = $IncludeTag
$configuration.Filter.ExcludeTag = $ExcludeTag

$configuration.Output.Verbosity = 'Detailed'
$configuration.TestRegistry.Enabled = $false

$configuration.TestResult.Enabled = [bool]$CI
$configuration.TestResult.OutputFormat = 'NUnitXml'
$configuration.TestResult.OutputPath = Join-Path $artifactRoot 'pester-results.xml'
$configuration.TestResult.OutputEncoding = 'UTF8'
$configuration.TestResult.TestSuiteName = 'Monkey365'

$configuration.CodeCoverage.Enabled = [bool]$CodeCoverage
$configuration.CodeCoverage.OutputFormat = 'JaCoCo'
$configuration.CodeCoverage.OutputPath = Join-Path $artifactRoot 'coverage.xml'
$configuration.CodeCoverage.OutputEncoding = 'UTF8'
$configuration.CodeCoverage.ExcludeTests = $true
$configuration.CodeCoverage.RecursePaths = $true
$configuration.CodeCoverage.CoveragePercentTarget = 45
$configuration.CodeCoverage.ReportRoot = $repoRoot

if ($CodeCoverage) {
    $coreModulesRoot = Join-Path $repoRoot 'src\monkey365\core\modules'
    $configuration.CodeCoverage.Path = @(
        Get-ChildItem `
            -Path $coreModulesRoot `
            -Include '*.ps1', '*.psm1' `
            -File `
            -Recurse |
            Sort-Object FullName |
            Select-Object -ExpandProperty FullName
    )
}

$configuration
