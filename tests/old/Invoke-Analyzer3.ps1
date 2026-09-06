#requires -Version 6.0
Function Add-XmlElement {
    param(
        [System.Xml.XmlNode] $Parent,
        [string] $Name,
        [System.Collections.IDictionary] $Attributes
    )

    $element = $document.CreateElement($Name)
    if ($null -ne $Attributes) {
        foreach ($key in $Attributes.Keys) {
            if ($null -ne $Attributes[$key]) {
                $element.SetAttribute([string] $key, $Attributes[$key])
            }
        }
    }
    [void] $Parent.AppendChild($element)
    return $element
}

Function Add-CDataElement {
    param(
        [System.Xml.XmlNode] $Parent,
        [string] $Name,
        [AllowNull()] [object] $Value
    )

    $element = Add-XmlElement -Parent $Parent -Name $Name
    [void] $element.AppendChild($document.CreateCDataSection($Value))
    return $element
}

Function Add-PropertyContainer {
    param(
        [System.Xml.XmlNode] $Parent,
        [System.Collections.IDictionary] $Values
    )

    $propertiesElement = Add-XmlElement -Parent $Parent -Name 'properties'
    foreach ($key in $Values.Keys) {
        if ($null -ne $Values[$key] -and -not [string]::IsNullOrWhiteSpace([string] $Values[$key])) {
            [void] (Add-XmlElement -Parent $propertiesElement -Name 'property' -Attributes ([ordered]@{
                name  = [string] $key
                value = [string] $Values[$key]
            }))
        }
    }
    return $propertiesElement
}

#I need to add isBlocking
#$blockingDiagnostics = @($diagnostics | Where-Object IsBlocking)
Function Get-ResultSummary {
    param([object[]] $Cases)

    $passed = @($Cases).Where({$_.Result -eq "Passed"}).Count
    $failed = @($Cases).Where({$_.Result -eq "Failed"}).Count
    $inconclusive = @($Cases).Where({$_.Result -eq "Inconclusive"}).Count
    $skipped = @($Cases).Where({$_.Result -eq "Skipped"}).Count
    $asserts = ($Cases | Measure-Object -Property Asserts -Sum).Sum
    If ($null -eq $asserts) { $asserts = 0 }

    $result = If ($failed -gt 0) {
        'Failed'
    }
    ElseIf ($inconclusive -gt 0) {
        'Inconclusive'
    }
    ElseIf ($Cases.Count -gt 0 -and $skipped -eq $Cases.Count) {
        'Skipped'
    }
    Else {
        'Passed'
    }

    return [pscustomobject]@{
        Total        = $Cases.Count
        Passed       = $passed
        Failed       = $failed
        Inconclusive = $inconclusive
        Skipped      = $skipped
        Asserts      = [int] $asserts
        Result       = $result
    }
}

