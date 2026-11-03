$ErrorActionPreference = 'Stop'
$projectDirectory = Split-Path $PSScriptRoot -Parent
Push-Location -LiteralPath (Join-Path $projectDirectory 'tests')
try {
    & alr -n exec -- gprbuild -p -P tests.gpr
    if ($LASTEXITCODE -ne 0) { throw 'Unit-test build failed.' }
    & (Join-Path $projectDirectory 'bin/tests/test-runner.exe')
    if ($LASTEXITCODE -ne 0) { throw 'Unit tests failed.' }
} finally {
    Pop-Location
}
