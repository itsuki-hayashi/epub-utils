$ErrorActionPreference = 'Stop'
Push-Location -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'proof')
try {
    & alr -n exec -- gnatprove -P core.gpr '--level=4' '--report=all' `
        '--checks-as-errors=on' '--timeout=15'
    if ($LASTEXITCODE -ne 0) { throw 'Required core proofs failed.' }
} finally {
    Pop-Location
}
