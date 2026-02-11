[CmdletBinding()]
param(
  [int]$LookbackWeeks = 12,
  [switch]$SkipGapCheck,
  [switch]$SkipMdCheck,
  [int]$BootstrapMinSummaries = 2
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# --- 路徑定位（以此檔案所在資料夾為準） ---
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir   = Split-Path -Parent $ScriptDir

# --- 統一編碼（避免亂碼/截斷） ---
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch {}
try { $OutputEncoding          = [System.Text.UTF8Encoding]::new($false) } catch {}
try { & chcp 65001 | Out-Null } catch {}

# --- 目錄：logs / reports ---
$LogDir     = Join-Path $RootDir 'logs\weekly'
$ReportDir  = Join-Path $RootDir 'reports\weekly'
New-Item -ItemType Directory -Force -Path $LogDir, $ReportDir | Out-Null

# --- 檔名：log + summary ---
$NowStamp   = Get-Date -Format 'yyyyMMdd_HHmmss'
$LogPath    = Join-Path $LogDir ("weekly_task_{0}.log" -f $NowStamp)

function Get-IsoWeekInfo([datetime]$dt) {
  $cal = [System.Globalization.CultureInfo]::InvariantCulture.Calendar
  $weekRule = [System.Globalization.CalendarWeekRule]::FirstFourDayWeek
  $firstDay = [System.DayOfWeek]::Monday
  $week = $cal.GetWeekOfYear($dt, $weekRule, $firstDay)

  # ISO Year：用該週週四判定年度
  $thursday = $dt.AddDays(3 - (([int]$dt.DayOfWeek + 6) % 7))
  $isoYear = $thursday.Year

  [pscustomobject]@{ IsoYear = $isoYear; IsoWeek = $week }
}

$iso = Get-IsoWeekInfo (Get-Date)
$SummaryPath = Join-Path $ReportDir ("weekly_summary_{0}-{1:D2}.txt" -f $iso.IsoYear, $iso.IsoWeek)

# --- 統一 log 輸出（同時寫到 console + 檔案，UTF-8） ---
$script:LogLock = New-Object object
function Write-Log {
  param(
    [Parameter(Mandatory=$true)][string]$Message,
    [ValidateSet('INFO','WARN','ERROR','STEP')][string]$Level = 'INFO'
  )
  $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  $line = "[{0}] [{1}] {2}" -f $ts, $Level, $Message

  if ($Level -eq 'ERROR') {
    Write-Host $line -ForegroundColor Red
  } elseif ($Level -eq 'WARN') {
    Write-Host $line -ForegroundColor Yellow
  } elseif ($Level -eq 'STEP') {
    Write-Host $line -ForegroundColor Cyan
  } else {
    Write-Host $line
  }

  [System.Threading.Monitor]::Enter($script:LogLock)
  try {
    $line | Out-File -FilePath $LogPath -Append -Encoding utf8
  } finally {
    [System.Threading.Monitor]::Exit($script:LogLock)
  }
}

function Append-SummaryLine([string]$text) {
  $text | Out-File -FilePath $SummaryPath -Append -Encoding utf8
}

function Run-Step {
  param(
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$true)][scriptblock]$Action
  )
  Write-Log "==> $Name" 'STEP'
  try {
    & $Action
    Write-Log "<== OK: $Name" 'INFO'
    return $true
  } catch {
    Write-Log "<== FAIL: $Name | $($_.Exception.Message)" 'ERROR'
    if ($_.ScriptStackTrace) { Write-Log "Stack: $($_.ScriptStackTrace)" 'ERROR' }
    return $false
  }
}

