# Investment Assistant - Weekly SOP（上線版）

> 目的：你只要記得「跑 / 看 / 救 / 交付」四件事。
> 本 SOP 適用：Windows PowerShell（傳統黑框）+ 排程（Task Scheduler / schtasks）。

---

## 0) 平常只要記三條（最常用）

### 0-1) 跑 weekly（手動）
```powershell
Set-Location D:\projects\investment-assistant
.\run.ps1 weekly
"ExitCode=$LASTEXITCODE"
```

### 0-2) 看目前狀態（最新 summary / log）
```powershell
Set-Location D:\projects\investment-assistant
.\run.ps1 status
```

### 0-3) 產出驗收包（交付或自存）
```powershell
Set-Location D:\projects\investment-assistant
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\bundle_acceptance.ps1 -Tag "F"
```

---

## 1) 看（最新輸出，不用翻資料夾）
```powershell
Set-Location D:\projects\investment-assistant
$latestLog = Get-ChildItem .\logs\weekly -Filter "weekly_task_*.log" -ErrorAction SilentlyContinue |
  Sort-Object LastWriteTime -Desc | Select-Object -First 1
$latestSummary = Get-ChildItem .\reports\weekly -Filter "weekly_summary_*.txt" -ErrorAction SilentlyContinue |
  Sort-Object LastWriteTime -Desc | Select-Object -First 1
"LatestLog    : " + $(if($latestLog){$latestLog.FullName}else{"<none>"})
"LogTime      : " + $(if($latestLog){$latestLog.LastWriteTime}else{"<none>"})
"LatestSummary: " + $(if($latestSummary){$latestSummary.FullName}else{"<none>"})
"SummaryTime  : " + $(if($latestSummary){$latestSummary.LastWriteTime}else{"<none>"})
```

---

## 2) 看（排程狀態查核）

### 2-1) Weekly（每週一 09:10）
```powershell
Set-Location D:\projects\investment-assistant
$TaskName = "InvestmentAssistant_Weekly"
schtasks /Query /TN $TaskName /V /FO LIST |
  Select-String -Pattern "TaskName:|Status:|Next Run Time:|Last Run Time:|Last Result:" | Out-Host
```

### 2-2) OnLogon（登入就跑一次）
```powershell
Set-Location D:\projects\investment-assistant
$TaskName = "InvestmentAssistant_OnLogon"
schtasks /Query /TN $TaskName /V /FO LIST |
  Select-String -Pattern "TaskName:|Status:|Last Run Time:|Last Result:" | Out-Host
```

### 2-3) 兩個任務一起查（Weekly + OnLogon）
```powershell
Set-Location D:\projects\investment-assistant
$names = @("InvestmentAssistant_Weekly","InvestmentAssistant_OnLogon")
foreach($n in $names){
  "" | Out-Host
  schtasks /Query /TN $n /V /FO LIST |
    Select-String -Pattern "TaskName:|Status:|Next Run Time:|Last Run Time:|Last Result:" | Out-Host
}
```

---

## 3) 救（失敗時：ExitCode != 0 看 log）
```powershell
Set-Location D:\projects\investment-assistant
$latest = Get-ChildItem .\logs\weekly -Filter "weekly_task_*.log" -ErrorAction SilentlyContinue |
  Sort-Object LastWriteTime -Desc | Select-Object -First 1
$latest.FullName | Out-Host
Get-Content $latest.FullName -Tail 120 | Out-Host
```

---

## 4) 交付（驗收包內容在哪）
- 位置：reports\weekly\acceptance_<Tag>_<yyyyMMdd_HHmmss>\
- 內含：最新 weekly_summary_*.txt、weekly_task_*.log、last_success.json（若存在）與 archive 內的最後失敗快照（若存在）

---

## 5) 小提醒（避免卡住）
- 寫 Markdown 檔：建議用 $lines 陣列 + Set-Content（不要用 here-string 直接貼超長內容）
- 排程任務已驗證可跑：Last Result 應為 0，且 logs\weekly 會新增 weekly_task_*.log