<?php

namespace App\Services\DataSources;

use Illuminate\Support\Facades\Http;
use Illuminate\Support\Str;

class TwseOpenApiClient
{
    public function __construct(
        private readonly string $baseUrl,
        private readonly string $endpointStockDayAll,
    ) {}

    public static function fromConfig(): self
    {
        $cfg = config('market.twse');
        return new self(
            baseUrl: rtrim((string)($cfg['base_url'] ?? ''), '/'),
            endpointStockDayAll: (string)($cfg['endpoint_stock_day_all'] ?? '/exchangeReport/STOCK_DAY_ALL'),
        );
    }

    /**
     * Fetch latest trading day snapshot for all TWSE listed stocks.
     * Returns array of rows (each row associative).
     *
     * @return array<int, array<string, mixed>>
     */
    public function fetchStockDayAll(): array
    {
        $url = $this->baseUrl . $this->endpointStockDayAll;

        $resp = Http::timeout(30)->retry(2, 500)->get($url);

        if (!$resp->ok()) {
            throw new \RuntimeException('TWSE OpenAPI request failed: HTTP ' . $resp->status());
        }

        $json = $resp->json();
        // TWSE OpenAPI commonly returns JSON array at root
        if (is_array($json)) {
            return $json;
        }

        // Sometimes it may wrap in data key
        if (is_array($json) && isset($json['data']) && is_array($json['data'])) {
            return $json['data'];
        }

        throw new \RuntimeException('TWSE OpenAPI response malformed');
    }

    public function normalizeSymbol(string $symbol): string
    {
        // e.g. "2330"
        return Str::upper(trim($symbol));
    }

    /**
     * Convert numeric strings like "1,234,567" / "--" / "" into float|null
     */
    public function toFloatOrNull(mixed $v): ?float
    {
        if ($v === null) return null;
        $s = trim((string)$v);
        if ($s === '' || $s === '--' || $s === '---') return null;
        $s = str_replace(',', '', $s);
        if (!is_numeric($s)) return null;
        return (float)$s;
    }

    /**
     * Convert numeric strings like "1,234,567" / "--" / "" into int|null
     */
    public function toIntOrNull(mixed $v): ?int
    {
        if ($v === null) return null;
        $s = trim((string)$v);
        if ($s === '' || $s === '--' || $s === '---') return null;
        $s = str_replace(',', '', $s);
        if (!is_numeric($s)) return null;
        return (int)$s;
    }

    /**
     * Try to find key in row by multiple possible names.
     */
    public function pick(array $row, array $keys): mixed
    {
        foreach ($keys as $k) {
            if (array_key_exists($k, $row)) return $row[$k];
        }
        return null;
    }
}