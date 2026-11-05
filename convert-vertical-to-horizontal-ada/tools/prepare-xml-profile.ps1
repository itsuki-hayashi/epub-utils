param([Parameter(Mandatory)][string]$OutputRoot)
$ErrorActionPreference = 'Stop'
$project = Split-Path $PSScriptRoot -Parent
$repository = [IO.Path]::GetFullPath((Join-Path $project '..'))
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
if ($OutputRoot -eq $repository -or $OutputRoot.StartsWith($repository+'\',[StringComparison]::OrdinalIgnoreCase)) {
    throw 'Keep diagnostic builds and profiles outside the repository.'
}
& (Join-Path $PSScriptRoot 'audit-xml-fork.ps1') | Out-Null
# MinGW archive tools still expand relative object paths before normalization.
$directory = Join-Path $OutputRoot ('xp-' + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $directory | Out-Null
$source = Join-Path $directory 'source'
New-Item -ItemType Directory -Path $source -Force | Out-Null
$inventory = [Collections.Generic.List[object]]::new()
function Copy-Source([string]$Relative) {
    $from = Join-Path $project $Relative
    $to = Join-Path $source $Relative
    New-Item -ItemType Directory -Path (Split-Path $to -Parent) -Force | Out-Null
    Copy-Item -LiteralPath $from -Destination $to
    $inventory.Add([pscustomobject]@{Path=$Relative.Replace('\','/');SHA256=(Get-FileHash -LiteralPath $from).Hash})
}
foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $project 'src') -File -Recurse) +
    @(Get-ChildItem -LiteralPath $project -Filter '*.gpr' -File)) {
    Copy-Source ($file.FullName.Substring($project.Length+1))
}
foreach ($relative in @('alire.toml','alire/alire.lock','coverage/coverage.gpr','coverage/alire.toml',
    'tests/alire.toml','tools/build.ps1','tools/audit-xml-fork.ps1','tools/diagnostics/allocations.c',
    'tools/diagnostics/xml_collections.c')) { Copy-Source $relative }
$fork = Get-Content -LiteralPath (Join-Path $project 'vendor/xmlada_epub/fork-identity.json') -Raw | ConvertFrom-Json
foreach ($file in $fork.Files.PSObject.Properties) { Copy-Source ('vendor/xmlada_epub/'+$file.Name) }
Copy-Source 'vendor/xmlada_epub/fork-identity.json'
$inventory | Sort-Object Path | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $directory 'original-sources.json')
Copy-Item -LiteralPath (Join-Path $source 'tools/diagnostics/allocations.c') -Destination (Join-Path $source 'src/heap_probe.c')
Copy-Item -LiteralPath (Join-Path $source 'tools/diagnostics/xml_collections.c') -Destination (Join-Path $source 'src/collection_probe.c')
function Change([string]$Relative, [string]$Before, [string]$After) {
    $path = Join-Path $source $Relative
    $text = [IO.File]::ReadAllText($path)
    if (-not $text.Contains($Before)) { throw "Diagnostic insertion point changed: $Relative" }
    [IO.File]::WriteAllText($path,$text.Replace($Before,$After))
}
Change 'epub_v2h_ada.gpr' 'when others => for Languages use ("Ada");' 'when others => for Languages use ("Ada", "C");'
Change 'src/profiling/on/epub-performance.adb' '   use type Ada.Real_Time.Time;' @'
   procedure Dump_Heap with Import, Convention => C, External_Name => "epub_heap_profile_dump";
   procedure Dump_Collections with Import, Convention => C, External_Name => "epub_collection_profile_dump";
   use type Ada.Real_Time.Time;
'@
Change 'src/profiling/on/epub-performance.adb' '      End_Task;' "      End_Task;`n      Dump_Heap; Dump_Collections;"
# Additional observations live only in this diagnostic copy. The release worker
# path, timing binary and report schema remain unchanged.
Change 'src/epub-workers.ads' '      Busy_Seconds : Duration := 0.0;' @'
      Busy_Seconds : Duration := 0.0;
      Last_Started, Last_Finished : Duration := 0.0;
'@
Change 'src/epub-workers.adb' '         Beginning := Ada.Real_Time.Clock;' @'
         Beginning := Ada.Real_Time.Clock;
         Shared.all.Measurements.all (Number).Last_Started := Ada.Real_Time.To_Duration (Beginning - Shared.all.Beginning);
'@
Change 'src/epub-workers.adb' '         Shared.all.Jobs.Complete;' @'
         Shared.all.Measurements.all (Number).Last_Finished := Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Shared.all.Beginning);
         Shared.all.Jobs.Complete;
'@
Change 'src/epub-workers.adb' '            Metric (Prefix & "_jobs", Item.Shared.all.Measurements.all (Index).Jobs);' @'
            Metric (Prefix & "_jobs", Item.Shared.all.Measurements.all (Index).Jobs);
            Ada.Text_IO.Put_Line (File, Prefix & "_last_started_seconds," & Item.Shared.all.Measurements.all (Index).Last_Started'Image);
            Ada.Text_IO.Put_Line (File, Prefix & "_last_finished_seconds," & Item.Shared.all.Measurements.all (Index).Last_Finished'Image);
'@
Push-Location -LiteralPath $source
try {
    & ./tools/build.ps1 -BuildKind profile -CpuTuning native -SectionGC -BuildArguments '-largs',
        '-Wl,--wrap=malloc','-Wl,--wrap=calloc','-Wl,--wrap=realloc','-Wl,--wrap=free',
        '-Wl,--wrap=system__finalization_primitives__attach_object_to_collection',
        '-Wl,--wrap=system__task_lock__lock' *> (Join-Path $directory 'build.log')
    & alr -n exec -- nm obj/linked/pns/epub-v2h.exe *> (Join-Path $directory 'symbols.txt')
    if ($LASTEXITCODE -ne 0) { throw 'Diagnostic symbol inventory failed.' }
} finally { Pop-Location }
$executable = Join-Path $source 'bin/profile-native-sections/epub-v2h.exe'
$identity = [pscustomobject]@{Directory=$directory;Executable=$executable;BinarySHA256=(Get-FileHash -LiteralPath $executable).Hash;
    XMLForkSHA256=$fork.SourceSHA256;InstrumentedOnly=$true;
    Units='Summed task wall durations; cumulative allocation bytes; collection attachment counts; per-worker final job timestamps'}
$identity | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $directory 'identity.json')
$identity | ConvertTo-Json
