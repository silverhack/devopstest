# Monkey365 - the PowerShell Cloud Security Tool for Azure and Microsoft 365 (copyright 2022) by Juan Garrido
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

<#
.SYNOPSIS
Runs PSScriptAnalyzer and writes pipeline-friendly result artifacts.

.DESCRIPTION
Loads tests/monkey365pssa.config.ps1, applies command-line overrides, runs
PSScriptAnalyzer, and writes normalized JSON results and a JSON summary. CI
mode also writes NUnit XML, emits native GitHub Actions or Azure Pipelines
annotations, and returns a non-zero process exit code when the quality gate
fails.

.PARAMETER Path
One or more PowerShell files or directories to analyze. The defaults cover all
PowerShell source files beneath src/monkey365 while skipping data-only trees.

.PARAMETER OutputPath
Directory for JSON and NUnit artifacts. The default is repository/logs.

.PARAMETER CI
Enables NUnit output, pipeline annotations, and deterministic exit codes.

.PARAMETER Severity
Diagnostic severities to collect. Overrides the global configuration.

.PARAMETER FailOnSeverity
Diagnostic severities that fail the quality gate. Overrides the global
configuration.

.PARAMETER IncludeRule
Runs only the named rules. Overrides the global configuration.

.PARAMETER ExcludeRule
Excludes the named rules. Overrides the global configuration.

.EXAMPLE
./tests/Invoke-Analyzer.ps1

.EXAMPLE
./tests/Invoke-Analyzer.ps1 -CI

