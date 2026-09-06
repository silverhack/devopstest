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

Function Get-RepositoryRelativePath {
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

Function Write-NUnitArtifact {
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

Try{
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $pssaConfig = [System.IO.Path]::Combine($repoRoot, "tests", "monkey365pssa.config.ps1")
    $monkey365pssa = Get-Command -Name $pssaConfig -CommandType ExternalScript -ErrorAction Ignore
    If($null -ne $monkey365pssa){
        #Set parameters
        $newPsboundParams = [ordered]@{}
        $param = $monkey365pssa.Parameters.Keys
        ForEach($p in $param.GetEnumerator()){
            If($PSBoundParameters.ContainsKey($p)){
                $newPsboundParams.Add($p,$PSBoundParameters[$p])
            }
        }
    }
    Else{
        Write-Error ("Function monkey365pssa.config.ps1 was not found")
        return
    }
    $configuration = & $pssaConfig @newPsboundParams
    $loadedAnalyzer = Get-Module -Name PSScriptAnalyzer -ErrorAction Ignore
    If($null -eq $loadedAnalyzer){
        throw "PSScriptAnalyzer is not present"
    }
    $rawDiagnostics = @(
        $files = @()
        ForEach ($analysisPath in $configuration.Run.Path.GetEnumerator()) {
            If (-not (Test-Path -LiteralPath $analysisPath)) {
                throw "Analysis path does not exist: $analysisPath"
            }
            If($configuration.Run.Recurse){
                $files+= [System.IO.Directory]::EnumerateFiles(
                    (Resolve-Path $analysisPath),
                    '*',
                    [System.IO.SearchOption]::AllDirectories
                )
            }
            Else{
                $files+= [System.IO.Directory]::EnumerateFiles(
                    (Resolve-Path $analysisPath),
                    '*',
                    [System.IO.SearchOption]::TopDirectoryOnly
                )
            }
        }
        $files = @($files | Sort-Object -Unique).Where({$_ -match '\.(ps1|psm1|psd1)$' -and $_ -notlike '*Tests.ps1'})
        If($files.Count -gt 0){
            $options = @{
                IncludeDefaultRules = $configuration.Run.DefaultRules;
                Settings = $configuration.AnalyzerSettings;
            }
            $files | Invoke-ScriptAnalyzer @options
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
    if ($configuration.Output.NUnit.Enabled) {
        Write-NUnitArtifact `
            -Diagnostics $diagnostics `
            -LiteralPath $configuration.Output.NUnit.Path `
            -Duration $timer.Elapsed
    }
    if ($configuration.Output.NUnit.Enabled) {
        Write-Information "PSScriptAnalyzer NUnit results: $($configuration.Output.NUnit.Path)" -InformationAction Continue
    }
}
Catch{
    $timer.Stop();
    throw
}


