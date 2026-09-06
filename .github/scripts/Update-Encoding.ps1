<#
.SYNOPSIS
Update encoding for files UTF8 with BOM or without BOM.

.DESCRIPTION
Supports UTF-8 BOM encoding and UTF-8 encoding without BOM.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = 'Path')]
    [System.String]$RootPath,

    [Parameter(Mandatory = $true, HelpMessage = 'Extensions to cover')]
    [System.String[]]$Extensions,

    [Parameter(Mandatory = $false, HelpMessage = 'Recurse')]
    [switch]$Recurse,

    [Parameter(Mandatory = $false, HelpMessage = 'Use Utf8 with BOM')]
    [Switch]$BOM,

    [Parameter(Mandatory = $false, HelpMessage = 'Check only')]
    [Switch]$Check
)
Begin{
    Function Set-NormalizedContent {
        param(
            [Parameter(Mandatory = $true, ValueFromPipeline = $True, HelpMessage = 'Literal Path')]
            [System.String]$LiteralPath,

            [Parameter(Mandatory = $true, HelpMessage = 'Encoding')]
            [System.Text.Encoding]$Encoding
        )
        Process{
            Try{
                #Read file
                $Content = [System.IO.File]::ReadAllText($LiteralPath)
                $expectedPreamble = $Encoding.GetPreamble()
                $contentBytes = $Encoding.GetBytes($Content)
                $expectedBytes = [byte[]]::new($expectedPreamble.Length + $contentBytes.Length)
                [System.Buffer]::BlockCopy($expectedPreamble, 0, $expectedBytes, 0, $expectedPreamble.Length)
                [System.Buffer]::BlockCopy($contentBytes, 0, $expectedBytes, $expectedPreamble.Length, $contentBytes.Length)
                $actualBytes = [System.IO.File]::ReadAllBytes($LiteralPath)

                If ([System.Linq.Enumerable]::SequenceEqual($actualBytes, $expectedBytes)) {
                    Write-Verbose ("The file {0} already has the right encoding" -f $LiteralPath)
                    return
                }
                Write-Verbose ("Changing encoding for {0}" -f $LiteralPath)
                $relativePath = Resolve-Path -Path $LiteralPath -Relative
                [void]$changedFiles.Add($relativePath)
                If (-not $Check) {
                    [System.IO.File]::WriteAllBytes($LiteralPath, $expectedBytes)
                }
            }
            Catch{
                Write-Error $_.Exception.Message
            }
        }
    }
    $repoRoot = $null;
    $utf8WithoutBom = [System.Text.UTF8Encoding]::new($false, $true)
    $utf8WithBom    = [System.Text.UTF8Encoding]::new($true,  $true)
    $changedFiles = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    If($null -ne (Get-Command -Name git -ErrorAction Ignore)){
        $repoRoot = git rev-parse --show-toplevel 2>$null
    }
    IF($null -eq $repoRoot){
        $repoRoot = Split-Path $PSScriptRoot -Parent
    }
    If (-NOT [System.IO.Path]::IsPathRooted($PSBoundParameters['RootPath'])) {
        $_rootPath = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $PSBoundParameters['RootPath']));
    }
    Else{
        $_rootPath = $PSBoundParameters['RootPath']
    }
}
Process{
    Try{
        $options = @{
            LiteralPath = $_rootPath;
            File = $true;
            Recurse = $Recurse.IsPresent;
        }
        $_allFiles = Get-ChildItem @options | Where-Object { $_.Extension -in $Extensions -and $_.FullName -notmatch '[\\/]\.git[\\/]'} | Select-Object -ExpandProperty FullName
        Write-Host "Processing PowerShell files: $($_allFiles.Count)"
        If($_allFiles){
            If($BOM.IsPresent){
                $encoding = $utf8WithBom
            }
            Else{
                $encoding = $utf8WithoutBom
            }
            $options = @{
                Encoding = $encoding                            
            }
            $_allFiles | Set-NormalizedContent @options
        }
    }
    Catch{
        Write-Error $_.Exception.Message
    }
}
