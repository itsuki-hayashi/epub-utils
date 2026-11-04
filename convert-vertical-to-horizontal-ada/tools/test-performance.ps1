$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'performance-statistics.ps1')
function Check([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
Check ((Get-PerformanceMedian @(4,1,3,2)) -eq 2.5) 'Even median'
Check ((Get-PerformanceMedian @(4,1,3)) -eq 3) 'Odd median'
Check (Get-PerformanceLatencyGate 0.1 0.12).Pass '20ms short-invocation boundary'
Check (-not (Get-PerformanceLatencyGate 0.1 0.120001).Pass) 'Short allowance must not exceed20ms'
Check (Get-PerformanceLatencyGate 0.249 0.269).Pass 'Short classification uses the control median'
Check ((Get-PerformanceLatencyGate 0.25 0.255).Rule -eq 'Relative2Percent') '250ms uses the relative rule'
Check (Get-PerformanceLatencyGate 0.25 0.255).Pass '2% boundary at250ms'
Check (-not (Get-PerformanceLatencyGate 0.25 0.256).Pass) 'No absolute allowance at250ms'
Check (Get-PerformanceLatencyGate 10 10.2).Pass '2% long-invocation boundary'
Check (-not (Get-PerformanceLatencyGate 10 10.200001).Pass) 'Long allowance remains2%'
$interval = Get-PairedSpeedup @(10,20,30,40,50,60,70,80) @(8,16,24,32,40,48,56,64) 1000
Check ($interval.Speedup -eq 1.25 -and $interval.Lower95 -eq 1.25 -and $interval.Upper95 -eq 1.25) 'Paired resampling retains correlation'
$same = Get-PairedSpeedup @(10,20,30,40) @(10,20,30,40) 1000
Check ($same.Lower95 -eq 1 -and $same.Upper95 -eq 1) 'Identical timings cannot imply a gain'
foreach ($case in @(@(@(1),@(1)), @(@(1,2),@(1)), @(@(0,1),@(1,1)), @(@(1,2),@([double]::NaN,1)))) {
    $rejected = $false
    try { $null = Get-PairedSpeedup $case[0] $case[1] 100 }
    catch { $rejected = $true }
    Check $rejected 'Invalid sample accepted'
}
$directory = Join-Path ([IO.Path]::GetTempPath()) ('performance-gates-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $directory
$paths = @('converted','preserved','mixed') | ForEach-Object {Join-Path $directory ($_+'.json')}
try {
    foreach ($scenario in @('valid','limited','wrong-cohort','workload-regression','wrong-binary','memory-failure',
                           'short-allowed','short-too-slow','cutoff-too-slow')) {
        $converted = [pscustomobject]@{ComparisonOnly=$true;Pairs=8;Limit=0;DualCompressionGate=$true;
            MemoryWithinBudget=$true;CandidateBinarySHA256='candidate';ControlBinarySHA256='control';
            InputSHA256s=@('a','b');Books=2;Workload='Converted';PromotionTimingMet=$true;RelativeSpeedup=1.1;
            ControlMedianSeconds=1.1;CandidateMedianSeconds=1.0;Label='converted'}
        $preserved = $converted | ConvertTo-Json | ConvertFrom-Json
        $preserved.Workload='Preserved'; $preserved.Books=1; $preserved.InputSHA256s=@('c')
        $preserved.PromotionTimingMet=$false; $preserved.RelativeSpeedup=1.0
        $preserved.ControlMedianSeconds=1.0; $preserved.Label='preserved'
        $mixed = $converted | ConvertTo-Json | ConvertFrom-Json
        $mixed.Workload='Mixed'; $mixed.Books=3; $mixed.InputSHA256s=@('a','b','c')
        switch ($scenario) {
            limited { $converted.Limit=12 }
            wrong-cohort { $mixed.InputSHA256s=@('a','b','d') }
            workload-regression { $preserved.RelativeSpeedup=0.97; $preserved.CandidateMedianSeconds=1/0.97 }
            wrong-binary { $mixed.CandidateBinarySHA256='different' }
            memory-failure { $mixed.MemoryWithinBudget=$false }
            short-allowed { $preserved.ControlMedianSeconds=0.1; $preserved.CandidateMedianSeconds=0.12; $preserved.RelativeSpeedup=0.1/0.12 }
            short-too-slow { $preserved.ControlMedianSeconds=0.1; $preserved.CandidateMedianSeconds=0.121; $preserved.RelativeSpeedup=0.1/0.121 }
            cutoff-too-slow { $preserved.ControlMedianSeconds=0.25; $preserved.CandidateMedianSeconds=0.256; $preserved.RelativeSpeedup=0.25/0.256 }
        }
        $converted | ConvertTo-Json | Set-Content -LiteralPath $paths[0]
        $preserved | ConvertTo-Json | Set-Content -LiteralPath $paths[1]
        $mixed | ConvertTo-Json | Set-Content -LiteralPath $paths[2]
        $accepted = $true
        try {
            & (Join-Path $PSScriptRoot 'evaluate-performance.ps1') -ConvertedSummary $paths[0] `
                -PreservedSummary $paths[1] -MixedSummary $paths[2] | Out-Null
        } catch { $accepted = $false }
        Check ($accepted -eq ($scenario -in @('valid','short-allowed'))) ('Unexpected promotion decision: ' + $scenario)
    }
} finally {
    foreach ($path in $paths) { if(Test-Path -LiteralPath $path) {Remove-Item -LiteralPath $path} }
    Remove-Item -LiteralPath $directory
}
foreach ($path in Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1') {
    $tokens = $null; $errors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile($path.FullName,[ref]$tokens,[ref]$errors)
    Check ($errors.Count -eq 0) ('PowerShell parse failed: ' + $path.Name + ': ' + ($errors -join '; '))
}
Write-Output 'PASS performance statistics, promotion gates and PowerShell syntax'
