#Requires -Version 5.1
[CmdletBinding()]
param(
  [int]$TopN = 50,
  [string]$OutPath = ".\data\universe_symbols.csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-FullPathSafe([string]$path){
  if ([System.IO.Path]::IsPathRooted($path)) { return $path }
  return [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $path))
}

function Ensure-Dir([string]$path){
  $dir = Split-Path -Parent $path
  if ($dir -and !(Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
}

function Write-Utf8NoBomFile([string]$path, [string]$text){
  $enc = New-Object System.Text.UTF8Encoding($false)
  Ensure-Dir $path
  [System.IO.File]::WriteAllText($path, $text, $enc)
}

function Get-RawBytesFromWebResponse($resp){
  $bytes = $null
  try {
    $ms = New-Object System.IO.MemoryStream
    $resp.RawContentStream.CopyTo($ms)
    $bytes = $ms.ToArray()
  } catch {
    if ($null -ne $resp.Content) {
      $bytes = [System.Text.Encoding]::ASCII.GetBytes([string]$resp.Content)
    }
  }
  if ($null -eq $bytes -or $bytes.Length -eq 0) { throw "Empty response bytes" }
  return $bytes
}

function Fetch-OpenApiStockDayAll() {
  $url = "https://openapi.twse.com.tw/v1/exchangeReport/STOCK_DAY_ALL"
  Write-Host "[FETCH] $url" -ForegroundColor Cyan

  # PS5.1：用 IWR 取 raw bytes，強制 UTF-8 decode，避免中文亂碼
  $resp = Invoke-WebRequest -Uri $url -Method Get -TimeoutSec 30 -UseBasicParsing
  $bytes = Get-RawBytesFromWebResponse $resp
  $jsonText = [System.Text.Encoding]::UTF8.GetString($bytes)

  $data = $jsonText | ConvertFrom-Json
  if ($null -eq $data) { throw "OpenAPI JSON parsed null" }
  return $data
}

function Fetch-LegacyCsvBig5() {
  $url = "https://www.twse.com.tw/exchangeReport/STOCK_DAY_ALL?response=open_data"
  Write-Host "[FETCH] $url" -ForegroundColor DarkYellow

  $resp = Invoke-WebRequest -Uri $url -Method Get -TimeoutSec 30 -UseBasicParsing
  $bytes = Get-RawBytesFromWebResponse $resp

  $big5 = [System.Text.Encoding]::GetEncoding("big5")
  $text = $big5.GetString($bytes)

  return ($text | ConvertFrom-Csv)
}

function Normalize-Row([object]$row) {
  # OpenAPI: Code / Name / TradeValue ...
  # Legacy CSV: 證券代號 / 證券名稱 / 成交金額 ...
  $code = $null
  $name = $null
  $tradeValue = $null

  $props = @{}
  foreach ($p in $row.PSObject.Properties) { $props[$p.Name] = $p.Value }

  if ($props.ContainsKey("Code")) { $code = [string]$props["Code"] }
  elseif ($props.ContainsKey("證券代號")) { $code = [string]$props["證券代號"] }

  if ($props.ContainsKey("Name")) { $name = [string]$props["Name"] }
  elseif ($props.ContainsKey("證券名稱")) { $name = [string]$props["證券名稱"] }

  if ($props.ContainsKey("TradeValue")) { $tradeValue = $props["TradeValue"] }
  elseif ($props.ContainsKey("成交金額")) { $tradeValue = $props["成交金額"] }

  $tv = 0
  if ($null -ne $tradeValue) {
    $s = ([string]$tradeValue).Replace(",","").Trim()
    [void][int64]::TryParse($s, [ref]$tv)
  }

  $sym = ""
  if ($null -ne $code) { $sym = ([string]$code).Trim() }

  $nm = ""
  if ($null -ne $name) { $nm = ([string]$name).Trim() }

  [pscustomobject]@{
    symbol     = $sym
    name       = $nm
    tradeValue = $tv
    market     = "TSE"
  }
}

# ===== main =====
$outFull = Get-FullPathSafe $OutPath
Ensure-Dir $outFull

$rows = $null
$mode = "openapi"

try {
  $rows = Fetch-OpenApiStockDayAll
} catch {
  Write-Host ("[WARN] OpenAPI failed, fallback to legacy CSV (Big5). Reason: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
  $mode = "legacy_csv"
  $rows = Fetch-LegacyCsvBig5
}

if ($null -eq $rows -or $rows.Count -eq 0) {
  throw "No rows fetched from TWSE source (mode=$mode)."
}

$norm = foreach ($r in $rows) { Normalize-Row $r }
$norm = $norm | Where-Object { $_.symbol -match '^\d{4}$' }

if ($null -eq $norm -or $norm.Count -eq 0) {
  $sample = $rows | Select-Object -First 1 | ConvertTo-Json -Depth 3
  throw "No 4-digit codes found after normalization. mode=$mode | sample(first row)=$sample"
}

$top = $norm |
  Sort-Object tradeValue -Descending |
  Select-Object -First $TopN |
  Select-Object symbol, name, market

$csvLines = $top | ConvertTo-Csv -NoTypeInformation
Write-Utf8NoBomFile $outFull ($csvLines -join "`r`n")

if (!(Test-Path $outFull)) { throw "Write failed: $outFull" }

Write-Host ("OK: wrote universe -> {0} (rows={1}, mode={2})" -f $outFull, $top.Count, $mode) -ForegroundColor Green
Write-Host "Sample:" -ForegroundColor DarkGray
$top | Select-Object -First 10 | Format-Table -AutoSize