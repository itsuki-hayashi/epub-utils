param([string]$ExecutablePath)
$ErrorActionPreference = 'Stop'
$projectDirectory = Split-Path $PSScriptRoot -Parent
$executable = if ($ExecutablePath) { [IO.Path]::GetFullPath($ExecutablePath) } else { Join-Path $projectDirectory 'bin/epub-v2h.exe' }
$fixtureDirectory = [IO.Path]::GetFullPath((Join-Path $projectDirectory '../convert-vertical-to-horizontal-perl/t/fixtures/input'))
$manifestPath = Join-Path $fixtureDirectory '../manifest.json'
$runDirectory = Join-Path $projectDirectory ('test-results/cli-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $runDirectory | Out-Null
$scenarios = [Collections.Generic.List[string]]::new()

function Check([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Run-Converter([string[]]$Arguments, [switch]$CleanPath, [string]$WorkingDirectory) {
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $executable
    $startInfo.WorkingDirectory = if ($WorkingDirectory) { $WorkingDirectory } else { $projectDirectory }
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $startInfo.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    foreach ($argument in $Arguments) { $startInfo.ArgumentList.Add($argument) }
    if ($CleanPath) { $startInfo.Environment['PATH'] = (Join-Path $env:WINDIR 'System32') + ';' + $env:WINDIR }
    $process = [Diagnostics.Process]::Start($startInfo)
    try {
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        return [pscustomobject]@{
            Code = $process.ExitCode
            Output = $stdoutTask.GetAwaiter().GetResult()
            Error = $stderrTask.GetAwaiter().GetResult()
        }
    } finally {
        $process.Dispose()
    }
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$help = Run-Converter @('--help')
Check ($help.Code -eq 0 -and $help.Output -match '--analyze-only' -and $help.Output -match 'DEFLATE') 'Help output'
$scenarios.Add('Help describes supported options and compression policy')
$originalHashes = @{}
foreach ($case in $manifest) {
    $originalHashes[$case.Book] = (Get-FileHash -LiteralPath (Join-Path $fixtureDirectory $case.Book) -Algorithm SHA256).Hash
}
$books = Join-Path $runDirectory 'books'
$report = Join-Path $runDirectory 'report.json'
$converted = Run-Converter @('--input-path', $fixtureDirectory, '--output-directory', $books, '--report-path', $report, '--json')
Check ($converted.Code -eq 0) ('Fixture conversion failed: ' + $converted.Error)
$records = @($converted.Output | ConvertFrom-Json)
Check ($records.Count -eq 21) 'Expected 21 fixture records'
foreach ($case in $manifest) {
    $matches = @($records | Where-Object Book -CEQ $case.Book)
    Check ($matches.Count -eq 1) ('Missing or duplicate record: ' + $case.Book)
    $actual = $matches[0]
    Check ($actual.Reason -ceq $case.Reason) ('Classification mismatch: ' + $case.Book)
    Check ((@($actual.ChangedEntries) -join '|') -ceq (@($case.ChangedEntries) -join '|')) ('Patch list mismatch: ' + $case.Book)
    $expectedStatus = if ($case.Reason -ceq 'VerticalText') { 'Converted' } else { 'Preserved' }
    Check ($actual.Status -ceq $expectedStatus) ('Status mismatch: ' + $case.Book)
    $outputHash = (Get-FileHash -LiteralPath (Join-Path $books $case.Book) -Algorithm SHA256).Hash
    Check ($actual.InputSHA256 -ceq $originalHashes[$case.Book]) 'Input hash reporting mismatch'
    Check ($actual.OutputSHA256 -ceq $outputHash) 'Output hash reporting mismatch'
    if ($expectedStatus -ceq 'Preserved') {
        Check ($outputHash -ceq $originalHashes[$case.Book]) 'Preserved archive changed'
    }
    Check ((Get-FileHash -LiteralPath (Join-Path $fixtureDirectory $case.Book) -Algorithm SHA256).Hash -ceq $originalHashes[$case.Book]) 'Source changed'
}
$reportRecords = Get-Content -LiteralPath $report -Raw | ConvertFrom-Json
Check (($records | ConvertTo-Json -Depth 8 -Compress) -ceq ($reportRecords | ConvertTo-Json -Depth 8 -Compress)) 'JSON stdout/report disagreement'
$scenarios.Add('21 fixture classifications, patches, statuses, hashes and source preservation')

$previewDirectory = Join-Path $runDirectory 'preview'
$previewReport = Join-Path $runDirectory 'preview.json'
$preview = Run-Converter @('--input-path', $fixtureDirectory, '--output-directory', $previewDirectory, '--report-path', $previewReport, '--what-if', '--json')
Check ($preview.Code -eq 0) ('Dry run failed: ' + $preview.Error)
Check (-not (Test-Path -LiteralPath $previewDirectory)) 'Dry run created an output directory'
Check (-not (Test-Path -LiteralPath $previewReport)) 'Dry run created a report'
Check (@($preview.Output | ConvertFrom-Json | Where-Object Status -CNE 'WhatIf').Count -eq 0) 'Dry-run statuses'
$scenarios.Add('Dry run creates no books, directories or reports')

$analysisReport = Join-Path $runDirectory 'analysis.json'
$analysis = Run-Converter @('--InputPath', $fixtureDirectory, '--OutputDirectory', $books, '--AnalyzeOnly', '--ReportPath', $analysisReport, '--json')
Check ($analysis.Code -eq 0) ('Analysis/aliases failed: ' + $analysis.Error)
Check (@($analysis.Output | ConvertFrom-Json | Where-Object Status -CNE 'Analyzed').Count -eq 0) 'Analysis ignores existing book outputs'
Check (Test-Path -LiteralPath $analysisReport) 'Analysis report missing'
$collision = Run-Converter @('--input-path', $fixtureDirectory, '--analyze-only', '--report-path', $analysisReport)
Check ($collision.Code -eq 1 -and $collision.Error -match 'Refusing to overwrite report') 'Report overwrite protection'
$repeat = Run-Converter @('--input-path', $fixtureDirectory, '--output-directory', $books, '--json')
Check ($repeat.Code -eq 1) 'Existing output books must be rejected'
Check (@($repeat.Output | ConvertFrom-Json | Where-Object Status -CNE 'Error').Count -eq 0) 'Every existing book rejected'
$scenarios.Add('Aliases, analysis and book/report overwrite protection')

$defaults = Join-Path $runDirectory 'defaults'
New-Item -ItemType Directory -Path $defaults | Out-Null
Copy-Item -LiteralPath (Join-Path $fixtureDirectory 'horizontal English [literal].epub') -Destination (Join-Path $defaults 'default.epub')
$defaultResult = Run-Converter @('--json', '--Verbose') -WorkingDirectory $defaults
Check ($defaultResult.Code -eq 0) ('Default paths failed: ' + $defaultResult.Error)
$defaultRecords = @($defaultResult.Output | ConvertFrom-Json)
Check ($defaultRecords.Count -eq 1 -and $defaultRecords[0].Status -ceq 'Preserved') 'Default working-directory input'
Check (Test-Path -LiteralPath (Join-Path $defaults 'horizontal/default.epub')) 'Default output directory'
Check ($defaultResult.Error -match 'Inspecting') 'Verbose diagnostics belong on stderr'
$inlineResult = Run-Converter @(('--input-path=' + (Join-Path $defaults 'default.epub')), '--analyze-only', '--json')
Check ($inlineResult.Code -eq 0) 'Inline option values'
$missingParent = Run-Converter @('--input-path', $fixtureDirectory, '--analyze-only', '--report-path', (Join-Path $runDirectory 'missing-parent/report.json'))
Check ($missingParent.Code -eq 1 -and $missingParent.Error -match 'directory must already exist') 'Report requires an existing parent'
$scenarios.Add('Default paths, verbose stderr, inline values and invalid report parent')

$mixed = Join-Path $runDirectory 'mixed'
New-Item -ItemType Directory -Path $mixed | Out-Null
[IO.File]::WriteAllText((Join-Path $mixed 'a-invalid.epub'), 'not a ZIP')
Copy-Item -LiteralPath (Join-Path $fixtureDirectory 'horizontal English [literal].epub') -Destination (Join-Path $mixed 'z-valid.epub')
$mixedResult = Run-Converter @('--input-path', $mixed, '--output-directory', (Join-Path $runDirectory 'mixed-output'), '--json')
$mixedRecords = @($mixedResult.Output | ConvertFrom-Json)
Check ($mixedResult.Code -eq 1) 'Mixed batch must return failure'
Check (($mixedRecords.Status -join '|') -ceq 'Error|Preserved') 'Per-book failure isolation'
Check (-not [string]::IsNullOrWhiteSpace($mixedRecords[0].Error)) 'Malformed ZIP error must be explicit'
$scenarios.Add('Malformed archive isolation and continued batch processing')

$tree = Join-Path $runDirectory 'tree'
$child = Join-Path $tree 'author/日本語 [literal]'
$deep = Join-Path $child 'series'
$ignored = Join-Path $tree 'HoRiZoNtAl'
New-Item -ItemType Directory -Path $deep, $ignored | Out-Null
$reference = Join-Path $fixtureDirectory 'vertical CSS variants.epub'
Copy-Item -LiteralPath $reference -Destination (Join-Path $tree 'root.epub')
Copy-Item -LiteralPath $reference -Destination (Join-Path $child 'same.epub')
Copy-Item -LiteralPath $reference -Destination (Join-Path $deep 'same.EPUB')
Copy-Item -LiteralPath $reference -Destination (Join-Path $ignored 'existing.epub')
$junction = Join-Path $tree 'directory-link'
New-Item -ItemType Junction -Path $junction -Value $child | Out-Null
$ignoredOutput = Join-Path $runDirectory 'ignored-output'
$treePreview = Run-Converter @('--input-path', $tree, '--recursive', '--output-directory', $ignoredOutput, '--what-if', '--json')
Check ($treePreview.Code -eq 0) ('Recursive preview failed: ' + $treePreview.Error)
Check (@($treePreview.Output | ConvertFrom-Json).Count -eq 3) 'Recursive scan must skip junctions and generated directories'
Check (-not (Test-Path -LiteralPath $ignoredOutput)) 'Recursive mode created ignored output directory'
$treeResult = Run-Converter @('--InputPath', $tree, '-r', '--OutputDirectory', $ignoredOutput, '--json')
$treeRecords = @($treeResult.Output | ConvertFrom-Json)
Check ($treeResult.Code -eq 0 -and $treeRecords.Count -eq 3) ('Recursive conversion failed: ' + $treeResult.Error)
foreach ($record in $treeRecords) { Check (Test-Path -LiteralPath $record.Output) 'Missing per-source recursive output' }
Check (-not (Test-Path -LiteralPath $ignoredOutput)) 'Recursive mode used ignored output directory'
$scenarios.Add('Recursive Unicode paths, duplicate basenames, output exclusion and junction skipping')

$clean = Run-Converter @('--input-path', (Join-Path $fixtureDirectory 'vertical CSS variants.epub'), '--analyze-only', '--json') -CleanPath
Check ($clean.Code -eq 0) ('Sanitized-PATH execution failed: ' + $clean.Error)
$scenarios.Add('Execution with only Windows system directories on PATH')
foreach ($arguments in @(@('--unknown'), @('--input-path'), @('unexpected-positional'))) {
    $bad = Run-Converter $arguments
    Check ($bad.Code -eq 1) 'Invalid arguments must fail'
}
$scenarios.Add('Unknown options, missing values and positional arguments rejected')

& perl (Join-Path $PSScriptRoot 'verify-archive-roundtrip.pl') conversion $books
if ($LASTEXITCODE -ne 0) { throw 'Independent Perl payload/metadata verification failed' }
$scenarios.Add('Independent Perl verification of 159 output entries')
$summary = [ordered]@{
    FixtureBooks = $records.Count
    Converted = @($records | Where-Object Status -CEQ 'Converted').Count
    Preserved = @($records | Where-Object Status -CEQ 'Preserved').Count
    Scenarios = $scenarios.ToArray()
}
$summary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $projectDirectory 'verification/cli-latest.json') -Encoding utf8
$summary | ConvertTo-Json -Depth 5
