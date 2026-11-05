param(
    [ValidateSet('development', 'release', 'profile')][string]$BuildKind = 'development',
    [ValidateSet('portable', 'native')][string]$CpuTuning = 'portable',
    [switch]$LinkTimeOptimization,
    [switch]$Gprof,
    [switch]$SectionGC,
    [ValidateSet('off','generate','use')][string]$PgoMode = 'off',
    [string]$ProfileDirectory,
    [Parameter(ValueFromRemainingArguments)][string[]]$BuildArguments
)
$ErrorActionPreference = 'Stop'
if ($Gprof -and $BuildKind -ne 'profile') { throw 'Use -BuildKind profile with -Gprof.' }
$projectDirectory = Split-Path $PSScriptRoot -Parent
& (Join-Path $PSScriptRoot 'audit-xml-fork.ps1')
if ($PgoMode -ne 'off' -and ($BuildKind -ne 'release' -or $Gprof -or $LinkTimeOptimization -or -not $ProfileDirectory)) {
    throw 'PGO requires a release build, an external ProfileDirectory, and no gprof/LTO.'
}
if ($PgoMode -eq 'off' -and $ProfileDirectory) { throw 'ProfileDirectory requires PgoMode generate or use.' }
if ($PgoMode -ne 'off') {
    $ProfileDirectory = [IO.Path]::GetFullPath($ProfileDirectory)
    $repository = [IO.Path]::GetFullPath((Join-Path $projectDirectory '..'))
    if ($ProfileDirectory -eq $repository -or $ProfileDirectory.StartsWith($repository+'\',[StringComparison]::OrdinalIgnoreCase)) {
        throw 'PGO data must remain outside the repository.'
    }
    $sources = @(Get-ChildItem -LiteralPath (Join-Path $projectDirectory 'src') -Recurse -File |
        Where-Object Extension -in '.adb','.ads','.c') + @(Get-ChildItem -LiteralPath $projectDirectory -Filter '*.gpr') +
        @(Get-Item -LiteralPath (Join-Path $projectDirectory 'alire/alire.lock'), (Join-Path $projectDirectory 'alire.toml')) +
        @(Get-ChildItem -LiteralPath (Join-Path $projectDirectory 'vendor/xmlada_epub') -Recurse -File |
          Where-Object { $_.Extension -in '.adb','.ads','.gpr','.toml','.json' -and
            $_.FullName.Substring((Join-Path $projectDirectory 'vendor/xmlada_epub').Length) -notmatch '[\\/](obj|lib|alire|config)[\\/]' })
    $sourceIdentity = (@($sources | Sort-Object FullName | ForEach-Object {
        $_.FullName.Substring($projectDirectory.Length) + ':' + (Get-FileHash -LiteralPath $_.FullName).Hash
    }) -join "`n")
    $sourceSHA256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($sourceIdentity)))
    $profileManifest = Join-Path $ProfileDirectory 'build-identity.json'
    if ($PgoMode -eq 'use') {
        $trained = Get-Content -LiteralPath $profileManifest -Raw | ConvertFrom-Json
        if ($trained.SourceSHA256 -cne $sourceSHA256 -or $trained.CpuTuning -ne $CpuTuning -or
            $trained.SectionGC -ne [bool]$SectionGC -or -not @(Get-ChildItem -LiteralPath $ProfileDirectory -Filter '*.gcda' -Recurse).Count) {
            throw 'PGO data is missing or belongs to a different source/configuration.'
        }
    } else {
        if (Test-Path -LiteralPath $profileManifest) { throw 'Use a fresh profile directory for each training build.' }
        New-Item -ItemType Directory -Path $ProfileDirectory -Force | Out-Null
    }
}
Push-Location -LiteralPath $projectDirectory
try {
    $switches = @('-p', '-P', 'epub_v2h_ada.gpr', "-XEPUB_BUILD=$BuildKind", "-XEPUB_TUNING=$CpuTuning")
    $sectionValue = if ($SectionGC) { 'true' } else { 'false' }
    $switches += "-XEPUB_SECTIONS=$sectionValue"
    $switches += @("-XEPUB_PGO=$PgoMode", "-XEPUB_PGO_DIRECTORY=$ProfileDirectory")
    if ($PgoMode -ne 'off') { $switches += '-f' }
    $isolated = $BuildKind -ne 'development' -or $CpuTuning -ne 'portable' -or $LinkTimeOptimization -or $Gprof -or $SectionGC
    $linkedValue = if ($isolated) { 'true' } else { 'false' }
    $switches += "-XEPUB_LINKED_OUTPUT=$linkedValue"
    $gprofValue = if ($Gprof) { 'true' } else { 'false' }
    $switches += "-XEPUB_GPROF=$gprofValue"
    $suffix = "$BuildKind-$CpuTuning" + $(if ($LinkTimeOptimization) { '-lto' }) + $(if ($Gprof) { '-gprof' })
    if ($SectionGC) { $suffix += '-sections' }
    if ($PgoMode -ne 'off') { $suffix += "-pgo-$PgoMode" }
    $buildSubdirectory = $suffix
    if ($isolated) {
        # MinGW's archive tools reject long expanded relative paths even when
        # their normalized absolute paths fit. Keep dependency paths short.
        $buildSubdirectory = $BuildKind.Substring(0,1) + $CpuTuning.Substring(0,1) +
            $(if ($LinkTimeOptimization) { 'l' }) + $(if ($Gprof) { 'g' }) + $(if ($SectionGC) { 's' })
    }
    # Generation and use share object paths so GCC locates matching .gcda files.
    # The q configuration stays isolated from all non-PGO objects and artifacts.
    if ($PgoMode -ne 'off') { $buildSubdirectory += 'q' }
    if ($isolated) { $switches += "--subdirs=$buildSubdirectory" }
    $mapDirectory = if ($isolated) { "obj/linked/$buildSubdirectory" } else { 'bin' }
    $switches += '-XEPUB_LINK_MAP=' + (Join-Path $projectDirectory "$mapDirectory/epub-v2h.map")
    $compiler = @()
    if ($BuildKind -ne 'development') { $compiler += @('-O3', '-gnatn') }
    if ($CpuTuning -eq 'native') { $compiler += @('-march=native', '-mtune=native') }
    if ($LinkTimeOptimization) { $compiler += '-flto=auto' }
    if ($Gprof) { $compiler += '-pg' }
    if ($SectionGC) { $compiler += @('-ffunction-sections', '-fdata-sections') }
    $switches += $BuildArguments
    if ($compiler.Count) { $switches += @('-cargs:Ada') + $compiler }
    if ($LinkTimeOptimization) { $switches += @('-largs', '-flto=auto') }
    & alr -n exec -- gprbuild @switches
    if ($LASTEXITCODE -ne 0) { throw 'Ada build failed.' }
    & (Join-Path $PSScriptRoot 'audit-xml-fork.ps1') -LinkMap (Join-Path $projectDirectory "$mapDirectory/epub-v2h.map")
    if ($PgoMode -eq 'generate') {
        [pscustomobject]@{SourceSHA256=$sourceSHA256;CpuTuning=$CpuTuning;SectionGC=[bool]$SectionGC;
            Platform='windows';ObjectConfiguration=$buildSubdirectory} | ConvertTo-Json |
            Set-Content -LiteralPath $profileManifest
    }
    if ($BuildKind -eq 'release') {
        $binary = Join-Path $projectDirectory "bin/$suffix/epub-v2h.exe"
        $linked = Join-Path $projectDirectory "obj/linked/$buildSubdirectory/epub-v2h.exe"
        New-Item -ItemType Directory -Path (Split-Path $binary -Parent) -Force | Out-Null
        & alr -n exec -- objcopy --preserve-dates --only-keep-debug $linked ($binary + '.debug')
        if ($LASTEXITCODE -ne 0) { throw 'Saving debug symbols failed.' }
        Copy-Item -LiteralPath $linked -Destination $binary -Force
        Copy-Item -LiteralPath (Join-Path (Split-Path $linked -Parent) 'epub-v2h.map') -Destination (Split-Path $binary -Parent) -Force
        & alr -n exec -- strip --preserve-dates --strip-debug --strip-unneeded $binary
        if ($LASTEXITCODE -ne 0) { throw 'Stripping release binary failed.' }
        Copy-Item -LiteralPath (Join-Path $projectDirectory 'CODEC_ORIGINS.md') -Destination (Split-Path $binary -Parent) -Force
    } elseif ($isolated) {
        $destination = Join-Path $projectDirectory "bin/$suffix"
        $linkedDirectory = Join-Path $projectDirectory "obj/linked/$buildSubdirectory"
        New-Item -ItemType Directory -Path $destination -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $linkedDirectory 'epub-v2h.exe'),(Join-Path $linkedDirectory 'epub-v2h.map') -Destination $destination -Force
    }
} finally {
    Pop-Location
}