.EXAMPLE
./tests/Invoke-Analyzer.ps1 -Severity Error,Warning,Information `
    -FailOnSeverity Error -ExcludeRule PSAvoidUsingWriteHost
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = 'Path')]
    [System.String[]]$Path,

    [Parameter(Mandatory = $false, HelpMessage = 'Recurse')]
    [switch]$Recurse,

    [Parameter(Mandatory = $false, HelpMessage = 'OutputPath')]
    [System.String]$OutputPath,

    [Parameter(Mandatory = $false, HelpMessage = 'NUnitXml')]
    [switch]$CI,

    [Parameter(Mandatory = $false, HelpMessage = 'Severity')]
    [ValidateSet('Error', 'Warning', 'Information')]
    [System.String[]]$Severity,

    [Parameter(Mandatory = $false, HelpMessage = 'FailOnSeverity')]
    [ValidateSet('Error', 'Warning', 'Information')]
    [System.String[]]$FailOnSeverity,

    [Parameter(Mandatory = $false, HelpMessage = 'Include rule')]
    [System.String[]]$IncludeRule,

    [Parameter(Mandatory = $false, HelpMessage = 'Exclude rule')]
    [System.String[]]$ExcludeRule
)

function Write-JsonArtifact {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object]$InputObject,

        [Parameter(Mandatory)]
        [string]$LiteralPath
    )

    ConvertTo-Json -InputObject $InputObject -Depth 8 |
        Set-Content -LiteralPath $LiteralPath -Encoding utf8
}

function Get-RepositoryRelativePath {
    param(
        [Parameter(Mandatory)]
        [string]$LiteralPath,

        [Parameter(Mandatory)]
        [string]$RepositoryRoot
    )

    if ([string]::IsNullOrWhiteSpace($LiteralPath)) {
        return ''
    }

    try {
        return [System.IO.Path]::GetRelativePath($RepositoryRoot, $LiteralPath).
            Replace([System.IO.Path]::DirectorySeparatorChar, '/')
    }
    catch {
        return $LiteralPath
    }
}

function ConvertTo-PipelineText {
    param(
        [AllowEmptyString()]
        [string]$Text,

        [ValidateSet('GitHubProperty', 'GitHubMessage', 'Azure')]
        [string]$Format
    )

    switch ($Format) {
        'GitHubProperty' {
            return $Text.Replace('%', '%25').Replace("`r", '%0D').Replace("`n", '%0A').
                Replace(':', '%3A').Replace(',', '%2C')
        }
        'GitHubMessage' {
            return $Text.Replace('%', '%25').Replace("`r", '%0D').Replace("`n", '%0A')
        }
        'Azure' {
            return $Text.Replace('%', '%25').Replace("`r", '%0D').Replace("`n", '%0A').
                Replace(';', '%3B').Replace(']', '%5D')
        }
    }
}

function Write-PipelineDiagnostic {
    param(
        [Parameter(Mandatory)]
        [object]$Diagnostic
    )

    if ($env:GITHUB_ACTIONS -eq 'true') {
        $level = switch ($Diagnostic.Severity) {
            'Error' { 'error' }
            'Warning' { 'warning' }
            default { 'notice' }
        }
        $properties = @(
            'file={0}' -f (ConvertTo-PipelineText $Diagnostic.FilePath GitHubProperty)
            'line={0}' -f $Diagnostic.Line
            'col={0}' -f $Diagnostic.Column
            'title={0}' -f (ConvertTo-PipelineText $Diagnostic.RuleName GitHubProperty)
        ) -join ','
        $message = ConvertTo-PipelineText $Diagnostic.Message GitHubMessage
        Write-Output "::$level $properties::$message"
    }

    if ($env:TF_BUILD -eq 'True') {
        $level = if ($Diagnostic.IsBlocking) { 'error' } else { 'warning' }
        $properties = @(
            "type=$level"
            'sourcepath={0}' -f (ConvertTo-PipelineText $Diagnostic.FilePath Azure)
            'linenumber={0}' -f $Diagnostic.Line
            'columnnumber={0}' -f $Diagnostic.Column
            'code={0}' -f (ConvertTo-PipelineText $Diagnostic.RuleName Azure)
        ) -join ';'
        $message = ConvertTo-PipelineText $Diagnostic.Message Azure
        Write-Output "##vso[task.logissue $properties;]$message"
    }
}

function Write-NUnitArtifact {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Diagnostics,

        [Parameter(Mandatory)]
        [string]$LiteralPath,

        [Parameter(Mandatory)]
        [TimeSpan]$Duration
    )

    $blocking = @($Diagnostics | Where-Object IsBlocking)
    $testCount = [Math]::Max(1, $Diagnostics.Count)
    $settings = [System.Xml.XmlWriterSettings]::new()
    $settings.Indent = $true
    $settings.Encoding = [System.Text.UTF8Encoding]::new($false)
    $writer = [System.Xml.XmlWriter]::Create($LiteralPath, $settings)

    try {
        $writer.WriteStartDocument()
        $writer.WriteStartElement('test-results')
        $writer.WriteAttributeString('name', 'Monkey365 PSScriptAnalyzer')
        $writer.WriteAttributeString('total', [string]$testCount)
        $writer.WriteAttributeString('errors', '0')
        $writer.WriteAttributeString('failures', [string]$blocking.Count)
        $writer.WriteAttributeString('not-run', '0')
        $writer.WriteAttributeString('inconclusive', '0')
        $writer.WriteAttributeString('ignored', '0')
        $writer.WriteAttributeString('skipped', '0')
        $writer.WriteAttributeString('invalid', '0')
        $writer.WriteAttributeString('date', [DateTime]::UtcNow.ToString('yyyy-MM-dd'))
        $writer.WriteAttributeString('time', [DateTime]::UtcNow.ToString('HH:mm:ss'))

        $writer.WriteStartElement('test-suite')
        $writer.WriteAttributeString('type', 'TestFixture')
        $writer.WriteAttributeString('name', 'PSScriptAnalyzer')
        $writer.WriteAttributeString('executed', 'True')
        $writer.WriteAttributeString('result', $(if ($blocking.Count -eq 0) { 'Success' } else { 'Failure' }))
        $writer.WriteAttributeString('success', $(if ($blocking.Count -eq 0) { 'True' } else { 'False' }))
        $writer.WriteAttributeString('time', $Duration.TotalSeconds.ToString('0.000', [Globalization.CultureInfo]::InvariantCulture))
        $writer.WriteAttributeString('asserts', '0')
        $writer.WriteStartElement('results')

        if ($Diagnostics.Count -eq 0) {
            $writer.WriteStartElement('test-case')
            $writer.WriteAttributeString('name', 'PSScriptAnalyzer.NoDiagnostics')
            $writer.WriteAttributeString('executed', 'True')
            $writer.WriteAttributeString('result', 'Success')
            $writer.WriteAttributeString('success', 'True')
            $writer.WriteAttributeString('time', '0')
            $writer.WriteAttributeString('asserts', '0')
            $writer.WriteEndElement()
        }
        else {
            $index = 0
            foreach ($diagnostic in $Diagnostics) {
                $index++
                $writer.WriteStartElement('test-case')
                $writer.WriteAttributeString('name', ('PSScriptAnalyzer.{0}.{1}:{2}:{3}' -f `
                    $diagnostic.RuleName, $diagnostic.FilePath, $diagnostic.Line, $index))
                $writer.WriteAttributeString('executed', 'True')
                $writer.WriteAttributeString('result', $(if ($diagnostic.IsBlocking) { 'Failure' } else { 'Success' }))
                $writer.WriteAttributeString('success', $(if ($diagnostic.IsBlocking) { 'False' } else { 'True' }))
                $writer.WriteAttributeString('time', '0')
                $writer.WriteAttributeString('asserts', '0')
                if ($diagnostic.IsBlocking) {
                    $writer.WriteStartElement('failure')
                    $writer.WriteElementString('message', ('[{0}] {1}' -f $diagnostic.RuleName, $diagnostic.Message))
                    $writer.WriteElementString('stack-trace', ('{0}:{1}:{2}' -f `
                        $diagnostic.FilePath, $diagnostic.Line, $diagnostic.Column))
                    $writer.WriteEndElement()
                }
                $writer.WriteEndElement()
            }
        }

        $writer.WriteEndElement()
        $writer.WriteEndElement()
        $writer.WriteEndElement()
        $writer.WriteEndDocument()
    }
    finally {
        $writer.Dispose()
    }
}

function Invoke-ScriptAnalyzerWithRetry {
    param(
        [Parameter(Mandatory)]
        [string]$LiteralPath,

        [Parameter(Mandatory)]
        [bool]$Recurse,

        [Parameter(Mandatory)]
        [hashtable]$Settings,

        [ValidateRange(0, 10)]
        [int]$RetryCount = 0
    )

    $threadAffinityError = 'The WriteObject and WriteError methods cannot be called from outside the overrides'
    for ($attempt = 0; $attempt -le $RetryCount; $attempt++) {
        try {
            return @(
                Invoke-ScriptAnalyzer `
                    -Path $LiteralPath `
                    -Recurse:$Recurse `
                    -Settings $Settings `
                    -ErrorAction Stop
            )
        }
        catch {
            $isTransientThreadError = $_.Exception.Message.Contains($threadAffinityError)
            if (-not $isTransientThreadError -or $attempt -ge $RetryCount) {
                throw
            }

            Write-Warning ('PSScriptAnalyzer hit a transient pipeline-thread error for {0}. Retrying ({1}/{2}).' -f `
                $LiteralPath, ($attempt + 1), $RetryCount)
            Start-Sleep -Milliseconds (250 * ($attempt + 1))
        }
    }
}

