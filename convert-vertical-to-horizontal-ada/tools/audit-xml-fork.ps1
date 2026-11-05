param([string]$LinkMap)
$ErrorActionPreference = 'Stop'
$project = Split-Path $PSScriptRoot -Parent
$fork = Join-Path $project 'vendor/xmlada_epub'
$identity = Get-Content -LiteralPath (Join-Path $fork 'fork-identity.json') -Raw | ConvertFrom-Json
$files = @(Get-ChildItem -LiteralPath $fork -Recurse -File | Where-Object {
    $relative = $_.FullName.Substring($fork.Length + 1).Replace('\','/')
    $relative -ne 'fork-identity.json' -and $relative -notmatch '(^|/)(obj|lib|alire|config|\.git)/'
})
if ($files.Count -ne @($identity.Files.PSObject.Properties).Count) { throw 'XML fork source inventory changed.' }
foreach ($file in $files) {
    $relative = $file.FullName.Substring($fork.Length + 1).Replace('\','/')
    $expected = $identity.Files.PSObject.Properties[$relative]
    if (-not $expected -or $expected.Value -cne (Get-FileHash -LiteralPath $file.FullName).Hash.ToLowerInvariant()) {
        throw "XML fork source identity changed: $relative"
    }
}
$projects = @('epub_v2h_ada.gpr','coverage/coverage.gpr','vendor/xmlada_epub/xmlada_epub_shared.gpr',
    'vendor/xmlada_epub/sax/xmlada_epub_sax.gpr','vendor/xmlada_epub/input_sources/xmlada_epub_input.gpr',
    'vendor/xmlada_epub/unicode/xmlada_epub_unicode.gpr')
foreach ($path in $projects) {
    if ([IO.File]::ReadAllText((Join-Path $project $path)) -match 'with\s+"(?:[^"\r\n]*/)?xmlada_(?!epub_)') {
        throw "Original XML/Ada import: $path"
    }
}
if ($LinkMap -and [IO.File]::ReadAllText($LinkMap) -match 'xmlada_26\.0\.0|sax__pointers__|epub__xml__(node_lists|attribute_lists)') {
    throw 'Original XML ownership entered the linked production closure.'
}
Write-Output ("XML fork identity and closure: {0} ({1} files)" -f $identity.SourceSHA256, $files.Count)
