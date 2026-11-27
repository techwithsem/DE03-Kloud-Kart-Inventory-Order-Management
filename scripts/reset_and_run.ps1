# reset_and_run.ps1
# rebuilds the kloudkart database from nothing and runs the full solution.
#   1. reads the database settings from .env (creating it with a random password if needed)
#   2. starts a postgresql 18 container with max_connections=500 if it isn't running.
#      it only accepts connections from this computer, not from the network.
#   3. drops and recreates the database
#   4. loads the supplied schema and csvs, exactly as shipped
#   5. runs sql/run_all.sql
#
# usage, from the repository root:
#   .\scripts\reset_and_run.ps1
#
# the password is fixed when the container is first created. if you change it in .env
# afterwards, remove the old container first: docker rm -f kloudkart

# windows powershell 5.1 turns any text a program writes to stderr into an error, and
# postgres writes harmless notices there. so failures are caught by exit code instead.
$ErrorActionPreference = "Continue"

. "$PSScriptRoot\use_env.ps1"

$repo = (Resolve-Path "$PSScriptRoot\..").Path
$container = $env:POSTGRES_CONTAINER
$port = $env:POSTGRES_PORT
$database = $env:POSTGRES_DB

$exists = docker ps -a --filter "name=^$container$" --format "{{.Names}}"
if (-not $exists) {
    Write-Host "starting a new postgres 18 container '$container' on 127.0.0.1:$port"
    docker run -d --name $container `
        -e POSTGRES_PASSWORD=$env:POSTGRES_PASSWORD `
        -p "127.0.0.1:${port}:5432" `
        -v "${repo}:/work" `
        postgres:18 -c max_connections=500 -c shared_buffers=256MB | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "could not start the postgres container" }
} else {
    docker start $container | Out-Null
}

Write-Host "waiting for postgres to accept connections"
do {
    Start-Sleep -Milliseconds 500
    docker exec $container pg_isready -U postgres -q
} until ($LASTEXITCODE -eq 0)

Write-Host "recreating database '$database'"
docker exec $container psql -U postgres -qX -d postgres -c "DROP DATABASE IF EXISTS $database WITH (FORCE)"
docker exec $container psql -U postgres -qX -d postgres -c "CREATE DATABASE $database"

Write-Host "loading the supplied schema and data"
docker exec -e PGOPTIONS="-c client_min_messages=warning" -w /work/M03_Resources $container psql -U postgres -d $database -qX -v ON_ERROR_STOP=1 -f schema.sql
if ($LASTEXITCODE -ne 0) { throw "schema.sql failed" }
docker exec -e PGOPTIONS="-c client_min_messages=warning" -w /work/M03_Resources $container psql -U postgres -d $database -X -v ON_ERROR_STOP=1 -f load.sql
if ($LASTEXITCODE -ne 0) { throw "load.sql failed" }

Write-Host "running the solution"
docker exec -e PGOPTIONS="-c client_min_messages=warning" -w /work $container psql -U postgres -d $database -X -v ON_ERROR_STOP=1 -f sql/run_all.sql
if ($LASTEXITCODE -ne 0) { throw "run_all.sql failed" }

Write-Host ""
Write-Host "done. for the race test, in this window:"
Write-Host "  . .\scripts\use_env.ps1"
Write-Host "  cd M03_Resources; python race_test.py"
