# Runs every pytest test file plus the four SQL data-quality suites and prints a report.
[CmdletBinding()]
param(
    [string]$Filter = "",
    [string]$Marker = "unit or smoke",
    [switch]$SkipDq,
    [string]$ReportDir = ""
)

$ErrorActionPreference = "Stop"

$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo

if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
    Write-Output "uv not found in PATH - install uv first (https://docs.astral.sh/uv/)"
    exit 2
}

if (-not $ReportDir) { $ReportDir = Join-Path $repo "logs" }
New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null

$startedAt = Get-Date
$stamp = $startedAt.ToString("yyyyMMdd-HHmmss")

function Invoke-Captured {
    param([string[]]$Cli)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $out = & uv @Cli 2>&1
    $code = $LASTEXITCODE
    $sw.Stop()
    [pscustomobject]@{
        Code    = $code
        Text    = (@($out | ForEach-Object { "$_" }) -join "`n")
        Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    }
}

function Get-Counts {
    param([string]$Text)
    $tail = (@($Text -split "`r?`n") | Select-Object -Last 25) -join " "
    $c = @{ passed = 0; failed = 0; errors = 0; skipped = 0; deselected = 0 }
    foreach ($name in @("passed", "failed", "skipped", "deselected")) {
        if ($tail -match "(\d+)\s+$name\b") { $c[$name] = [int]$Matches[1] }
    }
    if ($tail -match "(\d+)\s+errors?\b") { $c["errors"] = [int]$Matches[1] }
    [pscustomobject]$c
}

function Get-Status {
    param([int]$Code, $Counts)
    if ($Counts.failed -gt 0 -or $Counts.errors -gt 0) { return "FAIL" }
    if ($Counts.passed -gt 0) { return "PASS" }
    if ($Code -eq 0 -or $Code -eq 5) { return "EMPTY" }
    return "ERROR"
}

$files = @(Get-ChildItem -Path (Join-Path $repo "tests"), (Join-Path $repo "airflow\tests") `
        -Recurse -Filter "test_*.py" -ErrorAction SilentlyContinue)
if ($Filter) {
    $files = @($files | Where-Object { $_.FullName.Replace("$repo\", "") -like "*$Filter*" })
}
$files = @($files | Sort-Object FullName)

$rows = [System.Collections.Generic.List[object]]::new()
$details = [System.Collections.Generic.List[string]]::new()
$dqLayers = @("raw", "staging", "analytics", "marts")
$total = $files.Count + $(if ($SkipDq) { 0 } else { @($dqLayers | Where-Object { -not $Filter -or $_ -like "*$Filter*" }).Count })
$scopes = if ($SkipDq) { "tests + airflow/tests" } else { "tests + airflow/tests + SQL data-quality suites" }
Write-Output "Running $total test file(s) | marker: $(if ($Marker) { $Marker } else { '(none)' })"

$index = 0
foreach ($file in $files) {
    $index++
    $rel = $file.FullName.Replace("$repo\", "")
    $cli = @("run", "pytest", $rel, "-q", "--tb=short")
    if ($Marker -and $Marker -ne "all") { $cli += @("-m", $Marker) }
    $run = Invoke-Captured -Cli $cli
    $counts = Get-Counts -Text $run.Text
    $status = Get-Status -Code $run.Code -Counts $counts
    $rows.Add([pscustomobject]@{
            File = $rel; Status = $status; Counts = $counts
            Seconds = $run.Seconds; Code = $run.Code
        })
    Write-Output ("[{0,3}/{1}] {2,-5} {3} ({4}s)" -f $index, $total, $status, $rel, $run.Seconds)
    if ($status -eq "FAIL" -or $status -eq "ERROR") {
        $tail = @($run.Text -split "`r?`n" | Select-Object -Last 30) -join "`n"
        $details.Add("----- $rel (exit $($run.Code)) -----`n$tail")
    }
}

