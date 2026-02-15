<?php

namespace App\Console\Commands\Market;

use App\Services\Market\MarketSnapshotService;
use Illuminate\Console\Command;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;

class RunDaily extends Command
{
    protected $signature = 'market:run-daily {date?}';
    protected $description = 'Run full daily pipeline: fetch -> score/report -> comment (+ market snapshot)';

    public function handle(MarketSnapshotService $snapshotService): int
    {
        $requested = (string)($this->argument('date') ?? now()->toDateString());
        $this->info("Running daily pipeline for requested_date={$requested}");

        // 1) Fetch
        $this->call('market:fetch-daily-bars', ['date' => $requested]);

        // 2) Auto-align actual trading date (based on what got stored in daily_bars)
        $actual = DB::table('daily_bars')->max('date');
        if (!$actual) {
            $this->warn("No daily_bars found after fetch. Stop.");
            return self::FAILURE;
        }

        if ($actual !== $requested) {
            $this->warn("Auto-aligned actual_trading_date={$actual} (requested={$requested})");
        } else {
            $this->info("Auto-aligned actual_trading_date={$actual} (requested={$requested})");
        }

        // 3) Score/report
        $this->call('market:generate-daily-report', ['date' => $actual]);

        // 4) Comment
        $this->call('market:comment', ['date' => $actual]);

        // 5) Market snapshot (whole-market dashboard)
        $snapshot = $snapshotService->buildSnapshot($actual);

        $hasSnapshot = Schema::hasColumn('daily_reports', 'market_snapshot');
        $hasScore    = Schema::hasColumn('daily_reports', 'market_score');
        $hasState    = Schema::hasColumn('daily_reports', 'market_state');
        $hasAdvice   = Schema::hasColumn('daily_reports', 'capital_advice');

        if ($hasSnapshot || $hasScore || $hasState || $hasAdvice) {
            $update = [];
            if ($hasSnapshot) $update['market_snapshot'] = json_encode($snapshot, JSON_UNESCAPED_UNICODE);
            if ($hasScore)    $update['market_score'] = $snapshot['market_score'] ?? null;
            if ($hasState)    $update['market_state'] = $snapshot['market_state'] ?? null;
            if ($hasAdvice)   $update['capital_advice'] = $snapshot['capital_advice'] ?? null;

            if (!empty($update)) {
                DB::table('daily_reports')->where('date', $actual)->update($update);
                $this->info("Stored market snapshot into daily_reports for date={$actual}");
            }
        } else {
            $this->warn("Step7 columns not found in daily_reports. Snapshot skipped.");
        }

        $this->info("Daily pipeline DONE for actual_trading_date={$actual}");
        return self::SUCCESS;
    }
}