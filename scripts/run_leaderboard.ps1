Write-Host "=== Investment Assistant :: Phase ⑥ Leaderboard ==="

$IN  = "data/metrics_sweep.csv"

if (-not (Test-Path $IN)) {
    Write-Host "❌ Missing: $IN"
    exit 1
}

$rows = Import-Csv $IN

# 強制把數字欄位轉成 double/int，避免字串排序
$rows = $rows | ForEach-Object {
    $_.return_pct   = [double]$_.return_pct
    $_.max_drawdown = [double]$_.max_drawdown
    $_.trades       = [int]$_.trades
    $_.end_value    = [double]$_.end_value
    $_
}

# 避免「0 trades」干擾排行（你也可以改成保留）
$rows_traded = $rows | Where-Object { $_.trades -gt 0 }

function Export-Board($data, $path, $columns) {
    $dir = Split-Path $path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    if ($null -eq $data -or @($data).Count -eq 0) {
        # 輸出空檔但保留 header
        "" | Select-Object $columns | Export-Csv $path -NoTypeInformation -Encoding UTF8
        Write-Host "⚠ No rows -> wrote empty board: $path"
        return
    }

    $data | Select-Object $columns | Export-Csv $path -NoTypeInformation -Encoding UTF8
    Write-Host "✔ Wrote $path"
}

$cols = @("strategy","params","return_pct","max_drawdown","trades","end_value")

# 1) ALL
Export-Board ($rows_traded | Sort-Object return_pct -Descending) "data/leaderboard_all_by_return.csv" $cols
Export-Board ($rows_traded | Sort-Object max_drawdown, return_pct -Descending) "data/leaderboard_all_by_dd.csv" $cols

# 2) MA / RSI
$ma  = $rows_traded | Where-Object { $_.strategy -eq "ma" }
$rsi = $rows_traded | Where-Object { $_.strategy -eq "rsi" }

Export-Board ($ma  | Sort-Object return_pct -Descending) "data/leaderboard_ma_by_return.csv" $cols
Export-Board ($rsi | Sort-Object return_pct -Descending) "data/leaderboard_rsi_by_return.csv" $cols

Export-Board ($ma  | Sort-Object max_drawdown, return_pct -Descending) "data/leaderboard_ma_by_dd.csv" $cols
Export-Board ($rsi | Sort-Object max_drawdown, return_pct -Descending) "data/leaderboard_rsi_by_dd.csv" $cols

Write-Host "`n=== TOP 10 (ALL by return) ==="
$rows_traded | Sort-Object return_pct -Descending | Select-Object -First 10 $cols | Format-Table -AutoSize

Write-Host "`n=== Phase ⑥ DONE ==="