$configurationPath = Join-Path $PSScriptRoot 'monkey365pssa.config.ps1'
$artifactRoot = [System.IO.Path]::GetFullPath($OutputPath)
New-Item -Path $artifactRoot -ItemType Directory -Force | Out-Null
$timer = [System.Diagnostics.Stopwatch]::StartNew()

try {
    $configurationParameters = @{
        Path       = $Path
        OutputPath = $artifactRoot
        CI         = $CI
    }
    foreach ($parameterName in @('Severity', 'FailOnSeverity', 'IncludeRule', 'ExcludeRule')) {
        if ($PSBoundParameters.ContainsKey($parameterName)) {
            $configurationParameters[$parameterName] = $PSBoundParameters[$parameterName]
        }
    }
    $configuration = & $configurationPath @configurationParameters

    $requiredVersion = [version]$configuration.RequiredModules.PSScriptAnalyzer
    $loadedAnalyzer = Get-Module -Name PSScriptAnalyzer
    if ($loadedAnalyzer -and $loadedAnalyzer.Version -lt $requiredVersion) {
        throw "Monkey365 analysis requires PSScriptAnalyzer $requiredVersion or newer. Version $($loadedAnalyzer.Version) is already loaded."
    }
    if (-not $loadedAnalyzer) {
        $analyzerModule = Get-Module -Name PSScriptAnalyzer -ListAvailable |
            Where-Object Version -ge $requiredVersion |
            Sort-Object Version -Descending |
            Select-Object -First 1
        if (-not $analyzerModule) {
            throw "Monkey365 analysis requires PSScriptAnalyzer $requiredVersion or newer. Install it with: Install-Module PSScriptAnalyzer -MinimumVersion $requiredVersion -Scope CurrentUser"
        }
        Import-Module $analyzerModule.Path -Force -ErrorAction Stop
        $loadedAnalyzer = Get-Module -Name PSScriptAnalyzer
    }

    $rawDiagnostics = @(
        foreach ($analysisPath in $configuration.Run.Path) {
            if (-not (Test-Path -LiteralPath $analysisPath)) {
                throw "Analysis path does not exist: $analysisPath"
            }
            Invoke-ScriptAnalyzerWithRetry `
                -LiteralPath $analysisPath `
                -Recurse $configuration.Run.Recurse `
                -Settings $configuration.AnalyzerSettings `
                -RetryCount $configuration.Run.TransientErrorRetryCount
        }
    )

    $blockingSeverities = @($configuration.QualityGate.FailOnSeverity)
    $diagnostics = @(
        $rawDiagnostics |
            Sort-Object ScriptName, Line, Column, RuleName |
            ForEach-Object {
                $sourcePath = if ($_.Extent -and $_.Extent.File) { $_.Extent.File } else { $_.ScriptName }
                $relativePath = Get-RepositoryRelativePath `
                    -LiteralPath $sourcePath `
                    -RepositoryRoot $configuration.RepositoryRoot
                [pscustomobject][ordered]@{
                    RuleName          = [string]$_.RuleName
                    Severity          = [string]$_.Severity
                    Message           = [string]$_.Message
                    FilePath          = $relativePath
                    Line              = [int]$_.Line
                    Column            = [int]$_.Column
                    EndLine           = [int]$_.Extent.EndLineNumber
                    EndColumn         = [int]$_.Extent.EndColumnNumber
                    RuleSuppressionId = [string]$_.RuleSuppressionID
                    IsBlocking        = [string]$_.Severity -in $blockingSeverities
                }
            }
    )
    $timer.Stop()

    $blockingDiagnostics = @($diagnostics | Where-Object IsBlocking)
    $summary = [pscustomobject][ordered]@{
        SchemaVersion           = '1.0'
        Result                  = if ($blockingDiagnostics.Count -eq 0) { 'Passed' } else { 'Failed' }
        DiagnosticCount         = $diagnostics.Count
        BlockingDiagnosticCount = $blockingDiagnostics.Count
        ErrorCount              = @($diagnostics | Where-Object Severity -eq 'Error').Count
        WarningCount            = @($diagnostics | Where-Object Severity -eq 'Warning').Count
        InformationCount        = @($diagnostics | Where-Object Severity -eq 'Information').Count
        Duration                = $timer.Elapsed.ToString('c')
        DurationSeconds         = [math]::Round($timer.Elapsed.TotalSeconds, 3)
        ExecutedAtUtc           = [DateTimeOffset]::UtcNow.ToString('o')
        PSScriptAnalyzerVersion = $loadedAnalyzer.Version.ToString()
    }

    Write-JsonArtifact -InputObject $diagnostics -LiteralPath $configuration.Output.Json
    Write-JsonArtifact -InputObject $summary -LiteralPath $configuration.Output.SummaryJson

    if ($configuration.Output.NUnit.Enabled) {
        Write-NUnitArtifact `
            -Diagnostics $diagnostics `
            -LiteralPath $configuration.Output.NUnit.Path `
            -Duration $timer.Elapsed
    }

    foreach ($diagnostic in $diagnostics) {
        Write-Information ('{0}:{1}:{2} [{3}/{4}] {5}' -f `
            $diagnostic.FilePath, $diagnostic.Line, $diagnostic.Column,
            $diagnostic.Severity, $diagnostic.RuleName, $diagnostic.Message) `
            -InformationAction Continue
        if ($CI) {
            Write-PipelineDiagnostic -Diagnostic $diagnostic
        }
    }

    Write-Information "PSScriptAnalyzer summary: $($configuration.Output.SummaryJson)" -InformationAction Continue
    Write-Information "PSScriptAnalyzer results: $($configuration.Output.Json)" -InformationAction Continue
    if ($configuration.Output.NUnit.Enabled) {
        Write-Information "PSScriptAnalyzer NUnit results: $($configuration.Output.NUnit.Path)" -InformationAction Continue
    }

    if ($CI) {
        if ($blockingDiagnostics.Count -gt 0) {
            exit 1
        }
        exit 0
    }
}
catch {
    $timer.Stop()
    $failure = @(
        [pscustomobject][ordered]@{
            RuleName          = 'PSScriptAnalyzerInfrastructure'
            Severity          = 'Error'
            Message           = $_.Exception.Message
            FilePath          = Get-RepositoryRelativePath `
                -LiteralPath $configurationPath `
                -RepositoryRoot (Split-Path $PSScriptRoot -Parent)
            Line              = 0
            Column            = 0
            EndLine           = 0
            EndColumn         = 0
            RuleSuppressionId = ''
            IsBlocking        = $true
        }
    )
    $summary = [pscustomobject][ordered]@{
        SchemaVersion           = '1.0'
        Result                  = 'Failed'
        DiagnosticCount         = 1
        BlockingDiagnosticCount = 1
        ErrorCount              = 1
        WarningCount            = 0
        InformationCount        = 0
        Duration                = $timer.Elapsed.ToString('c')
        DurationSeconds         = [math]::Round($timer.Elapsed.TotalSeconds, 3)
        ExecutedAtUtc           = [DateTimeOffset]::UtcNow.ToString('o')
        PSScriptAnalyzerVersion = $null
    }

    $fallbackResultsPath = Join-Path $artifactRoot 'psscriptanalyzer-results.json'
    $fallbackSummaryPath = Join-Path $artifactRoot 'psscriptanalyzer-summary.json'
    Write-JsonArtifact -InputObject $failure -LiteralPath $fallbackResultsPath
    Write-JsonArtifact -InputObject $summary -LiteralPath $fallbackSummaryPath

    if ($CI) {
        $fallbackNUnitPath = Join-Path $artifactRoot 'psscriptanalyzer-results.xml'
        Write-NUnitArtifact -Diagnostics $failure -LiteralPath $fallbackNUnitPath -Duration $timer.Elapsed
        Write-PipelineDiagnostic -Diagnostic $failure[0]
        [Console]::Error.WriteLine($_.Exception.Message)
        exit 1
    }

    throw
}
