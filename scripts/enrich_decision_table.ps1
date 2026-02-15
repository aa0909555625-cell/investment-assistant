param(
  [Parameter(Mandatory=$true)][string]$Date,
  [string]$InPath = ".\data\all_stocks_daily.csv",
  [string]$OutPath = ".\data\all_stocks_decisions.csv",
  [string]$IndexPath = ".\data\index_daily.csv",
  [string]$LedgerPath = ".\data\ledger_trades.csv",
  [double]$VolatilityMax = 0.25,
  [int]$CooldownDays = 7
)

function To-Scalar($v) {
  if ($null -eq $v) { return $null }
  if ($v -is [System.Array]) {
    if ($v.Length -gt 0) { return $v[0] }
    return $null
  }
  return $v
}

function To-Num($v, $default=$null) {
  $v = To-Scalar $v
  if ($null -eq $v) { return $default }
  $s = "$v".Trim()
  if ($s -eq "") { return $default }

  $n = 0.0
  $styles = [System.Globalization.NumberStyles]::Float
  $ci = [System.Globalization.CultureInfo]::InvariantCulture

  if ([double]::TryParse($s, $styles, $ci, [ref]$n)) { return [double]$n }
  if ([double]::TryParse($s, [ref]$n)) { return [double]$n }

  # try replace comma decimal -> dot
  $s2 = $s.Replace(",", ".")
  if ([double]::TryParse($s2, $styles, $ci, [ref]$n)) { return [double]$n }

  return $default
}

function Clamp($x, $lo, $hi) {
  $x = To-Num $x $lo
  if ($x -lt $lo) { return $lo }
  if ($x -gt $hi) { return $hi }
  return $x
}

function Norm01or100($x) {
  $x = To-Num $x $null
  if ($null -eq $x) { return $null }
  if ($x -le 1.0 -and $x -ge 0.0) { return $x * 100.0 }
  return $x
}

function NormVol($v) {
  $v = To-Num $v 0.0
  if ($v -gt 1.0) { return $v / 100.0 } # 18 => 0.18
  return $v
}

if (!(Test-Path $InPath)) { throw "Missing input: $InPath" }
$rows = Import-Csv $InPath
if ($rows.Count -eq 0) { throw "Empty input: $InPath" }

# ---- Market Gate (proxy) ----
$allowNew = $true
$marketRisk = "normal"
$indexChange = $null
if (Test-Path $IndexPath) {
  $idx = Import-Csv $IndexPath | Where-Object { $_.date -eq $Date } | Select-Object -First 1
  if ($idx) {
    $indexChange = if ($idx.change_percent) { To-Num $idx.change_percent $null } elseif ($idx.pct) { To-Num $idx.pct $null } else { $null }
    if ($null -ne $indexChange) {
      if ($indexChange -le -1.5) { $allowNew = $false; $marketRisk = "high" }
      elseif ($indexChange -le -0.8) { $allowNew = $true; $marketRisk = "caution" }
      else { $allowNew = $true; $marketRisk = "normal" }
    }
  }
}

# ---- Cooldown map from ledger (stoploss only) ----
$cooldownMap = @{}
if (Test-Path $LedgerPath) {
  $ledger = Import-Csv $LedgerPath
  foreach ($t in $ledger) {
    if ($t.code -and $t.exit_reason -and $t.exit_date) {
      if ($t.exit_reason -match "stop" -or $t.exit_reason -match "sl") {
        $cooldownMap[$t.code] = $t.exit_date
      }
    }
  }
}

$hasClose = $rows[0].PSObject.Properties.Name -contains "close"

