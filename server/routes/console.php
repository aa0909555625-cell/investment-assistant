<?php

use Illuminate\Support\Facades\Artisan;
use Illuminate\Support\Facades\DB;

Artisan::command('market:fetch-daily-bars {date?}', function ($date = null) {
    $args = $date ? ['date' => $date] : [];
    $this->call(\App\Console\Commands\Market\FetchDailyBars::class, $args);
})->purpose('Fetch TWSE daily bars snapshot and upsert into stocks + daily_bars');

Artisan::command('market:generate-daily-report {date}', function ($date) {
    $this->call(\App\Console\Commands\Market\GenerateDailyReport::class, ['date' => $date]);
})->purpose('Generate v1 daily scores + mixed Top20 + report snapshot');

Artisan::command('market:comment {date}', function ($date) {
    $this->call(\App\Console\Commands\Market\GenerateAiComment::class, ['date' => $date]);
})->purpose('Generate rule-based Top20 comments into daily_reports.ai_comment');

/**
 * ✅ Auto-align to actual latest trading date in DB
 * Why: TWSE snapshot returns latest trading day; requested "today" may be non-trading day.
 */
Artisan::command('market:run-daily {date?}', function ($date = null) {
    $requested = $date ?: now('Asia/Taipei')->toDateString();
    $this->info("Running daily pipeline for requested_date={$requested}");

    // 1) fetch snapshot first
    $this->call('market:fetch-daily-bars', ['date' => $requested]);

    // 2) determine actual latest bars date
    $actual = DB::table('daily_bars')->max('date');
    if (!$actual) {
        $this->error("No daily_bars found after fetch. Abort.");
        return 1;
    }

    $this->info("Auto-aligned actual_trading_date={$actual} (requested={$requested})");

    // 3) generate report + comment using actual date
    $this->call('market:generate-daily-report', ['date' => $actual]);
    $this->call('market:comment', ['date' => $actual]);

    $this->info("Daily pipeline DONE for actual_trading_date={$actual}");
    return 0;
})->purpose('Run full daily pipeline with trading-date auto-align: fetch -> report -> comment');