function Invoke-Exe {
  param(
    [Parameter(Mandatory=$true)][string]$FilePath,
    [string[]]$ArgumentList = @(),
    [string]$WorkingDirectory = $RootDir,
    [switch]$AllowWarnExit2
  )

  $argText = ($ArgumentList -join ' ')
  Write-Log ("CMD: {0} {1}" -f $FilePath, $argText) 'INFO'

  $p = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -WorkingDirectory $WorkingDirectory -NoNewWindow -Wait -PassThru
  $code = [int]$p.ExitCode

  if ($code -eq 0) { return 0 }

  if ($AllowWarnExit2 -and $code -eq 2) {
    Write-Log ("(WARN) ExitCode=2 allowed for this step: {0}" -f $FilePath) 'WARN'
    return 2
  }

  throw "ExitCode=$code"
}

# --- ISO / Gap helpers ---
function Get-IsoWeekKey([int]$y,[int]$w) { "{0}-{1:D2}" -f $y, $w }

function Add-WeeksIso([int]$y,[int]$w,[int]$delta) {
  # 用「該 ISO week 的週一」作基準，安全跨年
  $jan4 = Get-Date -Year $y -Month 1 -Day 4
  $dow = (([int]$jan4.DayOfWeek + 6) % 7) # Mon=0..Sun=6
  $week1Mon = $jan4.AddDays(-$dow)
  $targetMon = $week1Mon.AddDays(7*($w-1 + $delta))
  $info = Get-IsoWeekInfo $targetMon
  return [pscustomobject]@{ IsoYear=$info.IsoYear; IsoWeek=$info.IsoWeek }
}

function Get-LogTail([string]$path, [int]$lines = 60) {
  try {
    if (Test-Path -LiteralPath $path) {
      return @(Get-Content -LiteralPath $path -Tail $lines -ErrorAction SilentlyContinue)
    }
  } catch {}
  return @()
}

function Write-JsonFile([string]$path, [object]$obj) {
  $dir = Split-Path -Parent $path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }
  ($obj | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $path -Encoding utf8 -NoNewline
}

