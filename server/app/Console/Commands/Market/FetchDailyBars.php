<?php

namespace App\Console\Commands\Market;

use App\Services\DataSources\TwseOpenApiClient;
use Carbon\Carbon;
use Illuminate\Console\Command;
use Illuminate\Support\Facades\DB;

class FetchDailyBars extends Command
{
    protected $signature = 'market:fetch-daily-bars {date? : YYYY-MM-DD (kept for compatibility; TWSE uses latest snapshot)}';
    protected $description = 'Fetch TWSE daily bars (all listed, latest snapshot) and upsert into stocks + daily_bars';

    /**
     * Convert TWSE date formats to YYYY-MM-DD.
     * Possible inputs:
     * - "2026-02-10" (already ISO)
     * - "1150210" (ROC yyyMMdd, e.g. 1150210 => 2026-02-10)
     * - "115/02/10" (ROC yyy/MM/dd)
     */
    private function normalizeDate(string $raw, string $fallbackIso): string
    {
        $raw = trim($raw);
        if ($raw === '') return $fallbackIso;

        // ISO already
        if (preg_match('/^\d{4}-\d{2}-\d{2}$/', $raw)) {
            return $raw;
        }

        // ROC with slashes: 115/02/10
        if (preg_match('/^(\d{3})\/(\d{2})\/(\d{2})$/', $raw, $m)) {
            $y = (int)$m[1] + 1911;
            return sprintf('%04d-%02d-%02d', $y, (int)$m[2], (int)$m[3]);
        }

        // ROC compact: 1150210
        if (preg_match('/^(\d{3})(\d{2})(\d{2})$/', $raw, $m)) {
            $y = (int)$m[1] + 1911;
            return sprintf('%04d-%02d-%02d', $y, (int)$m[2], (int)$m[3]);
        }

        // As last resort, try Carbon parse
        try {
            return Carbon::parse($raw)->toDateString();
        } catch (\Throwable) {
            return $fallbackIso;
        }
    }

    public function handle(): int
    {
        $tz = 'Asia/Taipei';
        $dateArg = (string)($this->argument('date') ?? '');
        $fallbackDate = $dateArg !== ''
            ? Carbon::parse($dateArg, $tz)->toDateString()
            : Carbon::now($tz)->toDateString();

        $this->info("Fetching TWSE STOCK_DAY_ALL (latest trading day snapshot). requested_date={$fallbackDate}");

        $client = TwseOpenApiClient::fromConfig();
        $rows = $client->fetchStockDayAll();

        if (count($rows) === 0) {
            $this->warn('No data returned from TWSE OpenAPI.');
            return self::SUCCESS;
        }

        $this->info('Rows: ' . count($rows));

        $now = now();
        $upsertedStocks = 0;
        $upsertedBars = 0;

        DB::beginTransaction();
        try {
            foreach ($rows as $r) {
                if (!is_array($r)) continue;

                $symbolRaw = (string)$client->pick($r, ['Code', '證券代號', 'StockCode', 'stock_code']);
                $symbol = $client->normalizeSymbol($symbolRaw);
                if ($symbol === '') continue;

                $name = (string)$client->pick($r, ['Name', '證券名稱', 'StockName', 'stock_name']);
                if ($name === '') $name = $symbol;

                $rowDateRaw = (string)$client->pick($r, ['Date', '日期', 'date']);
                $date = $this->normalizeDate($rowDateRaw, $fallbackDate);

                $volume   = $client->toIntOrNull($client->pick($r, ['TradeVolume', '成交股數', 'Volume', 'trade_volume']));
                $turnover = $client->toIntOrNull($client->pick($r, ['TradeValue', '成交金額', 'Turnover', 'trade_value']));

                $open  = $client->toFloatOrNull($client->pick($r, ['OpeningPrice', '開盤價', 'Open', 'open']));
                $high  = $client->toFloatOrNull($client->pick($r, ['HighestPrice', '最高價', 'High', 'high']));
                $low   = $client->toFloatOrNull($client->pick($r, ['LowestPrice', '最低價', 'Low', 'low']));
                $close = $client->toFloatOrNull($client->pick($r, ['ClosingPrice', '收盤價', 'Close', 'close']));

                $change = $client->toFloatOrNull($client->pick($r, ['Change', '漲跌價差', 'change']));

                DB::table('stocks')->upsert(
                    [[
                        'symbol' => $symbol,
                        'name' => $name,
                        'market' => 'TWSE',
                        'industry' => null,
                        'is_active' => 1,
                        'created_at' => $now,
                        'updated_at' => $now,
                    ]],
                    ['symbol'],
                    ['name', 'market', 'updated_at']
                );
                $upsertedStocks++;

                $stockId = (int) DB::table('stocks')->where('symbol', $symbol)->value('id');

                DB::table('daily_bars')->upsert(
                    [[
                        'stock_id' => $stockId,
                        'date' => $date,
                        'open' => $open,
                        'high' => $high,
                        'low' => $low,
                        'close' => $close,
                        'volume' => $volume,
                        'turnover' => $turnover,
                        'change' => $change,
                        'created_at' => $now,
                        'updated_at' => $now,
                    ]],
                    ['stock_id', 'date'],
                    ['open','high','low','close','volume','turnover','change','updated_at']
                );
                $upsertedBars++;
            }

            DB::commit();
        } catch (\Throwable $e) {
            DB::rollBack();
            $this->error('Failed: ' . $e->getMessage());
            return self::FAILURE;
        }

        $this->info("Done. Upserted stocks={$upsertedStocks}, bars={$upsertedBars}");
        return self::SUCCESS;
    }
}