if (-not $SkipDq) {
    foreach ($layer in $dqLayers) {
        if ($Filter -and $layer -notlike "*$Filter*") { continue }
        $index++
        $rel = "scripts\run_${layer}_tests.py"
        $run = Invoke-Captured -Cli @("run", "scripts\run_${layer}_tests.py")
        $c = @{ passed = 0; failed = 0; errors = 0; skipped = 0; deselected = 0 }
        if ($run.Text -match "All (\d+) .*tests passed") {
            $c.passed = [int]$Matches[1]
        }
        elseif ($run.Text -match "(\d+) of (\d+) tests failed") {
            $c.failed = [int]$Matches[1]
            $c.passed = [int]$Matches[2] - $c.failed
        }
        $counts = [pscustomobject]$c
        $status = Get-Status -Code $run.Code -Counts $counts
        $rows.Add([pscustomobject]@{
                File = $rel; Status = $status; Counts = $counts
                Seconds = $run.Seconds; Code = $run.Code
            })
        Write-Output ("[{0,3}/{1}] {2,-5} {3} ({4}s)" -f $index, $total, $status, $rel, $run.Seconds)
        if ($status -eq "FAIL" -or $status -eq "ERROR") {
            $tail = @($run.Text -split "`r?`n" | Select-Object -Last 30) -join "`n"
            $details.Add("----- $rel (exit $($run.Code)) -----`n$tail")
        }
    }
}

$sum = @{ passed = 0; failed = 0; errors = 0; skipped = 0; deselected = 0 }
$byStatus = @{}
$totalSeconds = 0.0
foreach ($row in $rows) {
    $sum["passed"] += $row.Counts.passed
    $sum["failed"] += $row.Counts.failed
    $sum["errors"] += $row.Counts.errors
    $sum["skipped"] += $row.Counts.skipped
    $sum["deselected"] += $row.Counts.deselected
    $status = $row.Status
    $byStatus[$status] = 1 + $(if ($byStatus[$status]) { $byStatus[$status] } else { 0 })
    $totalSeconds += $row.Seconds
}

$failed = @($rows | Where-Object { $_.Status -eq "FAIL" -or $_.Status -eq "ERROR" })
$result = if ($failed.Count -eq 0) { "PASS" } else { "FAIL" }
$dash = "=" * 106

$report = @(
    $dash
    " Test report - banking-delta-lakehouse"
    " Started : $($startedAt.ToString('yyyy-MM-dd HH:mm:ss'))"
    " Host    : $env:COMPUTERNAME"
    " Scope   : $scopes"
    " Marker  : $(if ($Marker) { $Marker } else { '(none)' })   Filter: $(if ($Filter) { $Filter } else { '(all files)' })"
    $dash
    (" {0,-3} {1,-50} {2,-6} {3,7} {4,7} {5,7} {6,8} {7,8}" -f "#", "File", "Status", "Passed", "Failed", "Errors", "Skipped", "Time")
    (" {0,-3} {1,-50} {2,-6} {3,7} {4,7} {5,7} {6,8} {7,8}" -f "---", ("-" * 50), "------", "-------", "-------", "-------", "--------", "--------")
)

$index = 0
foreach ($row in $rows) {
    $index++
    $report += (" {0,-3} {1,-50} {2,-6} {3,7} {4,7} {5,7} {6,8} {7,8}" -f
        $index, $row.File, $row.Status, $row.Counts.passed, $row.Counts.failed,
        $row.Counts.errors, $row.Counts.skipped, "$($row.Seconds)s")
}

$report += ("-" * 106)
$report += (" Files   : {0} total   PASS={1}  FAIL={2}  EMPTY={3}  ERROR={4}" -f
    $rows.Count,
    $(if ($byStatus["PASS"]) { $byStatus["PASS"] } else { 0 }),
    $(if ($byStatus["FAIL"]) { $byStatus["FAIL"] } else { 0 }),
    $(if ($byStatus["EMPTY"]) { $byStatus["EMPTY"] } else { 0 }),
    $(if ($byStatus["ERROR"]) { $byStatus["ERROR"] } else { 0 }))
$report += (" Tests   : {0} passed, {1} failed, {2} errors, {3} skipped, {4} deselected" -f
    $sum.passed, $sum.failed, $sum.errors, $sum.skipped, $sum.deselected)
$report += (" Duration: {0:N1}s wall" -f ((Get-Date) - $startedAt).TotalSeconds)
$report += (" RESULT  : {0}" -f $result)
if ($details.Count -gt 0) {
    $report += ""
    $report += " FAILURE DETAIL"
    foreach ($detail in $details) { $report += $detail }
}
$report += $dash

$reportPath = Join-Path $ReportDir "test-report-$stamp.txt"
$report | Set-Content -Path $reportPath -Encoding utf8
$report | Write-Output
Write-Output " Report saved: $reportPath"

if ($result -eq "FAIL") { exit 1 }
exit 0