# --- summary header ---
"=== Weekly Task Summary ===" | Out-File -FilePath $SummaryPath -Encoding utf8
Append-SummaryLine ("GeneratedAt: {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Append-SummaryLine ("IsoWeek: {0}-{1:D2}" -f $iso.IsoYear, $iso.IsoWeek)
Append-SummaryLine ("RootDir: {0}" -f $RootDir)
Append-SummaryLine ("SummaryPath: {0}" -f $SummaryPath)
Append-SummaryLine ("LogPath: {0}" -f $LogPath)
Append-SummaryLine ""

# --- 主流程狀態（IMPORTANT: 用 script scope，summary 與 ExitCode 一致） ---
$script:exitCode   = 0
$script:warnings   = New-Object System.Collections.Generic.List[string]
$script:failedSteps= New-Object System.Collections.Generic.List[string]

function Set-Warn([string]$msg) {
  $script:warnings.Add($msg) | Out-Null
  if ($script:exitCode -eq 0) { $script:exitCode = 2 }
}

function Set-Fail([string]$stepName) {
  $script:failedSteps.Add($stepName) | Out-Null
  $script:exitCode = 1
}

Write-Log "Weekly task start. RootDir=$RootDir" 'INFO'
Write-Log "LogPath=$LogPath" 'INFO'
Write-Log "SummaryPath=$SummaryPath" 'INFO'

# --- Step: (TEST) Force fail via env ---
$ok = Run-Step -Name 'Guard: optional IA_FORCE_FAIL' -Action {
  if ($env:IA_FORCE_FAIL -eq '1') {
    throw "IA_FORCE_FAIL=1 (intentional failure for verification)"
  }
  Append-SummaryLine "ForceFailGuard: OK"
}
if (-not $ok) { Set-Fail 'Guard: optional IA_FORCE_FAIL' }

# --- Step: HealthCheck (list repo root) ---
$ok = Run-Step -Name 'HealthCheck: list repo root' -Action {
  Get-ChildItem -LiteralPath $RootDir -Force | Select-Object -First 12 | ForEach-Object {
    Write-Log ("RootItem: {0}" -f $_.Name) 'INFO'
  }
  Append-SummaryLine "HealthCheck: OK (listed root items)"
}
if (-not $ok) { Set-Fail 'HealthCheck: list repo root' }

# --- Step: Python ensure venv (.venv) ---
$venvPy = Join-Path $RootDir '.venv\Scripts\python.exe'
$ok = Run-Step -Name 'Python: ensure venv (.venv)' -Action {
  if (-not (Test-Path -LiteralPath $venvPy)) {
    throw "Venv python not found: $venvPy"
  }
  Write-Log "Venv OK: $venvPy" 'INFO'
  Append-SummaryLine ("PythonVenv: OK ({0})" -f $venvPy)
}
if (-not $ok) { Set-Fail 'Python: ensure venv (.venv)' }

# --- Step: pip install (requirements.txt if exists) ---
$req = Join-Path $RootDir 'requirements.txt'
$ok = Run-Step -Name 'Python: pip install (requirements.txt if exists)' -Action {
  if (-not (Test-Path -LiteralPath $req)) {
    Write-Log "requirements.txt not found; skip pip install" 'WARN'
    Append-SummaryLine "PipInstall: SKIPPED (no requirements.txt)"
    return
  }
  $pip = @('-m','pip','install','-r',$req)
  Invoke-Exe -FilePath $venvPy -ArgumentList $pip -WorkingDirectory $RootDir | Out-Null
  Append-SummaryLine "PipInstall: OK"
}
if (-not $ok) { Set-Fail 'Python: pip install (requirements.txt if exists)' }

# --- Step: pytest (if installed) ---
$ok = Run-Step -Name 'Python: pytest (if installed)' -Action {
  $pytestExe = Join-Path $RootDir '.venv\Scripts\pytest.exe'
  if (-not (Test-Path -LiteralPath $pytestExe)) {
    Write-Log "pytest not installed (pytest.exe not found); skip" 'INFO'
    Append-SummaryLine "Pytest: SKIPPED (pytest not installed)"
    return
  }
  Invoke-Exe -FilePath $pytestExe -ArgumentList @('-q') -WorkingDirectory $RootDir | Out-Null
  Append-SummaryLine "Pytest: OK"
}
if (-not $ok) { Set-Fail 'Python: pytest (if installed)' }

# --- Step: markdown check (_check_md.py if exists) ---
$mdCheckPy = Join-Path $RootDir '_check_md.py'
$ok = Run-Step -Name 'Python: markdown check (_check_md.py if exists)' -Action {
  if ($SkipMdCheck) {
    Write-Log "MdCheck skipped by flag." 'WARN'
    Append-SummaryLine "MdCheck: SKIPPED (-SkipMdCheck)"
    return
  }
  if (-not (Test-Path -LiteralPath $mdCheckPy)) {
    Write-Log "_check_md.py not found; skip" 'WARN'
    Append-SummaryLine "MdCheck: SKIPPED (_check_md.py not found)"
    return
  }
  $code = Invoke-Exe -FilePath $venvPy -ArgumentList @($mdCheckPy) -WorkingDirectory $RootDir -AllowWarnExit2
  if ($code -eq 2) {
    Write-Log "MdCheck returned WARN (ExitCode=2)" 'WARN'
    Append-SummaryLine "MdCheck: WARN (ExitCode=2)"
    Set-Warn "MdCheck: WARN (ExitCode=2)"
    return
  }
  Append-SummaryLine "MdCheck: OK"
}
if (-not $ok) { Set-Fail 'Python: markdown check (_check_md.py if exists)' }

# --- Step: Data snapshot & validate (data/*.csv) ---
function Get-CsvMeta([string]$filePath) {
  $fi = Get-Item -LiteralPath $filePath -ErrorAction Stop
  $lineCount = 0
  try {
    $lineCount = (Get-Content -LiteralPath $filePath -ErrorAction Stop | Measure-Object -Line).Lines
  } catch {
    $lineCount = -1
  }

  $lastDate = $null
  try {
    $head = (Get-Content -LiteralPath $filePath -TotalCount 1 -ErrorAction Stop)
    if ($head) {
      $headers = $head.Split(',') | ForEach-Object { $_.Trim().Trim('"') }
      $dateIdx = -1
      for ($i=0; $i -lt $headers.Count; $i++) {
        if ($headers[$i].ToLowerInvariant() -eq 'date') { $dateIdx = $i; break }
      }

      if ($dateIdx -ge 0) {
        $tail = Get-Content -LiteralPath $filePath -Tail 50 -ErrorAction Stop
        $lastLine = $tail | Where-Object { $_ -and ($_ -notmatch '^\s*$') -and ($_ -notmatch '^\s*date\s*,') } | Select-Object -Last 1
        if ($lastLine) {
          $cols = $lastLine.Split(',')
          if ($cols.Count -gt $dateIdx) {
            $lastDate = $cols[$dateIdx].Trim().Trim('"')
          }
        }
      }
    }
  } catch {
    $lastDate = $null
  }

  [pscustomobject]@{
    FullName = $fi.FullName
    LastWriteTime = $fi.LastWriteTime
    Lines = $lineCount
    LastDate = $lastDate
  }
}

$ok = Run-Step -Name 'Data: snapshot & validate (data/*.csv)' -Action {
  $DataDir = Join-Path $RootDir 'data'
  if (-not (Test-Path -LiteralPath $DataDir)) {
    throw "Data dir not found: $DataDir"
  }

  $required = @(
    (Join-Path $DataDir '2330.csv'),
    (Join-Path $DataDir '0050.csv')
  )

  $optional = @(
    (Join-Path $DataDir 'phase5_signals_2330.csv'),
    (Join-Path $DataDir 'phase5_signals_0050.csv'),
    (Join-Path $DataDir 'metrics_sweep.csv')
  )

  $missingRequired = @()
  foreach ($p in $required) { if (-not (Test-Path -LiteralPath $p)) { $missingRequired += $p } }

  if ($missingRequired.Count -gt 0) {
    Append-SummaryLine ""
    Append-SummaryLine ("DataSnapshot: FAIL (missing required {0})" -f $missingRequired.Count)
    foreach ($m in $missingRequired) { Append-SummaryLine ("MissingRequired: {0}" -f $m) }
    throw ("Missing required data file(s): {0}" -f ($missingRequired -join ', '))
  }

  $missingOptional = @()
  foreach ($p in $optional) { if (-not (Test-Path -LiteralPath $p)) { $missingOptional += $p } }

  $phase6Equity = Get-ChildItem -LiteralPath $DataDir -Filter 'phase6_equity_*.csv'  -File -ErrorAction SilentlyContinue
  $phase6Trades = Get-ChildItem -LiteralPath $DataDir -Filter 'phase6_trades_*.csv'  -File -ErrorAction SilentlyContinue

  Append-SummaryLine ""
  Append-SummaryLine "=== Data Snapshot ==="

  foreach ($p in $required) {
    $m = Get-CsvMeta $p
    Append-SummaryLine ("CSV: {0}" -f $m.FullName)
    Append-SummaryLine ("  Lines: {0}" -f $m.Lines)
    Append-SummaryLine ("  LastWrite: {0}" -f $m.LastWriteTime)
    if ($m.LastDate) { Append-SummaryLine ("  LastDate: {0}" -f $m.LastDate) }
  }

  foreach ($p in $optional) {
    if (Test-Path -LiteralPath $p) {
      $m = Get-CsvMeta $p
      Append-SummaryLine ("CSV: {0}" -f $m.FullName)
      Append-SummaryLine ("  Lines: {0}" -f $m.Lines)
      Append-SummaryLine ("  LastWrite: {0}" -f $m.LastWriteTime)
      if ($m.LastDate) { Append-SummaryLine ("  LastDate: {0}" -f $m.LastDate) }
    }
  }

  Append-SummaryLine ("Phase6EquityCount: {0}" -f ($phase6Equity | Measure-Object).Count)
  foreach ($f in ($phase6Equity | Sort-Object Name)) {
    $m = Get-CsvMeta $f.FullName
    $extra = ""
    if ($m.LastDate) { $extra = " | LastDate=$($m.LastDate)" }
    Append-SummaryLine ("  Equity: {0} | Lines={1} | LastWrite={2}{3}" -f $f.Name, $m.Lines, $m.LastWriteTime, $extra)
  }

  Append-SummaryLine ("Phase6TradesCount: {0}" -f ($phase6Trades | Measure-Object).Count)
  foreach ($f in ($phase6Trades | Sort-Object Name)) {
    $m = Get-CsvMeta $f.FullName
    $extra = ""
    if ($m.LastDate) { $extra = " | LastDate=$($m.LastDate)" }
    Append-SummaryLine ("  Trades: {0} | Lines={1} | LastWrite={2}{3}" -f $f.Name, $m.Lines, $m.LastWriteTime, $extra)
  }

  if ($missingOptional.Count -gt 0) {
    Write-Log ("DataSnapshot: missing optional {0} file(s)" -f $missingOptional.Count) 'WARN'
    Append-SummaryLine ("MissingOptionalCount: {0}" -f $missingOptional.Count)
    foreach ($m in $missingOptional) { Append-SummaryLine ("MissingOptional: {0}" -f $m) }
    Set-Warn ("DataSnapshot: missing optional {0} file(s)" -f $missingOptional.Count)
  } else {
    Append-SummaryLine "MissingOptionalCount: 0"
  }

  if (($phase6Equity | Measure-Object).Count -eq 0) {
    Write-Log "DataSnapshot: no phase6_equity_*.csv found" 'WARN'
    Append-SummaryLine "Phase6Equity: WARN (none found)"
    Set-Warn "DataSnapshot: Phase6Equity none found"
  }
  if (($phase6Trades | Measure-Object).Count -eq 0) {
    Write-Log "DataSnapshot: no phase6_trades_*.csv found" 'WARN'
    Append-SummaryLine "Phase6Trades: WARN (none found)"
    Set-Warn "DataSnapshot: Phase6Trades none found"
  }

  Append-SummaryLine "DataSnapshot: OK"
}
if (-not $ok) { Set-Fail 'Data: snapshot & validate (data/*.csv)' }

# --- Bootstrap Mode 判定 ---
$summaryCount = 0
try {
  $summaryCount = (Get-ChildItem -LiteralPath $ReportDir -Filter 'weekly_summary_*.txt' -File -ErrorAction SilentlyContinue | Measure-Object).Count
} catch { $summaryCount = 0 }

$bootstrapOn = ($summaryCount -lt $BootstrapMinSummaries)
Append-SummaryLine ""
if ($bootstrapOn) {
  Write-Log ("BootstrapMode ON: summaryCount={0} < BootstrapMinSummaries={1} (gap will not set ExitCode=2)" -f $summaryCount, $BootstrapMinSummaries) 'WARN'
  Append-SummaryLine ("BootstrapMode: ON (summaryCount={0}, min={1})" -f $summaryCount, $BootstrapMinSummaries)
} else {
  Append-SummaryLine ("BootstrapMode: OFF (summaryCount={0}, min={1})" -f $summaryCount, $BootstrapMinSummaries)
}

# --- GapCheck ---
if (-not $SkipGapCheck) {
  Write-Log "GapCheck start (LookbackWeeks=$LookbackWeeks)..." 'INFO'

  $existing = @{}
  Get-ChildItem -LiteralPath $ReportDir -Filter 'weekly_summary_*.txt' -File -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_.BaseName -match '^weekly_summary_(\d{4})-(\d{2})$') {
      $key = "{0}-{1}" -f $matches[1], $matches[2]
      $existing[$key] = $_.FullName
    }
  }

  $needKeys = New-Object System.Collections.Generic.List[string]
  for ($i=0; $i -lt $LookbackWeeks; $i++) {
    $x = Add-WeeksIso -y $iso.IsoYear -w $iso.IsoWeek -delta (-$i)
    $needKeys.Add((Get-IsoWeekKey $x.IsoYear $x.IsoWeek)) | Out-Null
  }

  $gapsFound = @()
  foreach ($k in $needKeys) {
    if (-not $existing.ContainsKey($k)) { $gapsFound += $k }
  }

  Append-SummaryLine ""
  if ($gapsFound.Count -gt 0) {
    Write-Log ("GapCheck: MISSING {0} week(s): {1}" -f $gapsFound.Count, ($gapsFound -join ', ')) 'WARN'
    Append-SummaryLine ("GapCheck: MISSING {0} week(s)" -f $gapsFound.Count)
    Append-SummaryLine ("MissingWeeks: {0}" -f ($gapsFound -join ', '))

    if (-not $bootstrapOn) {
      Set-Warn ("GapCheck: missing {0} week(s)" -f $gapsFound.Count)
    } else {
      Append-SummaryLine "GapCheck: BootstrapMode -> ExitState not elevated"
    }
  } else {
    Write-Log "GapCheck: OK (no missing weeks within lookback window)" 'INFO'
    Append-SummaryLine "GapCheck: OK"
  }
} else {
  Write-Log "GapCheck skipped." 'WARN'
  Append-SummaryLine ""
  Append-SummaryLine "GapCheck: SKIPPED (-SkipGapCheck)"
}

