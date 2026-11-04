# Shared by the benchmark and its deterministic statistical checks.
function Get-PerformanceLatencyGate([double]$ControlSeconds, [double]$CandidateSeconds) {
    if ($ControlSeconds -le 0 -or $CandidateSeconds -le 0 -or
        -not [double]::IsFinite($ControlSeconds) -or -not [double]::IsFinite($CandidateSeconds)) {
        throw 'Positive finite median timings are required.'
    }
    # Classify by the frozen control median, so the candidate cannot move the
    # cutoff. The short-invocation allowance is absolute, without an added 2%.
    $short = $ControlSeconds -lt 0.250
    $limit = if ($short) { $ControlSeconds + 0.020 } else { $ControlSeconds * 1.02 }
    [pscustomobject]@{
        Rule = if ($short) { 'Fixed20ms' } else { 'Relative2Percent' }
        ControlSeconds = $ControlSeconds
        CandidateSeconds = $CandidateSeconds
        AddedSeconds = $CandidateSeconds - $ControlSeconds
        MaximumCandidateSeconds = $limit
        Pass = $CandidateSeconds - $limit -le 1e-12
    }
}

function Get-PerformanceMedian([double[]]$Values) {
    if (-not $Values.Count) { throw 'A nonempty sample is required.' }
    $sorted = [double[]]$Values.Clone()
    [Array]::Sort($sorted)
    $middle = [int][Math]::Floor($sorted.Count / 2)
    if ($sorted.Count % 2) { return $sorted[$middle] }
    return ($sorted[$middle - 1] + $sorted[$middle]) / 2
}

function Get-PairedSpeedup([double[]]$Control, [double[]]$Candidate, [int]$Resamples = 10000) {
    if ($Control.Count -ne $Candidate.Count -or $Control.Count -lt 2 -or
        @($Control + $Candidate | Where-Object { $_ -le 0 -or -not [double]::IsFinite($_) }).Count) {
        throw 'Paired positive finite timing samples are required.'
    }
    $random = [Random]::new(20261104)
    $ratios = [double[]]::new($Resamples)
    $left = [double[]]::new($Control.Count)
    $right = [double[]]::new($Control.Count)
    for ($trial = 0; $trial -lt $Resamples; $trial++) {
        for ($index = 0; $index -lt $Control.Count; $index++) {
            $pair = $random.Next($Control.Count)
            $left[$index] = $Control[$pair]
            $right[$index] = $Candidate[$pair]
        }
        $ratios[$trial] = (Get-PerformanceMedian $left) / (Get-PerformanceMedian $right)
    }
    [Array]::Sort($ratios)
    [pscustomobject]@{
        Speedup = (Get-PerformanceMedian $Control) / (Get-PerformanceMedian $Candidate)
        Lower95 = $ratios[[int][Math]::Floor(0.025 * $Resamples)]
        Upper95 = $ratios[[int][Math]::Ceiling(0.975 * $Resamples) - 1]
        Resamples = $Resamples
        Seed = 20261104
    }
}
