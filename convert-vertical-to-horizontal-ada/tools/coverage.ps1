param([switch]$MeasureOnly)
$ErrorActionPreference = 'Stop'
$projectDirectory = Split-Path $PSScriptRoot -Parent
$runDirectory = Join-Path $projectDirectory ('test-results/coverage-' + [guid]::NewGuid().ToString('N'))
$traceDirectory = Join-Path $runDirectory 'traces'
$reportDirectory = Join-Path $runDirectory 'report'
$runtimeProject = Join-Path $projectDirectory 'obj/gnatcov-runtime/share/gpr/gnatcov_rts.gpr'
New-Item -ItemType Directory -Path $traceDirectory, $reportDirectory | Out-Null

function Run-Alire([string[]]$Arguments, [string]$LogName) {
    if ($Arguments[1] -ne 'setup') { $Arguments += '-XEPUB_XML_ROLE=coverage' }
    & alr -n exec -- @Arguments *> (Join-Path $runDirectory $LogName)
    if ($LASTEXITCODE -ne 0) { throw ('Coverage command failed; see ' + (Join-Path $runDirectory $LogName)) }
}

Push-Location -LiteralPath (Join-Path $projectDirectory 'coverage')
try {
    if (-not (Test-Path -LiteralPath $runtimeProject)) {
        Run-Alire @('gnatcov', 'setup', '--prefix=../obj/gnatcov-runtime', '--warnings-as-errors') 'setup.log'
    }
    $prefix = (Join-Path $traceDirectory 'epub').Replace('\', '/')
    Run-Alire @('gnatcov', 'instrument', '-P', 'coverage.gpr', '--subdirs=standalone', '--units=epub.*',
        '--units=unzip.epub_decompression',
        '--units=epub_v2h_main',
        '--projects=Coverage', '--projects=Core_Containers', '--no-subprojects', '--level=stmt+mcdc', '--ada=2022', '--dump-trigger=atexit',
        ('--dump-filename-prefix=' + $prefix), ('--runtime-project=' + $runtimeProject), '--warnings-as-errors') 'instrument.log'
    Run-Alire @('gprbuild', '-p', '-P', 'coverage.gpr', '--subdirs=standalone', '--src-subdirs=gnatcov-instr',
        ('--implicit-with=' + $runtimeProject)) 'build.log'
    Push-Location -LiteralPath (Join-Path $projectDirectory 'tests')
    try {
        & (Join-Path $projectDirectory 'bin/coverage/standalone/test-runner.exe') *> (Join-Path $runDirectory 'unit-tests.log')
        if ($LASTEXITCODE -ne 0) { throw 'Instrumented AUnit tests failed' }
    } finally { Pop-Location }
    & (Join-Path $PSScriptRoot 'test-cli.ps1') -ExecutablePath (Join-Path $projectDirectory 'bin/coverage/standalone/epub-v2h.exe') *> (Join-Path $runDirectory 'cli-tests.log')
    $traces = @(Get-ChildItem -LiteralPath $traceDirectory -Filter '*.srctrace' | Select-Object -ExpandProperty FullName)
    if ($traces.Count -lt 2) { throw 'Coverage traces are missing' }
    $traceList = Join-Path $runDirectory 'traces.list'
    [IO.File]::WriteAllLines($traceList, $traces)
    Run-Alire @('gnatcov', 'coverage', '-P', 'coverage.gpr', '--subdirs=standalone', '--units=epub.*',
        '--units=unzip.epub_decompression',
        '--units=epub_v2h_main',
        '--projects=Coverage', '--projects=Core_Containers', '--no-subprojects', '--level=stmt+mcdc', '--annotate=xcov', ('--output-dir=' + $reportDirectory),
        ('@' + $traceList)) 'analysis.log'
    Run-Alire @('gnatcov', 'coverage', '-P', 'coverage.gpr', '--subdirs=standalone', '--units=epub.*',
        '--units=unzip.epub_decompression',
        '--units=epub_v2h_main',
        '--projects=Coverage', '--projects=Core_Containers', '--no-subprojects', '--level=stmt+mcdc', '--annotate=report', '-o',
        (Join-Path $projectDirectory 'verification/coverage-latest.txt'), ('@' + $traceList)) 'report.log'
    & (Join-Path $PSScriptRoot 'summarize-coverage.ps1') -CoverageDirectory $reportDirectory -MeasureOnly:$MeasureOnly
} finally { Pop-Location }
