<?php

namespace App\Http\Controllers;

use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;

class ReportController extends Controller
{
    public function today()
    {
        $date = DB::table('daily_reports')->orderByDesc('date')->value('date');
        if (!$date) abort(404, 'No report found');
        return redirect()->route('report.show', ['date' => $date]);
    }

    public function show(string $date)
    {
        $report = DB::table('daily_reports')->where('date', $date)->first();
        if (!$report) abort(404, 'Report not found');

        $top20 = $report->top20 ? json_decode($report->top20, true) : [];
        $ai = $report->ai_comment ?? '';

        $hasSnapshot = Schema::hasColumn('daily_reports', 'market_snapshot');
        $hasScore    = Schema::hasColumn('daily_reports', 'market_score');
        $hasState    = Schema::hasColumn('daily_reports', 'market_state');
        $hasAdvice   = Schema::hasColumn('daily_reports', 'capital_advice');

        $snapshot = null;
        $marketScore = null;
        $marketState = null;
        $capitalAdvice = null;

        // 1) read from columns if exist
        if ($hasSnapshot && isset($report->market_snapshot) && $report->market_snapshot) {
            $snapshot = json_decode($report->market_snapshot, true);
        }
        if ($hasScore && isset($report->market_score)) $marketScore = $report->market_score;
        if ($hasState && isset($report->market_state)) $marketState = $report->market_state;
        if ($hasAdvice && isset($report->capital_advice)) $capitalAdvice = $report->capital_advice;

        // 2) fallback: derive from snapshot
        if ($snapshot) {
            if ($marketScore === null && isset($snapshot['market_score'])) $marketScore = $snapshot['market_score'];
            if ($marketState === null && isset($snapshot['market_state'])) $marketState = $snapshot['market_state'];
            if ($capitalAdvice === null && isset($snapshot['capital_advice'])) $capitalAdvice = $snapshot['capital_advice'];
        }

        // 3) HARD GUARANTEE: if snapshot is still missing, compute NOW and (if possible) persist
        if (!$snapshot) {
            // build snapshot only if daily_bars exists for this date
            $barsCount = (int)DB::table('daily_bars')->where('date', $date)->count();
            if ($barsCount > 0) {
                /** @var \App\Services\Market\MarketSnapshotService $svc */
                $svc = app(\App\Services\Market\MarketSnapshotService::class);
                $snapshot = $svc->buildSnapshot($date);

                // persist back if columns exist
                $update = [];
                if ($hasSnapshot) $update['market_snapshot'] = json_encode($snapshot, JSON_UNESCAPED_UNICODE);
                if ($hasScore && ($marketScore === null) && isset($snapshot['market_score'])) $update['market_score'] = $snapshot['market_score'];
                if ($hasState && ($marketState === null) && isset($snapshot['market_state'])) $update['market_state'] = $snapshot['market_state'];
                if ($hasAdvice && ($capitalAdvice === null) && isset($snapshot['capital_advice'])) $update['capital_advice'] = $snapshot['capital_advice'];

                if (!empty($update)) {
                    DB::table('daily_reports')->where('date', $date)->update($update);
                }

                // set output vars
                if ($marketScore === null && isset($snapshot['market_score'])) $marketScore = $snapshot['market_score'];
                if ($marketState === null && isset($snapshot['market_state'])) $marketState = $snapshot['market_state'];
                if ($capitalAdvice === null && isset($snapshot['capital_advice'])) $capitalAdvice = $snapshot['capital_advice'];
            }
        }

        return view('report.show', [
            'date' => $report->date,
            'top20' => $top20,
            'ai_comment' => $ai,
            'market_snapshot' => $snapshot,
            'market_score' => $marketScore,
            'market_state' => $marketState,
            'capital_advice' => $capitalAdvice,
        ]);
    }
}