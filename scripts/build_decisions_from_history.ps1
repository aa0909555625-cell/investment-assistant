#Requires -Version 5.1
[CmdletBinding()]
param(
  [int]$LookbackDays = 120,     # decisions output window
  [int]$SmaFast = 20,
  [int]$SmaSlow = 60,
  [int]$RocDays = 20
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$histDir = ".\data\history"
$outPath = ".\data\all_stocks_decisions.csv"

if (!(Test-Path $histDir)) { throw "history dir not found: $histDir" }

function To-Date([string]$s){ [datetime]::Parse($s) }

function SMA([double[]]$arr, [int]$n, [int]$i){
  if ($i -lt ($n-1)) { return $null }
  $sum = 0.0
  for ($k = $i-($n-1); $k -le $i; $k++) { $sum += $arr[$k] }
  return $sum / $n
}

function ROC([double[]]$arr, [int]$n, [int]$i){
  if ($i -lt $n) { return $null }
  $prev = $arr[$i-$n]
  if ($prev -le 0) { return $null }
  return (($arr[$i] - $prev) / $prev) * 100.0
}

$files = Get-ChildItem $histDir -Filter *.csv
if ($files.Count -eq 0) { throw "no history csv files in $histDir" }

$all = @()

foreach ($f in $files) {
  $code = [IO.Path]::GetFileNameWithoutExtension($f.Name)

  $rows = @(Import-Csv $f.FullName | Where-Object { $_.date -and $_.close } | Sort-Object date)
  if ($rows.Length -lt 80) { continue }

  $dates  = @()
  $closeA = @()

  foreach ($r in $rows) {
    $dates  += [datetime]$r.date
    $closeA += [double]$r.close
  }

  $startCut = (Get-Date).AddDays(-1 * $LookbackDays).Date

  for ($i=0; $i -lt $rows.Length; $i++) {

    if ($dates[$i].Date -lt $startCut) { continue }

    $smaF = SMA $closeA $SmaFast $i
    $smaS = SMA $closeA $SmaSlow $i
    $roc  = ROC $closeA $RocDays $i

    if ($null -eq $smaF -or $null -eq $smaS -or $null -eq $roc) { continue }

    # score: base 50 + trend(0/25) + momentum(-10..+25)
    $trend = if ($smaF -gt $smaS) { 25 } else { 0 }
    $mom = [math]::Max(-10, [math]::Min(25, [math]::Round($roc/2,0)))
    $score = 50 + $trend + $mom
    if ($score -gt 99) { $score = 99 }
    if ($score -lt 1)  { $score = 1 }

    # daily change% (close-to-prev-close)
    $chg = $null
    if ($i -ge 1 -and $closeA[$i-1] -gt 0) {
      $chg = (($closeA[$i] - $closeA[$i-1]) / $closeA[$i-1]) * 100.0
      $chg = [math]::Round($chg,4)
    } else {
      $chg = 0.0
    }

    $all += [PSCustomObject]@{
      date = $dates[$i].ToString("yyyy-MM-dd")
      code = $code
      name = $code
      sector = "unknown"
      change_percent = $chg
      total_score = $score
      liquidity = 0
      volatility = 0
      momentum = [math]::Round($roc,4)
      warnings = ""
    }
  }
}

$all = @($all | Sort-Object date, code)

if ($all.Length -lt 200) {
  throw "too few decision rows built: $($all.Length). Ensure history has close and enough length."
}

$all | Export-Csv $outPath -NoTypeInformation -Encoding UTF8
Write-Host ("OK: built decisions history -> {0} (rows={1})" -f $outPath, $all.Length) -ForegroundColor Green