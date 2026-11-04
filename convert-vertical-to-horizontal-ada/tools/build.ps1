param(
    [ValidateSet('development', 'release', 'profile')][string]$BuildKind = 'development',
    [ValidateSet('portable', 'native')][string]$CpuTuning = 'portable',
    [switch]$LinkTimeOptimization,
    [switch]$Gprof,
    [switch]$SectionGC,
    [Parameter(ValueFromRemainingArguments)][string[]]$BuildArguments
)
$ErrorActionPreference = 'Stop'
if ($Gprof -and $BuildKind -ne 'profile') { throw 'Use -BuildKind profile with -Gprof.' }
$projectDirectory = Split-Path $PSScriptRoot -Parent
Push-Location -LiteralPath $projectDirectory
try {
    $switches = @('-p', '-P', 'epub_v2h_ada.gpr', "-XEPUB_BUILD=$BuildKind", "-XEPUB_TUNING=$CpuTuning")
    $sectionValue = if ($SectionGC) { 'true' } else { 'false' }
    $switches += "-XEPUB_SECTIONS=$sectionValue"
    $isolated = $BuildKind -ne 'development' -or $CpuTuning -ne 'portable' -or $LinkTimeOptimization -or $Gprof -or $SectionGC
    $linkedValue = if ($isolated) { 'true' } else { 'false' }
    $switches += "-XEPUB_LINKED_OUTPUT=$linkedValue"
    $gprofValue = if ($Gprof) { 'true' } else { 'false' }
    $switches += "-XEPUB_GPROF=$gprofValue"
    $suffix = "$BuildKind-$CpuTuning" + $(if ($LinkTimeOptimization) { '-lto' }) + $(if ($Gprof) { '-gprof' })
    if ($SectionGC) { $suffix += '-sections' }
    $buildSubdirectory = $suffix
    if ($isolated) {
        # MinGW's archive tools reject long expanded relative paths even when
        # their normalized absolute paths fit. Keep dependency paths short.
        $buildSubdirectory = $BuildKind.Substring(0,1) + $CpuTuning.Substring(0,1) +
            $(if ($LinkTimeOptimization) { 'l' }) + $(if ($Gprof) { 'g' }) + $(if ($SectionGC) { 's' })
    }
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
    } elseif ($isolated) {
        $destination = Join-Path $projectDirectory "bin/$suffix"
        $linkedDirectory = Join-Path $projectDirectory "obj/linked/$buildSubdirectory"
        New-Item -ItemType Directory -Path $destination -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $linkedDirectory 'epub-v2h.exe'),(Join-Path $linkedDirectory 'epub-v2h.map') -Destination $destination -Force
    }
} finally {
    Pop-Location
}
