# use_env.ps1
# loads the local database settings from .env into this powershell session.
# if .env doesn't exist yet, it creates one with a random password, so no password is
# ever written into the repository. .env is listed in .gitignore and never pushed.
#
# usage, from the repository root (note the leading dot, it keeps the settings in your
# session):
#   . .\scripts\use_env.ps1

$repoRoot = (Resolve-Path "$PSScriptRoot\..").Path
$envFile = Join-Path $repoRoot ".env"

$existing = @()
if (Test-Path $envFile) {
    $existing = Get-Content $envFile | Where-Object { $_ -match '^\s*[A-Za-z_][A-Za-z0-9_]*\s*=' }
}

if ($existing.Count -eq 0) {
    $chars = [char[]]'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'
    $bytes = New-Object byte[] 24
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $generated = -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })

    @(
        "# local database settings. private to this machine, never commit this file."
        "POSTGRES_CONTAINER=kloudkart"
        "POSTGRES_PORT=5433"
        "POSTGRES_DB=kloudkart"
        "POSTGRES_PASSWORD=$generated"
    ) | Set-Content -Encoding ascii $envFile

    Write-Host "created .env with a new random database password"
}

foreach ($line in Get-Content $envFile) {
    if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$') {
        Set-Item -Path "env:$($Matches[1])" -Value $Matches[2]
    }
}

if (-not $env:POSTGRES_CONTAINER) { $env:POSTGRES_CONTAINER = "kloudkart" }
if (-not $env:POSTGRES_PORT) { $env:POSTGRES_PORT = "5433" }
if (-not $env:POSTGRES_DB) { $env:POSTGRES_DB = "kloudkart" }
if (-not $env:POSTGRES_PASSWORD) { throw ".env has no POSTGRES_PASSWORD line" }

$env:DATABASE_URL = "postgresql://postgres:$($env:POSTGRES_PASSWORD)@127.0.0.1:$($env:POSTGRES_PORT)/$($env:POSTGRES_DB)"
