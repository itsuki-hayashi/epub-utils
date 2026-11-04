param(
    [ValidateSet('development', 'release', 'profile')][string]$BuildKind = 'development',
    [ValidateSet('portable', 'native')][string]$CpuTuning = 'portable',
    [switch]$LinkTimeOptimization,
    [switch]$Gprof,
    [Parameter(ValueFromRemainingArguments)][string[]]$BuildArguments
)
$ErrorActionPreference = 'Stop'
if ($Gprof -and $BuildKind -ne 'profile') { throw 'Use -BuildKind profile with -Gprof.' }
$projectDirectory = Split-Path $PSScriptRoot -Parent
Push-Location -LiteralPath $projectDirectory
try {
    $switches = @('-p', '-P', 'epub_v2h_ada.gpr', "-XEPUB_BUILD=$BuildKind", "-XEPUB_TUNING=$CpuTuning")
    if ($BuildKind -eq 'release') { $switches += '-XEPUB_LINKED_OUTPUT=true' }
    $suffix = "$BuildKind-$CpuTuning" + $(if ($LinkTimeOptimization) { '-lto' }) + $(if ($Gprof) { '-gprof' })
    if ($BuildKind -ne 'development' -or $CpuTuning -ne 'portable' -or $LinkTimeOptimization -or $Gprof) { $switches += "--subdirs=$suffix" }
    $compiler = @()
    if ($BuildKind -ne 'development') { $compiler += @('-O3', '-gnatn') }
    if ($CpuTuning -eq 'native') { $compiler += @('-march=native', '-mtune=native') }
    if ($LinkTimeOptimization) { $compiler += '-flto=auto' }
    if ($Gprof) { $switches += '-XEPUB_GPROF=true'; $compiler += '-pg' }
    $switches += $BuildArguments
    if ($compiler.Count) { $switches += @('-cargs:Ada') + $compiler }
    if ($LinkTimeOptimization) { $switches += @('-largs', '-flto=auto') }
    & alr -n exec -- gprbuild @switches
    if ($LASTEXITCODE -ne 0) { throw 'Ada build failed.' }
    if ($BuildKind -eq 'release') {
        $binary = Join-Path $projectDirectory "bin/$suffix/epub-v2h.exe"
        $linked = Join-Path $projectDirectory "obj/linked/$suffix/epub-v2h.exe"
        New-Item -ItemType Directory -Path (Split-Path $binary -Parent) -Force | Out-Null
        & alr -n exec -- objcopy --preserve-dates --only-keep-debug $linked ($binary + '.debug')
        if ($LASTEXITCODE -ne 0) { throw 'Saving debug symbols failed.' }
        Copy-Item -LiteralPath $linked -Destination $binary -Force
        Copy-Item -LiteralPath (Join-Path (Split-Path $linked -Parent) 'epub-v2h.map') -Destination (Split-Path $binary -Parent) -Force
        & alr -n exec -- strip --preserve-dates --strip-debug --strip-unneeded $binary
        if ($LASTEXITCODE -ne 0) { throw 'Stripping release binary failed.' }
    }
} finally {
    Pop-Location
}
