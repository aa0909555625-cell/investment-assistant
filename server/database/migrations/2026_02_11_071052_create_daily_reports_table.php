<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration {
    public function up(): void
    {
        Schema::create('daily_reports', function (Blueprint $table) {
            $table->id();
            $table->date('date')->unique();

            $table->string('market_summary', 255)->nullable();
            $table->json('warnings')->nullable();
            $table->json('top20')->nullable(); // snapshot

            $table->timestamps();
            $table->index(['date']);
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('daily_reports');
    }
};