Function Get-RepositoryRelativePath {
    param(
        [Parameter(Mandatory)]
        [string]$LiteralPath,

        [Parameter(Mandatory)]
        [string]$RepositoryRoot
    )

    If ([string]::IsNullOrWhiteSpace($LiteralPath)) {
        return ''
    }

    Try {
        return [System.IO.Path]::GetRelativePath($RepositoryRoot, $LiteralPath).
            Replace([System.IO.Path]::DirectorySeparatorChar, '/')
    }
    Catch {
        return $LiteralPath
    }
}
$ModuleName = "monkey365"
$ModulePath = "c:\monkey365";
$StartTime = [datetime]::UtcNow
$EndTime = $null
$TreatSuppressedAsSkipped = $true
$repoRoot = "C:/monkey365"
$groups = [ordered]@{}
ForEach ($record in $results) {
    $sourcePath = If ($record.Extent -and $record.Extent.File) { $record.Extent.File } ElseIf ($record.ScriptName){$record.ScriptName} Else {'<script-definition>'}
    $path = Get-RepositoryRelativePath -LiteralPath $sourcePath -RepositoryRoot $repoRoot
    $rule = $record | Select-Object -ExpandProperty RuleName -ErrorAction Ignore
    If ([string]::IsNullOrWhiteSpace($rule)) {
        $rule = '<unknown-rule>'
    }
    $key = $path + [char] 0x001F + $rule
    If (-not $groups.Contains($key)) {
        $groups[$key] = [pscustomobject]@{
            Path    = $path
            Rule    = $rule
            Records = [System.Collections.Generic.List[object]]::new()
        }
    }
    $groups[$key].Records.Add($record)
}
$caseModels = [System.Collections.Generic.List[object]]::new()
foreach ($group in $groups.Values) {
    $recordArray = @($group.Records)
    $allSuppressed = $recordArray.Count -gt 0 -and $recordArray.Where({$_.IsSuppressed}).Count -eq $recordArray.Count
    $result = if ($recordArray.Count -eq 0) {
        'Passed'
    }
    elseif ($TreatSuppressedAsSkipped -and $allSuppressed) {
        'Skipped'
    }
    else {
        'Failed'
    }
    $asserts = if ($result -eq 'Passed') { 1 } elseif ($result -eq 'Failed') { $recordArray.Count } else { 0 }

    $caseModels.Add([pscustomobject]@{
        Path    = $group.Path
        Rule    = $group.Rule
        Records = $recordArray
        Result  = $result
        Asserts = $asserts
    })
}
$caseModels = @($caseModels | Sort-Object Path, Rule)
$summary = Get-ResultSummary -Cases $caseModels
$finishTime = if ($EndTime.HasValue) { $EndTime.Value.ToUniversalTime() } else { [datetime]::UtcNow }
$beginTime = $StartTime.ToUniversalTime()
$duration = [math]::Max(0, ($finishTime - $beginTime).TotalSeconds)
$durationText = $duration.ToString('0.000000', [Globalization.CultureInfo]::InvariantCulture)
$startText = $beginTime.ToString('yyyy-MM-dd HH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
$endText = $finishTime.ToString('yyyy-MM-dd HH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)

$document = [System.Xml.XmlDocument]::new()
[void] $document.AppendChild($document.CreateXmlDeclaration('1.0', 'utf-8', $null))
$run = Add-XmlElement -Parent $document -Name 'test-run' -Attributes ([ordered]@{
            id              = '0'
            testcasecount   = $summary.Total
            result          = $summary.Result
            total           = $summary.Total
            passed          = $summary.Passed
            failed          = $summary.Failed
            inconclusive    = $summary.Inconclusive
            skipped         = $summary.Skipped
            asserts         = $summary.Asserts
            'engine-version'= 'PSScriptAnalyzer-NUnit3-Converter/1.0'
            'clr-version'   = [Environment]::Version.ToString()
            'start-time'    = $startText
            'end-time'      = $endText
            duration        = $durationText
        })

#[void] (Add-CDataElement -Parent $run -Name 'command-line' -Value $CommandLine)
$suiteAttributes = [ordered]@{
    id              = '0-1000'
    name            = $ModuleName
    fullname        = if ($ModulePath) { $ModulePath } else { $ModuleName }
    testcasecount   = $summary.Total
    runstate        = 'Runnable'
    result          = $summary.Result
    'start-time'    = $startText
    'end-time'      = $endText
    duration        = $durationText
    total           = $summary.Total
    passed          = $summary.Passed
    failed          = $summary.Failed
    inconclusive    = $summary.Inconclusive
    skipped         = $summary.Skipped
    asserts         = $summary.Asserts
}

$projectAttributes = [ordered]@{ type = 'Project' }
foreach ($entry in $suiteAttributes.GetEnumerator()) { $projectAttributes[$entry.Key] = $entry.Value }
$projectSuite = Add-XmlElement -Parent $run -Name 'test-suite' -Attributes $projectAttributes
[void] (Add-PropertyContainer -Parent $projectSuite -Values ([ordered]@{
    Module     = $ModuleName
    ModulePath = $ModulePath
    Generator  = 'ConvertTo-PSScriptAnalyzerNUnit3'
}))
$assemblyAttributes = [ordered]@{ type = 'Assembly' }
foreach ($entry in $suiteAttributes.GetEnumerator()) { $assemblyAttributes[$entry.Key] = $entry.Value }
$assemblyAttributes.id = '0-1001'
$assemblyAttributes.name = 'PSScriptAnalyzer'
$assemblySuite = Add-XmlElement -Parent $projectSuite -Name 'test-suite' -Attributes $assemblyAttributes
$nextId = 1002
foreach ($fileGroup in ($caseModels | Group-Object Path)) {
    $fileCases = @($fileGroup.Group)
    $fileSummary = Get-ResultSummary -Cases $fileCases
    $fixtureId = '0-{0}' -f $nextId
    $nextId++
    $filePath = [string] $fileGroup.Name
    $fileName = if ($filePath -eq '<script-definition>') { $filePath } else { [System.IO.Path]::GetFileName($filePath) }
    $className = '{0}.{1}' -f $ModuleName, ([System.IO.Path]::GetFileNameWithoutExtension($fileName) -replace '[^A-Za-z0-9_.-]', '_')

    $fixture = Add-XmlElement -Parent $assemblySuite -Name 'test-suite' -Attributes ([ordered]@{
        type            = 'TestFixture'
        id              = $fixtureId
        name            = $fileName
        fullname        = $filePath
        classname       = $className
        testcasecount   = $fileSummary.Total
        runstate        = 'Runnable'
        result          = $fileSummary.Result
        'start-time'    = $startText
        'end-time'      = $endText
        duration        = $durationText
        total           = $fileSummary.Total
        passed          = $fileSummary.Passed
        failed          = $fileSummary.Failed
        inconclusive    = $fileSummary.Inconclusive
        skipped         = $fileSummary.Skipped
        asserts         = $fileSummary.Asserts
    })
    [void] (Add-PropertyContainer -Parent $fixture -Values ([ordered]@{
        Module     = $ModuleName
        ModulePath = $ModulePath
        Path       = $filePath
        Language   = 'PowerShell'
    }))

    foreach ($case in $fileCases) {
        $caseId = '0-{0}' -f $nextId
        $nextId++
        $caseAttributes = [ordered]@{
            id           = $caseId
            name         = $case.Rule
            fullname     = '{0}.{1}' -f $className, $case.Rule
            methodname   = $case.Rule
            classname    = $className
            runstate     = if ($case.Result -eq 'Skipped') { 'Ignored' } else { 'Runnable' }
            result       = $case.Result
            'start-time' = $startText
            'end-time'   = $endText
            duration     = '0.000000'
            asserts      = $case.Asserts
        }
        if ($case.Result -eq 'Skipped') {
            $caseAttributes.label = 'Ignored'
        }

        $testCase = Add-XmlElement -Parent $fixture -Name 'test-case' -Attributes $caseAttributes
        $firstRecord = $case.Records | Select-Object -First 1
        $severity = $firstRecord | Select-Object -ExpandProperty Severity -ErrorAction Ignore
        $suppressionId = $firstRecord | Select-Object -ExpandProperty RuleSuppressionID -ErrorAction Ignore
        [void] (Add-PropertyContainer -Parent $testCase -Values ([ordered]@{
            Module            = $ModuleName
            ModulePath        = $ModulePath
            RuleName          = $case.Rule
            Severity          = $severity
            ScriptName        = $fileName
            ScriptPath        = $filePath
            DiagnosticCount   = $case.Records.Count
            RuleSuppressionID = $suppressionId
        }))

        if ($case.Result -eq 'Passed') {
            [void] (Add-CDataElement -Parent $testCase -Name 'output' -Value ('No diagnostics emitted by {0}.' -f $case.Rule))
            continue
        }

        if ($case.Result -eq 'Skipped') {
            $reason = Add-XmlElement -Parent $testCase -Name 'reason'
            [void] (Add-CDataElement -Parent $reason -Name 'message' -Value 'Diagnostic was suppressed by PSScriptAnalyzer configuration or SuppressMessageAttribute.')
            continue
        }

        $messages = @($case.Records | ForEach-Object { [string] ($_ | Select-Object -ExpandProperty Message -ErrorAction Ignore)})
        $locations = @($case.Records | ForEach-Object {
            $line = $_ | Select-Object -ExpandProperty Line -ErrorAction Ignore
            $column = $_ | Select-Object -ExpandProperty Column -ErrorAction Ignore
            '{0}: line {1}, column {2}' -f $case.Path, $(if ($null -ne $line) { $line } else { '?' }), $(if ($null -ne $column) { $column } else { '?' })
        })

        $failure = Add-XmlElement -Parent $testCase -Name 'failure'
        [void] (Add-CDataElement -Parent $failure -Name 'message' -Value ($messages -join [Environment]::NewLine))
        [void] (Add-CDataElement -Parent $failure -Name 'stack-trace' -Value ($locations -join [Environment]::NewLine))

        $assertions = Add-XmlElement -Parent $testCase -Name 'assertions'
        for ($recordIndex = 0; $recordIndex -lt $case.Records.Count; $recordIndex++) {
            $record = $case.Records[$recordIndex]
            $recordSeverity = [string] ($record | Select-Object -ExpandProperty Severity -ErrorAction Ignore)
            $assertionResult = if ($recordSeverity -in @('Error', 'ParseError')) { 'Error' } elseif ($recordSeverity -eq 'Warning') { 'Warning' } else { 'Failed' }
            $assertion = Add-XmlElement -Parent $assertions -Name 'assertion' -Attributes ([ordered]@{ result = $assertionResult })
            [void] (Add-CDataElement -Parent $assertion -Name 'message' -Value $messages[$recordIndex])
            [void] (Add-CDataElement -Parent $assertion -Name 'stack-trace' -Value $locations[$recordIndex])
        }
    }
}
$writerSettings = [System.Xml.XmlWriterSettings]::new()
$writerSettings.Encoding = [System.Text.UTF8Encoding]::new($false)
$writerSettings.Indent = $true
$writerSettings.IndentChars = '  '
$writerSettings.NewLineChars = [Environment]::NewLine
$writerSettings.NewLineHandling = [System.Xml.NewLineHandling]::Replace

$memoryStream = [System.IO.MemoryStream]::new()
try {
    $writer = [System.Xml.XmlWriter]::Create($memoryStream, $writerSettings)
    try {
        $document.Save($writer)
    }
    finally {
        $writer.Dispose()
    }
    $xmlText = [System.Text.Encoding]::UTF8.GetString($memoryStream.ToArray())
}
finally {
    $memoryStream.Dispose()
}

if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $resolvedOutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
    $outputDirectory = [System.IO.Path]::GetDirectoryName($resolvedOutputPath)
    if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
        [void] [System.IO.Directory]::CreateDirectory($outputDirectory)
    }
    [System.IO.File]::WriteAllText($resolvedOutputPath, $xmlText, [System.Text.UTF8Encoding]::new($false))
}

if ([string]::IsNullOrWhiteSpace($OutputPath) -or $PassThru) {
    return $xmlText
}