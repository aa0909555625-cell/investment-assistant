<?php

namespace App\Services\Market;

use Illuminate\Support\Facades\DB;

class MarketSnapshotService
{
    /**
     * Build snapshot for a given trading date (YYYY-MM-DD).
     * Data source: daily_bars + daily_scores (your own DB).
     */
    public function buildSnapshot(string $date): array
    {
        // ---- A) Market breadth from daily_bars ----
        $rows = DB::table('daily_bars')
            ->select(['close', 'change', 'volume', 'turnover'])
            ->where('date', $date)
            ->get();

        $total = $rows->count();

        $adv = 0; $dec = 0; $flat = 0;
        $bigUp = 0; $bigDown = 0;
        $sumVol = 0.0; $sumTov = 0.0;

        // pct stats
        $pcts = [];

        foreach ($rows as $r) {
            $chg = (float)($r->change ?? 0);
            $close = (float)($r->close ?? 0);
            $prev = $close - $chg;
            $pct = ($prev != 0.0) ? ($chg / $prev * 100.0) : 0.0;

            $pcts[] = $pct;

            if ($chg > 0) $adv++;
            elseif ($chg < 0) $dec++;
            else $flat++;

            if ($pct >= 7.0) $bigUp++;
            if ($pct <= -7.0) $bigDown++;

            $sumVol += (float)($r->volume ?? 0);
            $sumTov += (float)($r->turnover ?? 0);
        }

        sort($pcts);
        $medianPct = $this->percentile($pcts, 50);
        $p90 = $this->percentile($pcts, 90);
        $p10 = $this->percentile($pcts, 10);

        $advRatio = ($total > 0) ? round($adv / $total * 100, 1) : 0.0;
        $decRatio = ($total > 0) ? round($dec / $total * 100, 1) : 0.0;

        // ---- B) Score distribution from daily_scores ----
        $scoreAgg = DB::table('daily_scores')
            ->selectRaw('COUNT(*) as n, AVG(score_total) as avg_score, MIN(score_total) as min_score, MAX(score_total) as max_score')
            ->where('date', $date)
            ->first();

        $n = (int)($scoreAgg->n ?? 0);
        $avgScore = ($n > 0) ? round((float)$scoreAgg->avg_score, 1) : null;

        $countBuy   = $this->countScore($date, 70, null);      // >=70
        $countWatch = $this->countScore($date, 55, 69.9999);   // 55-69
        $countAvoid = $this->countScore($date, 0, 54.9999);    // <55

        // ---- C) Market score/state/advice (rule-based v1) ----
        // Key drivers: breadth (advRatio), score avg, extreme moves
        $extreme = ($total > 0) ? round(($bigUp + $bigDown) / $total * 100, 1) : 0.0;

        // Build a 0-100 "market_score" (v1)
        $marketScore = 50;

        // breadth
        if ($advRatio >= 60) $marketScore += 15;
        elseif ($advRatio >= 52) $marketScore += 8;
        elseif ($advRatio <= 40) $marketScore -= 15;
        elseif ($advRatio <= 48) $marketScore -= 8;

        // score avg
        if ($avgScore !== null) {
            if ($avgScore >= 62) $marketScore += 10;
            elseif ($avgScore >= 58) $marketScore += 6;
            elseif ($avgScore <= 50) $marketScore -= 10;
            elseif ($avgScore <= 54) $marketScore -= 6;
        }

        // volatility / extremes (too high = risk)
        if ($extreme >= 12) $marketScore -= 8;
        elseif ($extreme >= 8) $marketScore -= 4;

        $marketScore = max(0, min(100, (int)round($marketScore)));

        // Market state label
        $marketState = 'neutral';
        if ($marketScore >= 70) $marketState = 'risk_on';
        elseif ($marketScore >= 60) $marketState = 'bullish';
        elseif ($marketScore <= 35) $marketState = 'risk_off';
        elseif ($marketScore <= 45) $marketState = 'bearish';

        // Capital advice (0-100): how aggressive to allocate today
        // Conservative: penalize high extremes
        $capitalAdvice = $marketScore;
        if ($extreme >= 10) $capitalAdvice = max(0, $capitalAdvice - 10);
        $capitalAdvice = max(0, min(100, (int)round($capitalAdvice)));

        $thresholds = [
            ['label' => '>= 75', 'action' => '偏多可加碼（分批）', 'note' => '盤勢強 + 多數股票同步走強。仍建議分批與風控。'],
            ['label' => '65 - 74', 'action' => '可布局（保守）', 'note' => '偏多盤，優先挑高分/高流動性標的。'],
            ['label' => '55 - 64', 'action' => '中性觀察', 'note' => '可小額試單或等待更明確訊號。'],
            ['label' => '45 - 54', 'action' => '降低曝險', 'note' => '盤勢偏弱，避免追高，減少新倉。'],
            ['label' => '< 45', 'action' => '偏空減碼/防守', 'note' => '以現金為王，嚴控停損，避免硬凹。'],
        ];

        return [
            'date' => $date,

            // market decision meta
            'market_score' => $marketScore,
            'market_state' => $marketState,
            'capital_advice' => $capitalAdvice,
            'thresholds' => $thresholds,

            // breadth
            'breadth' => [
                'total' => $total,
                'adv' => $adv,
                'dec' => $dec,
                'flat' => $flat,
                'adv_ratio' => $advRatio,
                'dec_ratio' => $decRatio,
                'big_up_pct_ge_7' => $bigUp,
                'big_down_pct_le_-7' => $bigDown,
                'extreme_ratio' => $extreme,
                'median_change_pct' => round((float)$medianPct, 2),
                'p10_change_pct' => round((float)$p10, 2),
                'p90_change_pct' => round((float)$p90, 2),
                'sum_volume' => (int)round($sumVol),
                'sum_turnover' => (int)round($sumTov),
            ],

            // score distribution
            'scores' => [
                'n' => $n,
                'avg' => $avgScore,
                'min' => ($n > 0) ? (int)$scoreAgg->min_score : null,
                'max' => ($n > 0) ? (int)$scoreAgg->max_score : null,
                'buy_ge_70' => $countBuy,
                'watch_55_69' => $countWatch,
                'avoid_lt_55' => $countAvoid,
            ],
        ];
    }

    private function countScore(string $date, float $min, ?float $max): int
    {
        $q = DB::table('daily_scores')->where('date', $date)->where('score_total', '>=', $min);
        if ($max !== null) $q->where('score_total', '<=', $max);
        return (int)$q->count();
    }

    private function percentile(array $sorted, float $p): float
    {
        $n = count($sorted);
        if ($n === 0) return 0.0;
        $pos = ($p / 100.0) * ($n - 1);
        $lo = (int)floor($pos);
        $hi = (int)ceil($pos);
        if ($lo === $hi) return (float)$sorted[$lo];
        $w = $pos - $lo;
        return (float)$sorted[$lo] * (1.0 - $w) + (float)$sorted[$hi] * $w;
    }
}