# --- 結尾：摘要 & exit code ---
Append-SummaryLine ""
Append-SummaryLine ("WarningsCount: {0}" -f $script:warnings.Count)
if ($script:warnings.Count -gt 0) {
  Append-SummaryLine ("Warnings: {0}" -f ($script:warnings -join ' | '))
}

Append-SummaryLine ("FailedStepsCount: {0}" -f $script:failedSteps.Count)
if ($script:failedSteps.Count -gt 0) {
  Append-SummaryLine ("FailedSteps: {0}" -f ($script:failedSteps -join ' | '))
}

Append-SummaryLine ("ExitCode: {0}" -f $script:exitCode)

Write-Log "Weekly task done. ExitCode=$($script:exitCode)" 'INFO'
Write-Log "SummaryPath=$SummaryPath" 'INFO'
Write-Log "LogPath=$LogPath" 'INFO'

# --- Write last_success / last_failure ---
$successPath = Join-Path $ReportDir 'last_success.json'
$failurePath = Join-Path $ReportDir 'last_failure.json'

$baseSnapshot = [ordered]@{
  generatedAt      = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  isoWeek          = ('{0}-{1:D2}' -f $iso.IsoYear, $iso.IsoWeek)
  exitCode         = [int]$script:exitCode
  repo             = (Resolve-Path $RootDir).Path
  summaryPath      = (Resolve-Path $SummaryPath).Path
  logPath          = (Resolve-Path $LogPath).Path
  warningsCount    = [int]$script:warnings.Count
  warnings         = @($script:warnings)
  failedStepsCount = [int]$script:failedSteps.Count
  failedSteps      = @($script:failedSteps)
}

if ($script:exitCode -eq 0 -or $script:exitCode -eq 2) {
  Write-JsonFile -path $successPath -obj $baseSnapshot
} else {
  $fail = [ordered]@{}
  foreach ($k in $baseSnapshot.Keys) { $fail[$k] = $baseSnapshot[$k] }
  $fail['logTail'] = @(Get-LogTail -path $LogPath -lines 80)
  Write-JsonFile -path $failurePath -obj $fail
}

exit $script:exitCode