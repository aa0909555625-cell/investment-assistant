<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration {
    public function up(): void
    {
        Schema::create('stocks', function (Blueprint $table) {
            $table->id();
            $table->string('symbol', 10)->unique();        // 2330
            $table->string('name', 100);
            $table->string('market', 10);                 // TWSE / TPEx
            $table->string('industry', 100)->nullable();  // optional v1
            $table->boolean('is_active')->default(true);
            $table->timestamps();

            $table->index(['market', 'is_active']);
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('stocks');
    }
};
