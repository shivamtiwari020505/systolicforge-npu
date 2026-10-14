param([ValidateSet('full', 'basys3', 'all')][string]$Flow = 'all')
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
# Vivado installs both vivado.bat and an extensionless vivado launcher. Without
# selecting one match, .Source enumerates both paths and '&' cannot execute it.
$vivadoCommand = Get-Command vivado -CommandType Application -ErrorAction Stop |
    Select-Object -First 1
$runRoot = Join-Path $repoRoot ('build/vivado_runs/' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
New-Item -ItemType Directory -Path $runRoot | Out-Null
$previousRunRoot = $env:SYSTOLICFORGE_RUN_ROOT
$env:SYSTOLICFORGE_RUN_ROOT = $runRoot
$failed = $false
Push-Location $repoRoot
try {
    # Hash actual synthesis sources even in a ZIP extraction with no .git.
    Get-ChildItem rtl,fpga -Recurse -File |
        Where-Object { $_.Extension -in '.sv','.xdc','.tcl','.ps1','.cmd' } |
        Sort-Object FullName | ForEach-Object {
            [PSCustomObject]@{
                Path = $_.FullName.Substring($repoRoot.Length + 1).Replace('\','/')
                SHA256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
            }
        } | Export-Csv -LiteralPath (Join-Path $runRoot 'source_hashes.csv') -NoTypeInformation
    # Read the authoritative version from the Tcl build manifests, not a
    # separate native -version preflight. An informational launcher exit code
    # must not stop the actual synthesis/implementation attempt.
    @("vivado_executable=$($vivadoCommand.Source)",
      'vivado_version=recorded_by_Tcl_in_each_build_manifest') |
        Out-File (Join-Path $runRoot 'launch_info.txt') -Encoding ascii
    $flows = if ($Flow -eq 'all') { @('full', 'basys3') } else { @($Flow) }
    foreach ($selectedFlow in $flows) {
        $directoryName = if ($selectedFlow -eq 'full') { 'vivado_npu_ooc_full' } else { 'vivado_basys3' }
        $scriptName = if ($selectedFlow -eq 'full') { 'synth_npu_ooc.tcl' } else { 'build_basys3.tcl' }
        $buildDirectory = Join-Path $runRoot $directoryName
        New-Item -ItemType Directory -Path $buildDirectory | Out-Null
        $arguments = @('-mode','batch','-source',(Join-Path $PSScriptRoot $scriptName),
            '-log',(Join-Path $buildDirectory 'vivado.log'),
            '-journal',(Join-Path $buildDirectory 'vivado.jou'))
        if ($selectedFlow -eq 'full') { $arguments += @('-tclargs','full') }
        & $vivadoCommand.Source @arguments
        $exitCode = $LASTEXITCODE
        "exit_code=$exitCode" | Out-File (Join-Path $buildDirectory 'run_status.txt') -Encoding ascii
        if ($exitCode -ne 0) { $failed = $true }
    }
} finally {
    Pop-Location
    $env:SYSTOLICFORGE_RUN_ROOT = $previousRunRoot
    $archivePath = "$runRoot.zip"
    Compress-Archive -LiteralPath $runRoot -DestinationPath $archivePath
    Write-Host "Return this results archive: $archivePath"
}
if ($failed) { exit 1 }
