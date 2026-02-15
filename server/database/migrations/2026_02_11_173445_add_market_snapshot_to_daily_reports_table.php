<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration {
    public function up(): void
    {
        Schema::table('daily_reports', function (Blueprint $table) {
            if (!Schema::hasColumn('daily_reports', 'market_snapshot')) {
                $table->json('market_snapshot')->nullable()->after('ai_comment');
            }
            if (!Schema::hasColumn('daily_reports', 'market_score')) {
                $table->unsignedTinyInteger('market_score')->nullable()->after('market_snapshot');
            }
            if (!Schema::hasColumn('daily_reports', 'market_state')) {
                $table->string('market_state', 20)->nullable()->after('market_score');
            }
            if (!Schema::hasColumn('daily_reports', 'capital_advice')) {
                $table->unsignedTinyInteger('capital_advice')->nullable()->after('market_state'); // 0-100 (%)
            }
        });
    }

    public function down(): void
    {
        Schema::table('daily_reports', function (Blueprint $table) {
            if (Schema::hasColumn('daily_reports', 'capital_advice')) {
                $table->dropColumn('capital_advice');
            }
            if (Schema::hasColumn('daily_reports', 'market_state')) {
                $table->dropColumn('market_state');
            }
            if (Schema::hasColumn('daily_reports', 'market_score')) {
                $table->dropColumn('market_score');
            }
            if (Schema::hasColumn('daily_reports', 'market_snapshot')) {
                $table->dropColumn('market_snapshot');
            }
        });
    }
};