<#
.SYNOPSIS
Runs the Monkey365 Pester 6.x test suite and writes structured test artifacts.

.DESCRIPTION
Loads tests/monkey365pester.config.ps1, applies command-line overrides, runs
Pester, and writes JSON summary and failure reports. CI mode also writes NUnit
XML and returns a non-zero process exit code for test or coverage failures.

.PARAMETER Path
One or more test files or directories. The default includes contract, unit, and
smoke tests.

.PARAMETER OutputPath
Directory for JSON, NUnit, and code coverage artifacts. Relative paths are
resolved from the current working directory. The default is repository/logs.

.PARAMETER CI
Enables NUnit output and deterministic process exit codes for CI systems.

.PARAMETER CodeCoverage
Enables JaCoCo code coverage output and evaluates the configured coverage floor.

.PARAMETER IncludeTag
Runs tests carrying at least one supplied tag. Tag is an alias for IncludeTag.

.PARAMETER ExcludeTag
Excludes tests carrying any supplied tag. Defaults to Integration and Slow.
Passing an explicit value, including an empty array, replaces the default.

.EXAMPLE
./tests/Invoke-Tests.ps1

.EXAMPLE
./tests/Invoke-Tests.ps1 -CI -CodeCoverage

.EXAMPLE
./tests/Invoke-Tests.ps1 -Path ./tests/unit -Tag Unit -ExcludeTag @()
#>
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

function Write-JsonArtifact {
    param(
        [Parameter(Mandatory)]
        [object]$InputObject,

        [Parameter(Mandatory)]
        [string]$LiteralPath
    )

    ConvertTo-Json -InputObject $InputObject -Depth 8 |
        Set-Content -LiteralPath $LiteralPath -Encoding utf8
}

function Get-TestErrorDetail {
    param(
        [Parameter(Mandatory)]
        [object]$Test
    )

    $records = [System.Collections.Generic.List[object]]::new()
    foreach ($source in @($Test, $Test.Block, $Test.Block.BlockContainer)) {
        if ($null -ne $source -and $source.PSObject.Properties['ErrorRecord']) {
            foreach ($record in @($source.ErrorRecord)) {
                if ($null -ne $record -and -not $records.Contains($record)) {
                    $records.Add($record)
                }
            }
        }
    }

    $messages = foreach ($record in $records) {
        if ($record.Exception -and -not [string]::IsNullOrWhiteSpace($record.Exception.Message)) {
            $record.Exception.Message
        }
        elseif (-not [string]::IsNullOrWhiteSpace($record.DisplayErrorMessage)) {
            $record.DisplayErrorMessage
        }
        else {
            $record.ToString()
        }
    }

    $stackTraces = foreach ($record in $records) {
        if (-not [string]::IsNullOrWhiteSpace($record.ScriptStackTrace)) {
            $record.ScriptStackTrace
        }
        elseif (-not [string]::IsNullOrWhiteSpace($record.DisplayStackTrace)) {
            $record.DisplayStackTrace
        }
        elseif ($record.Exception -and -not [string]::IsNullOrWhiteSpace($record.Exception.StackTrace)) {
            $record.Exception.StackTrace
        }
    }

    [pscustomobject]@{
        ErrorMessage = ($messages | Select-Object -Unique) -join [Environment]::NewLine
        StackTrace   = ($stackTraces | Select-Object -Unique) -join [Environment]::NewLine
    }
}

$artifactRoot = [System.IO.Path]::GetFullPath($OutputPath)
New-Item -Path $artifactRoot -ItemType Directory -Force | Out-Null

$summaryPath = Join-Path $artifactRoot 'pester-monkey365-summary.json'
$failuresPath = Join-Path $artifactRoot 'pester-failures.json'
$configurationPath = Join-Path $PSScriptRoot 'monkey365pester.config.ps1'
$timer = [System.Diagnostics.Stopwatch]::StartNew()

