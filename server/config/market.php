<?php

return [
    'twse' => [
        // Official TWSE OpenAPI base
        'base_url' => env('TWSE_BASE_URL', 'https://openapi.twse.com.tw/v1'),
        // STOCK_DAY_ALL is "latest trading day" snapshot (all listed)
        'endpoint_stock_day_all' => env('TWSE_STOCK_DAY_ALL', '/exchangeReport/STOCK_DAY_ALL'),
    ],

    'universe' => [
        'markets' => ['TWSE'], // v1: TWSE first; TPEx will be added next step
        'min_volume' => env('MARKET_MIN_VOLUME', 0),
    ],
];