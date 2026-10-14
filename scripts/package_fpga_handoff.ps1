param([string]$Name = 'systolicforge-fpga-closure-v5')
$ErrorActionPreference = 'Stop'
if ($Name -notmatch '^[A-Za-z0-9_-]+$') { throw 'Name must be a simple archive basename' }
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$releaseRoot = Join-Path $repoRoot 'release'
New-Item -ItemType Directory -Force -Path $releaseRoot | Out-Null
$archivePath = Join-Path $releaseRoot "$Name.zip"
if (Test-Path -LiteralPath $archivePath) { throw "Archive already exists: $archivePath" }
$stagingRoot = Join-Path $releaseRoot ($Name + '-' + [Guid]::NewGuid().ToString('N'))
$packageRoot = Join-Path $stagingRoot $Name
New-Item -ItemType Directory -Path $packageRoot | Out-Null
Push-Location $repoRoot
try {
    $paths = @(git ls-files --cached --others --exclude-standard)
    if ($LASTEXITCODE -ne 0) { throw 'git ls-files failed' }
    $allowedRoots = @('rtl','tb','compiler','scripts','tests','examples','fpga','synth','include','pd','docs','.github','images')
    $rootFiles = @('Makefile','README.md','LICENSE','AGENTS.md','CONTRIBUTING.md',
                  '.gitignore','.gitattributes','FPGA_RERUN.md')
    $records = foreach ($path in ($paths | Sort-Object -Unique)) {
        $components = $path.Split('/')
        if ($path -like 'docs/commercial/*') { continue }
        if ($components.Count -eq 1) {
            if ($path -notin $rootFiles) { continue }
        } elseif ($components[0] -notin $allowedRoots) { continue }
        # Exclude loose uploads/build products; include intentionally archived
        # Vivado evidence so published report links remain usable in a handoff.
        $isArchivedEvidence = $path.StartsWith('docs/evidence/vivado/')
        if (-not $isArchivedEvidence -and [IO.Path]::GetExtension($path) -in '.zip','.docx','.vvp','.log','.rpt','.dcp','.jou','.vcd','.pyc') { continue }
        $sourcePath = Join-Path $repoRoot $path
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) { continue }
        $destination = Join-Path $packageRoot $path
        New-Item -ItemType Directory -Force -Path (Split-Path $destination) | Out-Null
        Copy-Item -LiteralPath $sourcePath -Destination $destination
        [PSCustomObject]@{ Path=$path; SHA256=(Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash }
    }
    $records | Export-Csv -LiteralPath (Join-Path $packageRoot 'SOURCE_SHA256.csv') -NoTypeInformation
    $sourceRevision = git rev-parse HEAD
    $dirty = @(git status --porcelain --untracked-files=normal)
    @("base_git_commit=$sourceRevision", "working_tree_modified=$($dirty.Count -gt 0)",
      'package_source=working_tree_snapshot_with_per_file_hashes',
      'vivado_results=see_docs/evidence/vivado_for_configuration_scoped_external_reports',
      "generated_utc=$([DateTime]::UtcNow.ToString('o'))") |
        Out-File (Join-Path $packageRoot 'PACKAGE_MANIFEST.txt') -Encoding ascii
    $evidenceDirectory = Join-Path $packageRoot 'handoff_evidence'
    New-Item -ItemType Directory -Path $evidenceDirectory | Out-Null
    foreach ($evidenceName in @('fpga_closure_verification.log','fpga_closure_python_tests.log',
                               'fpga_closure_windows_tests.log','fpga_closure_stress.log',
                               'yosys_npu_full.log','yosys_xc7_synth.log')) {
        $evidencePath = Join-Path $repoRoot "build/$evidenceName"
        if (Test-Path -LiteralPath $evidencePath) {
            Copy-Item -LiteralPath $evidencePath -Destination $evidenceDirectory
        }
    }
    # Preserve the supplied reference archive separately from the new sources.
    $referenceZip = Join-Path $repoRoot 'build.zip'
    if (Test-Path -LiteralPath $referenceZip) {
        Copy-Item -LiteralPath $referenceZip -Destination (Join-Path $evidenceDirectory 'reference_vivado_build.zip')
    }
    Compress-Archive -LiteralPath $packageRoot -DestinationPath $archivePath
    Write-Host "Project handoff: $archivePath"
    Get-FileHash -LiteralPath $archivePath -Algorithm SHA256
    Write-Host "Retained staging copy: $packageRoot"
} finally { Pop-Location }
