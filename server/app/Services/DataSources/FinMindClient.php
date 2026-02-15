<?php

namespace App\Services\DataSources;

use Illuminate\Support\Facades\Http;
use Illuminate\Support\Str;

class FinMindClient
{
    public function __construct(
        private readonly string $baseUrl,
        private readonly string $token,
    ) {}

    public static function fromConfig(): self
    {
        $cfg = config('market.finmind');
        return new self(
            baseUrl: rtrim((string)($cfg['base_url'] ?? ''), '/'),
            token: (string)($cfg['token'] ?? ''),
        );
    }

    /**
     * Fetch Taiwan stock daily price (日資料).
     * Dataset: TaiwanStockPrice
     * @return array<int, array<string, mixed>>
     */
    public function fetchDaily(string $date): array
    {
        $query = [
            'dataset'    => 'TaiwanStockPrice',
            'data_id'    => '',  // empty => all stocks
            'start_date' => $date,
            'end_date'   => $date,
        ];

        if (!empty($this->token)) {
            $query['token'] = $this->token;
        }

        $url = $this->baseUrl . '/data';
        $resp = Http::timeout(30)->retry(2, 500)->get($url, $query);

        if (!$resp->ok()) {
            throw new \RuntimeException('FinMind request failed: HTTP ' . $resp->status());
        }

        $json = $resp->json();
        if (!is_array($json) || !isset($json['data'])) {
            throw new \RuntimeException('FinMind response malformed');
        }

        return is_array($json['data']) ? $json['data'] : [];
    }

    // v1: keep simple; refine later using listing dataset
    public function guessMarket(string $symbol): string
    {
        return 'TWSE';
    }

    public function normalizeSymbol(string $symbol): string
    {
        return Str::upper(trim($symbol));
    }
}