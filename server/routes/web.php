<?php

use App\Http\Controllers\ReportController;
use Illuminate\Support\Facades\Route;

Route::get('/', function () {
    return view('welcome');
});

Route::get('/today', [ReportController::class, 'today'])->name('report.today');
Route::get('/report/{date}', [ReportController::class, 'show'])->name('report.show');
