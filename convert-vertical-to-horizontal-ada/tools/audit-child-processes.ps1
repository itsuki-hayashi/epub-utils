param(
    [Parameter(Mandatory)][string]$Executable,
    [Parameter(Mandatory)][string]$InputPath,
    [Parameter(Mandatory)][string]$OutputRoot,
    [ValidateRange(1,1024)][int]$Jobs = 16
)
$ErrorActionPreference = 'Stop'
$project=Split-Path $PSScriptRoot -Parent
$repository=[IO.Path]::GetFullPath((Join-Path $project '..'))
$OutputRoot=[IO.Path]::GetFullPath($OutputRoot)
if($OutputRoot -eq $repository -or $OutputRoot.StartsWith($repository+'\',[StringComparison]::OrdinalIgnoreCase)) {
    throw 'Keep process-audit books and reports outside the repository.'
}
foreach($file in Get-ChildItem (Join-Path $project 'src') -Recurse -File | Where-Object Extension -in '.adb','.ads','.c') {
    if([IO.File]::ReadAllText($file.FullName) -match '\b(Spawn|Non_Blocking_Spawn|CreateProcess\w*|fork|vfork|execv\w*|system|popen|ShellExecute\w*)\s*\(') {
        throw ('Process-launch call in owned converter source: '+$file.Name)
    }
}
if(-not ('EpubProcessSnapshot' -as [type])) {
Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class EpubProcessSnapshot {
 [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)]
 struct Entry {
  public uint Size,Usage,Id; public UIntPtr Heap;
  public uint Module,Threads,Parent; public int Priority; public uint Flags;
  [MarshalAs(UnmanagedType.ByValTStr,SizeConst=260)] public string Name;
 }
 [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr CreateToolhelp32Snapshot(uint flags,uint id);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool Process32FirstW(IntPtr snapshot,ref Entry entry);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool Process32NextW(IntPtr snapshot,ref Entry entry);
 [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
 public static Dictionary<int,int> Read() {
  IntPtr handle=CreateToolhelp32Snapshot(2,0);
  if(handle==new IntPtr(-1)) throw new Win32Exception(Marshal.GetLastWin32Error());
  try {
   Entry entry=new Entry();entry.Size=(uint)Marshal.SizeOf<Entry>();
   if(!Process32FirstW(handle,ref entry)) throw new Win32Exception(Marshal.GetLastWin32Error());
   var rows=new Dictionary<int,int>();
   do { rows[checked((int)entry.Id)]=checked((int)entry.Parent); } while(Process32NextW(handle,ref entry));
   int error=Marshal.GetLastWin32Error();
   if(error!=18) throw new Win32Exception(error);
   return rows;
  } finally {CloseHandle(handle);}
 }
}
"@
}
$directory=Join-Path $OutputRoot ('process-audit-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $directory|Out-Null
$process=$null
try {
    $start=[Diagnostics.ProcessStartInfo]::new([IO.Path]::GetFullPath($Executable))
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true;$start.RedirectStandardInput=$true
    $start.StandardOutputEncoding=[Text.UTF8Encoding]::new($false)
    foreach($argument in @('--input-path',[IO.Path]::GetFullPath($InputPath),'--output-directory',
        (Join-Path $directory 'books'),'--json','--jobs',"$Jobs")) {$start.ArgumentList.Add($argument)}
    $null=[EpubProcessSnapshot]::Read()
    $process=[Diagnostics.Process]::Start($start)
    $process.StandardInput.Close()
    $parentStarted=$process.StartTime.ToUniversalTime()
    $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
    $children=[Collections.Generic.HashSet[int]]::new()
    $consoleHosts=[Collections.Generic.HashSet[int]]::new()
    $candidates=@{}
    $watch=[Diagnostics.Stopwatch]::StartNew()
    $samples=0;$observed=$false;$last=0.0;$maxGap=0.0
    do {
        $rows=[EpubProcessSnapshot]::Read();$samples++
        $now=$watch.Elapsed.TotalMilliseconds;$maxGap=[Math]::Max($maxGap,$now-$last);$last=$now
        $observed=$observed -or $rows.ContainsKey($process.Id)
        foreach($row in $rows.GetEnumerator()) {
            if($row.Value -eq $process.Id) {
                # A surviving process can retain the ID of a long-dead parent.
                # Compare creation times before attributing reused parent IDs.
                $candidate=[Diagnostics.Process]::GetProcessById($row.Key)
                try {
                    $created=$candidate.StartTime.ToUniversalTime()
                    $image=$candidate.MainModule.FileName
                    $systemHost=$image -eq (Join-Path ([Environment]::GetFolderPath('System')) 'conhost.exe')
                    $candidates[$row.Key]=[pscustomobject]@{Id=$row.Key;Name=$candidate.ProcessName;Image=$image;
                        Created=$created;OlderThanConverter=($created -lt $parentStarted);SystemConsoleHost=$systemHost}
                    if($created -ge $parentStarted) {
                        if($systemHost){$null=$consoleHosts.Add($row.Key)}else{$null=$children.Add($row.Key)}
                    }
                } finally {$candidate.Dispose()}
            }
        }
    } while(-not $process.WaitForExit(5))
    [IO.File]::WriteAllText((Join-Path $directory 'report.json'),$stdout.GetAwaiter().GetResult(),[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $directory 'stderr.log'),$stderr.GetAwaiter().GetResult())
    if($process.ExitCode -ne 0 -or -not $observed){throw 'Converter failed or was not observed by the process audit.'}
    $result=[pscustomobject]@{BinarySHA256=(Get-FileHash -LiteralPath $Executable).Hash;
        Jobs=$Jobs;ObservedApplicationChildProcesses=$children.Count;SystemConsoleHosts=$consoleHosts.Count;StaticOwnedSourceAudit=$true;
        Method='Toolhelp process snapshots plus source inspection';Samples=$samples;MaxPollGapMilliseconds=$maxGap;
        ParentStarted=$parentStarted;ParentIDCandidates=@($candidates.Values);
        Limitation='Sampling alone cannot exclude a child shorter than the observed polling gaps.';
        Result=$(if($children.Count){'FAIL'}else{'PASS'})}
    $result|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $directory 'summary.json')
    $result|ConvertTo-Json
    if($children.Count){throw 'The converter created application child processes.'}
} finally {if($process){$process.Dispose()}}
