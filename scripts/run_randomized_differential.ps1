$ErrorActionPreference = "Stop"

$repoRoot = Join-Path $PSScriptRoot ".."

Push-Location $repoRoot
try {
    python scripts\run_randomized_differential.py @args
    if ($LASTEXITCODE -ne 0) {
        throw "randomized differential regression failed"
    }
}
finally {
    Pop-Location
}
