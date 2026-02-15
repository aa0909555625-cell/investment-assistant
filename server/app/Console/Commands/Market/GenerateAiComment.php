<?php

namespace App\Console\Commands\Market;

use Illuminate\Console\Command;
use Illuminate\Support\Facades\DB;

class GenerateAiComment extends Command
{
    protected $signature = 'market:comment {date : YYYY-MM-DD}';
    protected $description = 'Generate v1 rule-based comments for Top20 and store into daily_reports.ai_comment';

    public function handle(): int
    {
        $date = (string)$this->argument('date');

        $report = DB::table('daily_reports')->where('date', $date)->first();
        if (!$report) {
            $this->error("Report not found for date={$date}. Run market:generate-daily-report first.");
            return self::FAILURE;
        }

        $top20 = json_decode((string)$report->top20, true) ?: [];
        if (count($top20) === 0) {
            $this->error("Top20 empty for date={$date}.");
            return self::FAILURE;
        }

        $lines = [];
        $lines[] = "Top20 文字解讀（v1｜規則型，基於單日資料）";
        $lines[] = "注意：目前僅用當日 OHLC/量能做相對排名，非投資建議。";
        $lines[] = "";

        $bucketTitle = [
            'trend' => '趨勢/動能',
            'stable' => '穩健/低波',
            'liquidity' => '成交量/流動性',
            'volatility' => '波動/事件',
        ];

        foreach ($top20 as $i => $it) {
            $symbol = $it['symbol'] ?? '';
            $name = $it['name'] ?? '';
            $bucket = $it['bucket'] ?? 'other';
            $score = (int)($it['score_total'] ?? 0);

            $sig = $it['signals'] ?? [];
            $liq = (int)($sig['liquidity'] ?? 0);
            $vol = (int)($sig['volatility'] ?? 0);
            $mom = (int)($sig['momentum'] ?? 0);

            $warn = $it['warnings'] ?? [];
            $warnText = count($warn) ? ('⚠ ' . implode('、', $warn)) : '（無額外警示）';

            $bt = $bucketTitle[$bucket] ?? $bucket;

            // 2–3 lines objective commentary
            $lines[] = sprintf("%02d) %s｜%s（%s｜總分 %d）", $i + 1, $symbol, $name, $bt, $score);
            $lines[] = "    指標：流動性 {$liq}｜波動 {$vol}｜動能 {$mom}";

            // Explain why it got into the bucket
            if ($bucket === 'trend') {
                $lines[] = "    解讀：動能相對突出（當日變動在全市場屬前段），但仍需留意量能/波動是否匹配。{$warnText}";
            } elseif ($bucket === 'stable') {
                $lines[] = "    解讀：波動相對較低、走勢較穩；若同時量能偏弱，容易出現流動性風險。{$warnText}";
            } elseif ($bucket === 'liquidity') {
                $lines[] = "    解讀：量能/成交金額相對強，適合做『可進可出』的觀察標的；仍需搭配波動與動能判斷。{$warnText}";
            } elseif ($bucket === 'volatility') {
                $lines[] = "    解讀：當日振幅相對大，屬事件/波動型標的；風險較高，需嚴格控位與停損。{$warnText}";
            } else {
                $lines[] = "    解讀：分類未命中主要桶，但在綜合分數上仍達到前段。{$warnText}";
            }

            $lines[] = "";
        }

        $text = implode("\n", $lines);

        DB::table('daily_reports')->where('date', $date)->update([
            'ai_comment' => $text,
            'updated_at' => now(),
        ]);

        $this->info("Done. ai_comment updated for date={$date} (lines=" . count($lines) . ")");
        return self::SUCCESS;
    }
}