$out = foreach ($r in $rows) {
  $code = $r.code
  $name = $r.name
  $sector = $r.sector

  $chg = To-Num $r.change_percent 0.0
  $liq_raw = Norm01or100 $r.liquidity
  $mom_raw = Norm01or100 $r.momentum
  $vol = NormVol $r.volatility

  $warnings = "$($r.warnings)".Trim()

  # ---- factor scores ----
  $score_trend = Clamp (50.0 + ($chg * 6.0)) 0.0 100.0
  $score_momo  = if ($null -ne $mom_raw) { Clamp $mom_raw 0.0 100.0 } else { Clamp (50.0 + ($chg * 8.0)) 0.0 100.0 }
  $score_volume = if ($null -ne $liq_raw) { Clamp $liq_raw 0.0 100.0 } else { 55.0 }
  $score_position = Clamp (100.0 - ([math]::Abs($chg) * 8.0)) 0.0 100.0

  $riskPenalty = 0.0
  if ($warnings) { $riskPenalty += 12.0 }
  if ($vol -ge 0.25) { $riskPenalty += 22.0 }
  elseif ($vol -ge 0.18) { $riskPenalty += 14.0 }
  elseif ($vol -ge 0.12) { $riskPenalty += 8.0 }
  elseif ($vol -ge 0.08) { $riskPenalty += 4.0 }
  $score_risk_penalty = Clamp $riskPenalty 0.0 40.0

  # ---- total score (compute if missing) ----
  $total_raw = To-Num $r.total_score $null
  $total = if ($null -ne $total_raw) {
    Clamp $total_raw 0.0 100.0
  } else {
    $calc = (0.30*$score_trend) + (0.25*$score_momo) + (0.15*$score_position) + (0.15*$score_volume) + (0.15*(100.0-$score_risk_penalty))
    Clamp ([math]::Round($calc,2)) 0.0 100.0
  }

  # ---- gates ----
  $gate_market = $allowNew
  $gate_volatility = ($vol -le $VolatilityMax)

  $hits = 0
  if ($score_trend -ge 70.0) { $hits++ }
  if ($score_momo  -ge 70.0) { $hits++ }
  if ($score_volume -ge 70.0) { $hits++ }
  $gate_consensus = ($hits -ge 2)

  $gate_cooldown = $true
  if ($cooldownMap.ContainsKey($code)) {
    $last = $cooldownMap[$code]
    try {
      $d0 = [datetime]::ParseExact($last, "yyyy-MM-dd", $null)
      $d1 = [datetime]::ParseExact($Date, "yyyy-MM-dd", $null)
      $days = ($d1 - $d0).Days
      if ($days -lt $CooldownDays) { $gate_cooldown = $false }
    } catch { }
  }

  $gate_final = ($gate_market -and $gate_volatility -and $gate_consensus -and $gate_cooldown)

  $action = "NO-TRADE"
  if ($total -ge 80.0 -and $gate_final) { $action = "READY" }
  elseif ($total -ge 70.0 -and $gate_market -and $gate_volatility -and $gate_cooldown) { $action = "OBSERVE" }

  $close = $null
  if ($hasClose) { $close = To-Num $r.close $null }

  $entry_low = ""
  $entry_high = ""
  $stop_price = ""
  if ($null -ne $close -and $close -gt 0) {
    $band = if ($action -eq "READY") { 0.006 } else { 0.010 }
    $entry_low  = [math]::Round($close * (1 - $band), 2)
    $entry_high = [math]::Round($close * (1 + $band), 2)
    $sl = [math]::Max(0.035, ($vol * 0.65))
    $stop_price = [math]::Round($close * (1 - $sl), 2)
  } else {
    if ($warnings) { $warnings = "$warnings|no_price" } else { $warnings = "no_price" }
  }

  $risk_tag = ""
  if ($warnings -match "no_price") { $risk_tag = "DATA_NO_PRICE" }
  elseif (!$gate_market) { $risk_tag = "MKT_RISK_$marketRisk" }
  elseif (!$gate_volatility) { $risk_tag = "VOL_TOO_HIGH" }
  elseif (!$gate_consensus) { $risk_tag = "NO_CONSENSUS" }
  elseif (!$gate_cooldown) { $risk_tag = "COOLDOWN" }
  elseif ($warnings) { $risk_tag = "DATA_WARN" }
  else { $risk_tag = "OK" }

  $reason = "trend=$([math]::Round($score_trend,1)) momo=$([math]::Round($score_momo,1)) volProxy=$([math]::Round($score_volume,1)) pos=$([math]::Round($score_position,1)) riskPenalty=$([math]::Round($score_risk_penalty,1)) gates(mkt=$gate_market,cons=$gate_consensus,cd=$gate_cooldown,vol=$gate_volatility)"

  [pscustomobject]@{
    date = $r.date
    code = $code
    name = $name
    sector = $sector
    change_percent = $chg
    total_score = $total
    liquidity = if ($null -ne $liq_raw) { $liq_raw } else { "" }
    volatility = [math]::Round($vol,4)
    momentum = if ($null -ne $mom_raw) { $mom_raw } else { "" }
    warnings = $warnings

    action = $action
    entry_low = $entry_low
    entry_high = $entry_high
    stop_price = $stop_price
    risk_tag = $risk_tag

    score_trend = [math]::Round($score_trend,2)
    score_momo  = [math]::Round($score_momo,2)
    score_position = [math]::Round($score_position,2)
    score_volume = [math]::Round($score_volume,2)
    score_risk_penalty = [math]::Round($score_risk_penalty,2)

    gate_market = $gate_market
    gate_consensus = $gate_consensus
    gate_cooldown = $gate_cooldown
    gate_volatility = $gate_volatility
    gate_final = $gate_final

    reason = $reason
    market_risk = $marketRisk
    market_index_change = $indexChange
  }
}

$out | Export-Csv $OutPath -NoTypeInformation -Encoding UTF8
Write-Host "OK: wrote -> $OutPath (rows=$($out.Count))" -ForegroundColor Green
Write-Host "MarketGate allowNew=$allowNew risk=$marketRisk idxChange=$indexChange" -ForegroundColor DarkGray