<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration {
    public function up(): void
    {
        Schema::create('daily_scores', function (Blueprint $table) {
            $table->id();
            $table->foreignId('stock_id')->constrained('stocks')->cascadeOnDelete();
            $table->date('date');

            $table->string('bucket', 20); // stable / trend / chip / value

            $table->unsignedTinyInteger('score_total')->default(0);

            $table->unsignedTinyInteger('score_liquidity')->default(0);
            $table->unsignedTinyInteger('score_volatility')->default(0);
            $table->unsignedTinyInteger('score_momentum')->default(0);
            $table->unsignedTinyInteger('score_drawdown')->default(0);
            $table->unsignedTinyInteger('score_chip')->default(0);
            $table->unsignedTinyInteger('score_value')->default(0);

            $table->json('meta')->nullable(); // raw factor notes
            $table->timestamps();

            $table->unique(['stock_id', 'date']);
            $table->index(['date', 'bucket', 'score_total']);
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('daily_scores');
    }
};
