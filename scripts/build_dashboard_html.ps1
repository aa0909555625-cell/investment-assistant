#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$Date = "",
  [int]$Capital = 300000,
  [int]$Top = 200,

  # run_dashboard.ps1 uses -ReportsDir; older/manual callers may use -OutDir
  [Alias("OutDir")]
  [string]$ReportsDir = ".\reports",

  [string]$TemplatePath = ".\templates\dashboard_template.html",
  [switch]$Open,
  [switch]$ListDates
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# [MARKER] BUILD_DASHBOARD_HTML_PS51_v1

function EnsureDir([string]$p){
  if([string]::IsNullOrWhiteSpace($p)){ return }
  if(!(Test-Path $p)){ New-Item -ItemType Directory -Force -Path $p | Out-Null }
}

function Resolve-Abs([string]$p){
  if([string]::IsNullOrWhiteSpace($p)){ return $p }
  try { return (Resolve-Path $p).Path } catch { return [System.IO.Path]::GetFullPath($p) }
}

function Get-LatestDateInReports([string]$dir){
  if(!(Test-Path $dir)){ return "" }
  $files = Get-ChildItem $dir -File -Filter "market_snapshot_????-??-??.json" -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending
  if($files -and $files.Count -gt 0){
    $m = [regex]::Match($files[0].Name, '^market_snapshot_(\d{4}-\d{2}-\d{2})\.json$')
    if($m.Success){ return $m.Groups[1].Value }
  }
  return ""
}

function Try-ReplaceToken([string]$html,[string[]]$tokens,[string]$value){
  foreach($t in $tokens){
    if($html -like "*$t*"){ $html = $html.Replace($t, $value) }
  }
  return $html
}

# ---- normalize paths ----
$ReportsDir   = Resolve-Abs $ReportsDir
$TemplatePath = Resolve-Abs $TemplatePath
EnsureDir $ReportsDir

if($ListDates){
  Get-ChildItem $ReportsDir -File -Filter "market_snapshot_????-??-??.json" -ErrorAction SilentlyContinue |
    ForEach-Object {
      $m = [regex]::Match($_.Name, '^market_snapshot_(\d{4}-\d{2}-\d{2})\.json$')
      if($m.Success){ $m.Groups[1].Value }
    } | Sort-Object -Unique
  exit 0
}

if([string]::IsNullOrWhiteSpace($Date)){
  $Date = Get-LatestDateInReports $ReportsDir
}
if([string]::IsNullOrWhiteSpace($Date)){
  throw "No Date provided and cannot infer latest date from ReportsDir=$ReportsDir (need market_snapshot_YYYY-MM-DD.json)."
}

# ---- locate json inputs ----
$marketSnapshot = Join-Path $ReportsDir ("market_snapshot_{0}.json" -f $Date)
$sectorHeat     = Join-Path $ReportsDir ("sector_heat_{0}.json" -f $Date)
$regimeJson     = Join-Path $ReportsDir ("regime_{0}.json" -f $Date)
$decisionJson   = Join-Path $ReportsDir ("decision_{0}.json" -f $Date)
$allocationJson = Join-Path $ReportsDir ("allocation_{0}.json" -f $Date)

# ---- read template if exists, else fallback template ----
$html = ""
if(Test-Path $TemplatePath){
  $html = Get-Content $TemplatePath -Raw -Encoding UTF8
} else {
  $html = @"
<!doctype html>
<html><head><meta charset="utf-8"><title>Investment Dashboard</title></head>
<body><h1>Investment Dashboard</h1><div id="app"></div></body></html>
"@
}

# ---- replace basic tokens ----
$html2 = $html
$html2 = Try-ReplaceToken $html2 @("__DATE__","{{DATE}}","{{date}}") $Date
$html2 = Try-ReplaceToken $html2 @("__CAPITAL__","{{CAPITAL}}","{{capital}}") ("$Capital")
$html2 = Try-ReplaceToken $html2 @("__TOP__","{{TOP}}","{{top}}") ("$Top")

# ---- PS5.1 safe "exists ? abs : ''" ----
$msAbs = ""
if(Test-Path $marketSnapshot){ $msAbs = Resolve-Abs $marketSnapshot }

$shAbs = ""
if(Test-Path $sectorHeat){ $shAbs = Resolve-Abs $sectorHeat }

$rgAbs = ""
if(Test-Path $regimeJson){ $rgAbs = Resolve-Abs $regimeJson }

$dcAbs = ""
if(Test-Path $decisionJson){ $dcAbs = Resolve-Abs $decisionJson }

$alAbs = ""
if(Test-Path $allocationJson){ $alAbs = Resolve-Abs $allocationJson }

$html2 = Try-ReplaceToken $html2 @("__MARKET_SNAPSHOT_JSON__","{{MARKET_SNAPSHOT_JSON}}","{{market_snapshot_json}}") $msAbs
$html2 = Try-ReplaceToken $html2 @("__SECTOR_HEAT_JSON__","{{SECTOR_HEAT_JSON}}","{{sector_heat_json}}") $shAbs
$html2 = Try-ReplaceToken $html2 @("__REGIME_JSON__","{{REGIME_JSON}}","{{regime_json}}") $rgAbs
$html2 = Try-ReplaceToken $html2 @("__DECISION_JSON__","{{DECISION_JSON}}","{{decision_json}}") $dcAbs
$html2 = Try-ReplaceToken $html2 @("__ALLOCATION_JSON__","{{ALLOCATION_JSON}}","{{allocation_json}}") $alAbs

# ---- if template had no known placeholders, inject a minimal viewer ----
$hadKnownTokens = ($html -match "__MARKET_SNAPSHOT_JSON__|{{MARKET_SNAPSHOT_JSON}}|__SECTOR_HEAT_JSON__|{{SECTOR_HEAT_JSON}}|__REGIME_JSON__|__DECISION_JSON__|__ALLOCATION_JSON__")

$injectViewer = @"
<!-- injected viewer (BUILD_DASHBOARD_HTML_PS51_v1) -->
<script>
(function(){
  function el(tag, txt){ var e=document.createElement(tag); if(txt!==undefined){ e.textContent=txt; } return e; }
  var root = document.getElementById('app') || document.body;
  root.appendChild(el('h2','Data Pack (paths)'));
  var items = [
    ['market_snapshot', '$($msAbs -replace "\\","\\\\")'],
    ['sector_heat', '$($shAbs -replace "\\","\\\\")'],
    ['regime', '$($rgAbs -replace "\\","\\\\")'],
    ['decision', '$($dcAbs -replace "\\","\\\\")'],
    ['allocation', '$($alAbs -replace "\\","\\\\")']
  ];
  var ul = el('ul'); root.appendChild(ul);
  items.forEach(function(it){
    var li = el('li');
    li.appendChild(el('b', it[0] + ': '));
    li.appendChild(el('span', it[1] || '(missing)'));
    ul.appendChild(li);
  });
})();
</script>
"@

if(-not $hadKnownTokens){
  if($html2 -match "</body>"){
    $html2 = [regex]::Replace($html2, "</body>", ($injectViewer + "`r`n</body>"), 1)
  } else {
    $html2 = $html2 + "`r`n" + $injectViewer + "`r`n"
  }
}

# ---- write output ----
$outPath = Join-Path $ReportsDir ("dashboard_{0}.html" -f $Date)
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($outPath, $html2.Replace("`r`n","`n").Replace("`n","`r`n"), $utf8NoBom)

Write-Host ("OK: wrote HTML -> {0}" -f $outPath) -ForegroundColor Green
if($Open){ Start-Process $outPath | Out-Null }
exit 0