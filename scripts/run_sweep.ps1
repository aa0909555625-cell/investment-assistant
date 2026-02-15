Write-Host "=== Investment Assistant :: Phase ⑤ Strategy Sweep ==="

$PY = "python"
$MAIN = "src.main"
$OUT = "data/metrics_sweep.csv"

Remove-Item $OUT -ErrorAction SilentlyContinue

"strategy,params,return_pct,max_drawdown,trades,end_value" | Out-File $OUT -Encoding UTF8

function Run-MA-Sweep {
    for ($maShort = 1; $maShort -le 5; $maShort++) {
        for ($maLong = $maShort + 1; $maLong -le 30; $maLong++) {

            Write-Host "MA Sweep: short=$maShort long=$maLong"

            $result = & $PY -m $MAIN `
                --backtest `
                --strategy ma `
                --ma-short $maShort `
                --ma-long $maLong 2>$null

            if ($LASTEXITCODE -ne 0) { continue }

            $json = Get-Content data/metrics.json | ConvertFrom-Json

            "ma,""short=$maShort long=$maLong"",$($json.return_pct),$($json.max_drawdown),$($json.trades),$($json.end_value)" `
                | Add-Content $OUT
        }
    }
}

function Run-RSI-Sweep {
    foreach ($period in @(7,14,21)) {
        foreach ($os in @(20,30)) {
            foreach ($ob in @(70,80)) {

                Write-Host "RSI Sweep: period=$period os=$os ob=$ob"

                $result = & $PY -m $MAIN `
                    --backtest `
                    --strategy rsi `
                    --rsi-period $period `
                    --rsi-oversold $os `
                    --rsi-overbought $ob 2>$null

                if ($LASTEXITCODE -ne 0) { continue }

                $json = Get-Content data/metrics.json | ConvertFrom-Json

                "rsi,""period=$period os=$os ob=$ob"",$($json.return_pct),$($json.max_drawdown),$($json.trades),$($json.end_value)" `
                    | Add-Content $OUT
            }
        }
    }
}

Run-MA-Sweep
Run-RSI-Sweep

Write-Host "=== Phase ⑤ Sweep DONE ==="
