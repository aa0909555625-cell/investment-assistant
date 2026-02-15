<?php

namespace App\Console\Commands\Market;

use Illuminate\Console\Command;
use Illuminate\Support\Facades\DB;

class GenerateDailyReport extends Command
{
    protected $signature = 'market:generate-daily-report {date : YYYY-MM-DD}';
    protected $description = 'Generate v1 daily scores + mixed Top20 + daily report snapshot';

    public function handle(): int
    {
        $date = (string)$this->argument('date');

        $bars = DB::table('daily_bars')
            ->join('stocks', 'stocks.id', '=', 'daily_bars.stock_id')
            ->select([
                'daily_bars.stock_id',
                'daily_bars.date',
                'daily_bars.open',
                'daily_bars.high',
                'daily_bars.low',
                'daily_bars.close',
                'daily_bars.volume',
                'daily_bars.turnover',
                'daily_bars.change',
                'stocks.symbol',
                'stocks.name',
                'stocks.market',
            ])
            ->where('daily_bars.date', $date)
            ->where('stocks.market', 'TWSE')
            ->get();

        if ($bars->count() === 0) {
            $this->error("No daily_bars found for date={$date}");
            return self::FAILURE;
        }

        // Build arrays for normalization
        $volumes = [];
        $turnovers = [];
        $volRanges = []; // intraday volatility proxy
        $chgAbs = [];
        $chgPct = [];

        foreach ($bars as $b) {
            $open = (float)($b->open ?? 0);
            $high = (float)($b->high ?? 0);
            $low  = (float)($b->low ?? 0);
            $close= (float)($b->close ?? 0);
            $change = (float)($b->change ?? 0);

            $volumes[] = (int)($b->volume ?? 0);
            $turnovers[] = (int)($b->turnover ?? 0);

            $base = $open > 0 ? $open : ($close > 0 ? $close : 0);
            $rangePct = $base > 0 ? (($high - $low) / $base) : 0;
            $volRanges[] = $rangePct;

            $chgAbs[] = abs($change);
            $chgPct[] = ($base > 0) ? ($change / $base) : 0;
        }

        $minMax = function(array $arr): array {
            if (count($arr) === 0) return [0, 0];
            return [min($arr), max($arr)];
        };

        [$minVol, $maxVol] = $minMax($volumes);
        [$minTo, $maxTo] = $minMax($turnovers);
        [$minVr, $maxVr] = $minMax($volRanges);
        [$minChgAbs, $maxChgAbs] = $minMax($chgAbs);
        [$minChgPct, $maxChgPct] = $minMax($chgPct);

        $norm = function(float $v, float $min, float $max): float {
            if ($max <= $min) return 0.0;
            return ($v - $min) / ($max - $min);
        };

        $now = now();

        // Clear previous scores for the date (idempotent)
        DB::table('daily_scores')->where('date', $date)->delete();

        $scored = [];

        foreach ($bars as $b) {
            $open = (float)($b->open ?? 0);
            $high = (float)($b->high ?? 0);
            $low  = (float)($b->low ?? 0);
            $close= (float)($b->close ?? 0);
            $change = (float)($b->change ?? 0);

            $volume = (float)($b->volume ?? 0);
            $turnover = (float)($b->turnover ?? 0);

            $base = $open > 0 ? $open : ($close > 0 ? $close : 0);
            $rangePct = $base > 0 ? (($high - $low) / $base) : 0.0;
            $chgAbsV = abs($change);
            $chgPctV = $base > 0 ? ($change / $base) : 0.0;

            // Component scores (0-100)
            $liquidity = (int)round(100 * max(
                $norm($volume, $minVol, $maxVol),
                $norm($turnover, $minTo, $maxTo)
            ));

            $volatility = (int)round(100 * $norm($rangePct, $minVr, $maxVr));

            // Momentum: mix abs change and pct change (pref pct)
            $momentum = (int)round(100 * max(
                $norm($chgAbsV, $minChgAbs, $maxChgAbs),
                $norm($chgPctV, $minChgPct, $maxChgPct)
            ));

            // Stable: inverse of volatility
            $stable = 100 - $volatility;

            // Drawdown/chip/value not available in day-0; keep 0
            $drawdown = 0;
            $chip = 0;
            $value = 0;

            // Bucket assignment (v1)
            // - Trend: momentum high
            // - Stable: stable high
            // - Liquidity: liquidity high
            // - Volatility: volatility high
            $bucketScores = [
                'trend'      => $momentum,
                'stable'     => $stable,
                'liquidity'  => $liquidity,
                'volatility' => $volatility,
            ];
            arsort($bucketScores);
            $bucket = array_key_first($bucketScores);

            // Total score: weighted (v1)
            // Trend: momentum(0.5) + liquidity(0.3) + stable(0.2)
            // Stable: stable(0.6) + liquidity(0.3) + (100-volatility)(0.1)
            // Liquidity: liquidity(0.7) + stable(0.2) + momentum(0.1)
            // Volatility: volatility(0.6) + liquidity(0.2) + momentum(0.2)
            $total = 0;
            if ($bucket === 'trend') {
                $total = 0.5*$momentum + 0.3*$liquidity + 0.2*$stable;
            } elseif ($bucket === 'stable') {
                $total = 0.6*$stable + 0.3*$liquidity + 0.1*(100-$volatility);
            } elseif ($bucket === 'liquidity') {
                $total = 0.7*$liquidity + 0.2*$stable + 0.1*$momentum;
            } else { // volatility
                $total = 0.6*$volatility + 0.2*$liquidity + 0.2*$momentum;
            }
            $scoreTotal = (int)max(0, min(100, round($total)));

            // Risk flags (v1)
            $warnings = [];
            if ($volatility >= 85) $warnings[] = '高波動';
            if ($liquidity <= 10) $warnings[] = '低流動性';
            if ($open > 0 && abs($chgPctV) >= 0.08) $warnings[] = '單日大幅波動(>=8%)';

            $meta = [
                'range_pct' => round($rangePct, 6),
                'change_pct' => $base > 0 ? round($chgPctV, 6) : null,
                'warnings' => $warnings,
            ];

            DB::table('daily_scores')->insert([
                'stock_id' => $b->stock_id,
                'date' => $date,
                'bucket' => $bucket,
                'score_total' => $scoreTotal,
                'score_liquidity' => $liquidity,
                'score_volatility' => $volatility,
                'score_momentum' => $momentum,
                'score_drawdown' => $drawdown,
                'score_chip' => $chip,
                'score_value' => $value,
                'meta' => json_encode($meta, JSON_UNESCAPED_UNICODE),
                'created_at' => $now,
                'updated_at' => $now,
            ]);

            $scored[] = [
                'symbol' => $b->symbol,
                'name' => $b->name,
                'bucket' => $bucket,
                'score_total' => $scoreTotal,
                'liquidity' => $liquidity,
                'volatility' => $volatility,
                'momentum' => $momentum,
                'warnings' => $warnings,
            ];
        }

        // Build Top20 mixed
        $pickTop = function(string $bucket, int $n) use ($date) {
            return DB::table('daily_scores')
                ->join('stocks', 'stocks.id', '=', 'daily_scores.stock_id')
                ->where('daily_scores.date', $date)
                ->where('daily_scores.bucket', $bucket)
                ->orderByDesc('daily_scores.score_total')
                ->limit($n)
                ->get([
                    'stocks.symbol', 'stocks.name',
                    'daily_scores.bucket', 'daily_scores.score_total',
                    'daily_scores.score_liquidity', 'daily_scores.score_volatility', 'daily_scores.score_momentum',
                    'daily_scores.meta',
                ])
                ->map(function($r) {
                    $meta = json_decode((string)$r->meta, true) ?: [];
                    return [
                        'symbol' => $r->symbol,
                        'name' => $r->name,
                        'bucket' => $r->bucket,
                        'score_total' => (int)$r->score_total,
                        'signals' => [
                            'liquidity' => (int)$r->score_liquidity,
                            'volatility' => (int)$r->score_volatility,
                            'momentum' => (int)$r->score_momentum,
                        ],
                        'warnings' => $meta['warnings'] ?? [],
                    ];
                })
                ->values()
                ->all();
        };

        $top = array_merge(
            $pickTop('trend', 6),
            $pickTop('stable', 6),
            $pickTop('liquidity', 4),
            $pickTop('volatility', 4),
        );

        // Market summary (v1 simple)
        $marketSummary = 'TWSE盤後快照：已完成日線入庫與Top20產生（v1 day-0 scoring）';

        // Global warnings (v1)
        $globalWarnings = [
            'v1限制：目前僅使用單日數據，尚未引入均線/回撤/歷史波動率/法人籌碼等指標；日後累積資料後升級。',
        ];

        DB::table('daily_reports')->upsert(
            [[
                'date' => $date,
                'market_summary' => $marketSummary,
                'warnings' => json_encode($globalWarnings, JSON_UNESCAPED_UNICODE),
                'top20' => json_encode($top, JSON_UNESCAPED_UNICODE),
                'created_at' => $now,
                'updated_at' => $now,
            ]],
            ['date'],
            ['market_summary','warnings','top20','updated_at']
        );

        $this->info("Done. daily_scores inserted=" . count($scored) . ", top20=" . count($top));
        return self::SUCCESS;
    }
}