# run_race_test_10x.ps1
# runs the unmodified race_test.py several times in a row and saves every run's output to
# benchmarks/race_test_runs.txt. one pass proves very little about a race; ten in a row
# is much harder to get lucky with.
#
# usage, from the repository root, with the virtual environment set up:
#   .\scripts\run_race_test_10x.ps1
#   .\scripts\run_race_test_10x.ps1 -runs 20
#
# the connection details come from .env (see use_env.ps1), never from this file.

param(
    [int]$Runs = 10
)

. "$PSScriptRoot\use_env.ps1"

$repo = (Resolve-Path "$PSScriptRoot\..").Path
$python = Join-Path $repo ".venv\Scripts\python.exe"
if (-not (Test-Path $python)) { $python = "python" }

$out = Join-Path $repo "benchmarks\race_test_runs.txt"
$passed = 0

"race_test.py, $Runs consecutive runs, $(Get-Date -Format 'yyyy-MM-dd HH:mm')" | Set-Content -Encoding utf8 $out

Push-Location (Join-Path $repo "M03_Resources")
try {
    for ($i = 1; $i -le $Runs; $i++) {
        "`n######## run $i of $Runs ########" | Add-Content -Encoding utf8 $out
        $result = & $python race_test.py 2>&1 | Out-String
        $result | Add-Content -Encoding utf8 $out
        if ($LASTEXITCODE -eq 0) { $passed++ }
        Write-Host ("run {0}: {1}" -f $i, $(if ($LASTEXITCODE -eq 0) { "passed" } else { "FAILED" }))
    }
} finally {
    Pop-Location
}

"`nsummary: $passed of $Runs runs passed" | Add-Content -Encoding utf8 $out
Write-Host "$passed of $Runs runs passed. full output in benchmarks\race_test_runs.txt"
if ($passed -ne $Runs) { exit 1 }
