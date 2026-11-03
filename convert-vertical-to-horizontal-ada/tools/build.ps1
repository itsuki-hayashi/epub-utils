$ErrorActionPreference = 'Stop'
$projectDirectory = Split-Path $PSScriptRoot -Parent
Push-Location -LiteralPath $projectDirectory
try {
    & alr -n exec -- gprbuild -p -P epub_v2h_ada.gpr @args
    if ($LASTEXITCODE -ne 0) { throw 'Ada build failed.' }
} finally {
    Pop-Location
}