try {
    $configuration = & $configurationPath `
        -Path $Path `
        -OutputPath $artifactRoot `
        -CI:$CI `
        -CodeCoverage:$CodeCoverage `
        -IncludeTag $IncludeTag `
        -ExcludeTag $ExcludeTag

    $result = Invoke-Pester -Configuration $configuration
    $timer.Stop()

    $failures = @(
        foreach ($test in @($result.Failed)) {
            $details = Get-TestErrorDetail -Test $test
            $container = $test.Block.BlockContainer
            $testFilePath = if ($container.PSObject.Properties['Item']) {
                [string]$container.Item
            }
            elseif ($container.PSObject.Properties['Name']) {
                [string]$container.Name
            }
            else {
                [string]$container
            }
            [pscustomobject][ordered]@{
                TestName     = $test.ExpandedPath
                FilePath     = $testFilePath
                ErrorMessage = $details.ErrorMessage
                StackTrace   = $details.StackTrace
            }
        }
    )

    Write-JsonArtifact -InputObject $failures -LiteralPath $failuresPath

    $coverageTarget = [double]$configuration.CodeCoverage.CoveragePercentTarget.Value
    $coveragePassed = $true
    $coveragePercent = $null
    if ($CodeCoverage) {
        $coveragePercent = [math]::Round([double]$result.CodeCoverage.CoveragePercent, 2)
        $coveragePassed = $coveragePercent -ge $coverageTarget
    }

    $testsPassed = (
        $result.FailedCount -eq 0 -and
        $result.FailedBlocksCount -eq 0 -and
        $result.FailedContainersCount -eq 0
    )
    $succeeded = $testsPassed -and $coveragePassed

    $summary = [ordered]@{
        SchemaVersion         = '1.0'
        Result                = if ($succeeded) { 'Passed' } else { 'Failed' }
        PassedCount           = [int]$result.PassedCount
        FailedCount           = [int]$result.FailedCount
        SkippedCount          = [int]$result.SkippedCount
        InconclusiveCount     = [int]$result.InconclusiveCount
        NotRunCount           = [int]$result.NotRunCount
        TotalCount            = [int]$result.TotalCount
        FailedBlocksCount     = [int]$result.FailedBlocksCount
        FailedContainersCount = [int]$result.FailedContainersCount
        Duration              = $result.Duration.ToString('c')
        DurationSeconds       = [math]::Round($result.Duration.TotalSeconds, 3)
        ExecutedAtUtc         = [DateTimeOffset]::UtcNow.ToString('o')
        PesterVersion         = $result.Version.ToString()
    }

    if ($CodeCoverage) {
        $summary.CoveragePercent = $coveragePercent
        $summary.CoverageTarget = $coverageTarget
    }

    Write-JsonArtifact -InputObject $summary -LiteralPath $summaryPath

    Write-Information "Pester summary: $summaryPath" -InformationAction Continue
    Write-Information "Pester failures: $failuresPath" -InformationAction Continue

    if ($CodeCoverage -and -not $coveragePassed) {
        Write-Warning ("Code coverage {0:N2}% is below the configured target of {1:N2}%." -f `
            $coveragePercent, $coverageTarget)
    }

    if ($CI) {
        if (-not $succeeded) {
            exit 1
        }
        exit 0
    }
}
catch {
    $timer.Stop()

    $infrastructureFailure = @(
        [pscustomobject][ordered]@{
            TestName     = '[Pester infrastructure]'
            FilePath     = $configurationPath
            ErrorMessage = $_.Exception.Message
            StackTrace   = $_.ScriptStackTrace
        }
    )
    Write-JsonArtifact -InputObject $infrastructureFailure -LiteralPath $failuresPath

    $summary = [ordered]@{
        SchemaVersion         = '1.0'
        Result                = 'Failed'
        PassedCount           = 0
        FailedCount           = 1
        SkippedCount          = 0
        InconclusiveCount     = 0
        NotRunCount           = 0
        TotalCount            = 1
        FailedBlocksCount     = 0
        FailedContainersCount = 1
        Duration              = $timer.Elapsed.ToString('c')
        DurationSeconds       = [math]::Round($timer.Elapsed.TotalSeconds, 3)
        ExecutedAtUtc         = [DateTimeOffset]::UtcNow.ToString('o')
        PesterVersion         = $null
    }
    Write-JsonArtifact -InputObject $summary -LiteralPath $summaryPath

    if ($CI) {
        [Console]::Error.WriteLine($_.Exception.Message)
        exit 1
    }

    throw
}
