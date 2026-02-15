<!DOCTYPE html>
<html lang="zh-TW">
<head>
  <meta charset="UTF-8">
  <title>台股 Top20 日報｜{{ $date }}</title>
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <style>
    body { font-family: system-ui, -apple-system, "Segoe UI", Arial; margin: 18px; color:#111; }
    h1,h2,h3 { margin: 10px 0; }
    .muted { color:#666; font-size:12px; }
    .card { border:1px solid #e5e7eb; border-radius:10px; padding:12px; margin:10px 0; background:#fff; }
    .grid { display:grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap:10px; }
    @media (max-width: 1100px) { .grid { grid-template-columns:1fr; } }
    table { width:100%; border-collapse: collapse; margin:8px 0 18px; }
    th,td { border:1px solid #e5e7eb; padding:8px; font-size:13px; vertical-align: top; }
    th { background:#f9fafb; text-align:left; }
    .badge { display:inline-block; padding:2px 8px; border-radius:999px; border:1px solid #ddd; font-size:12px; }
    .warn { color:#b00020; font-size:12px; }
    .bar { height:10px; border-radius:999px; background:#eee; overflow:hidden; }
    .bar > div { height:100%; }
    .pre { background:#0b1220; color:#e5e7eb; padding:14px; border-radius:10px; white-space: pre-wrap; font-size: 12px; line-height: 1.35; }
    .kpi { font-size: 22px; font-weight: 800; }
    .small { font-size: 12px; color:#666; }
    .row { display:flex; gap:10px; flex-wrap:wrap; align-items:center; }
    .hr { height:1px; background:#eee; margin:12px 0; }
  </style>
</head>
<body>

  <h1>台股 Top20 日報</h1>
  <div class="muted">日期：{{ $date }}（v1｜單日資料規則型，非投資建議）</div>

  {{-- ===== Market snapshot (whole market) ===== --}}
  @php
    $snap = $market_snapshot ?? null;
    $breadth = $snap['breadth'] ?? null;
    $scores = $snap['scores'] ?? null;
    $thresholds = $snap['thresholds'] ?? [];
    $ms = $market_score ?? ($snap['market_score'] ?? null);
    $state = $market_state ?? ($snap['market_state'] ?? null);
    $cap = $capital_advice ?? ($snap['capital_advice'] ?? null);

    $stateLabel = [
      'risk_on' => '偏多（Risk-On）',
      'bullish' => '偏多（Bullish）',
      'neutral' => '中性（Neutral）',
      'bearish' => '偏空（Bearish）',
      'risk_off' => '偏空（Risk-Off）',
    ][$state] ?? ($state ?? 'n/a');

    $barPct = is_null($ms) ? 0 : max(0, min(100, (int)$ms));
    $capPct = is_null($cap) ? 0 : max(0, min(100, (int)$cap));
  @endphp

  <div class="card">
    <h2>市場盤口總覽（全市場）</h2>

    <div class="row">
      <span class="badge">市場狀態：{{ $stateLabel }}</span>
      @if(!is_null($ms)) <span class="badge">市場總分：{{ $ms }}/100</span> @endif
      @if(!is_null($cap)) <span class="badge">資金積極度：{{ $cap }}/100</span> @endif
      <span class="muted">（分數越高＝越適合進場/加碼；越低＝偏防守/減碼）</span>
    </div>

    <div class="hr"></div>

    <div class="grid">
      <div class="card" style="margin:0">
        <div class="small">市場總分（0-100）</div>
        <div class="kpi">{{ is_null($ms) ? 'n/a' : $ms }}</div>
        <div class="bar"><div style="width: {{ $barPct }}%; background:#2563eb;"></div></div>
        <div class="small muted">用市場廣度 + 平均分數 + 極端波動比例估算</div>
      </div>

      <div class="card" style="margin:0">
        <div class="small">資金積極度（0-100）</div>
        <div class="kpi">{{ is_null($cap) ? 'n/a' : $cap }}</div>
        <div class="bar"><div style="width: {{ $capPct }}%; background:#16a34a;"></div></div>
        <div class="small muted">較保守版本（極端波動高會扣分）</div>
      </div>

      <div class="card" style="margin:0">
        <div class="small">市場廣度（漲/跌家數）</div>
        @if($breadth)
          <div class="kpi">{{ $breadth['adv_ratio'] ?? 0 }}% <span class="small">上漲</span></div>
          <div class="small muted">
            漲 {{ $breadth['adv'] ?? 0 }}｜跌 {{ $breadth['dec'] ?? 0 }}｜平 {{ $breadth['flat'] ?? 0 }}｜總 {{ $breadth['total'] ?? 0 }}
          </div>
          <div class="small muted">
            中位數%：{{ $breadth['median_change_pct'] ?? 0 }}｜P10：{{ $breadth['p10_change_pct'] ?? 0 }}｜P90：{{ $breadth['p90_change_pct'] ?? 0 }}
          </div>
          <div class="small muted">
            極端波動(>=7% 或 <=-7%)：{{ $breadth['extreme_ratio'] ?? 0 }}%
          </div>
        @else
          <div class="warn">尚無盤口資料（market_snapshot 尚未生成）</div>
        @endif
      </div>
    </div>

    <div class="hr"></div>

    <h3>分析評估：分數區間 → 行動建議</h3>
    <table>
      <thead>
        <tr>
          <th style="width:120px">分數</th>
          <th style="width:220px">建議</th>
          <th>說明</th>
        </tr>
      </thead>
      <tbody>
        @foreach($thresholds as $t)
          <tr>
            <td><span class="badge">{{ $t['label'] ?? '' }}</span></td>
            <td><b>{{ $t['action'] ?? '' }}</b></td>
            <td class="muted">{{ $t['note'] ?? '' }}</td>
          </tr>
        @endforeach
      </tbody>
    </table>

    <div class="card" style="margin:0">
      <h3 style="margin-top:0">市場熱度分佈（依 daily_scores）</h3>
      @if($scores)
        <div class="row">
          <span class="badge">樣本：{{ $scores['n'] ?? 0 }}</span>
          <span class="badge">平均分：{{ $scores['avg'] ?? 'n/a' }}</span>
          <span class="badge">最低/最高：{{ $scores['min'] ?? 'n/a' }} / {{ $scores['max'] ?? 'n/a' }}</span>
        </div>
        <div class="small muted" style="margin-top:6px">
          ≥70（可布局候選）：{{ $scores['buy_ge_70'] ?? 0 }}｜
          55-69（觀察）：{{ $scores['watch_55_69'] ?? 0 }}｜
          <55（避開/防守）：{{ $scores['avoid_lt_55'] ?? 0 }}
        </div>
      @else
        <div class="warn">尚無分數分佈資料</div>
      @endif
    </div>

  </div>

  {{-- ===== Top20 table ===== --}}
  <div class="card">
    <h2>Top20 名單</h2>
    <table>
      <thead>
        <tr>
          <th>#</th>
          <th>代號</th>
          <th>名稱</th>
          <th>Bucket</th>
          <th>總分</th>
          <th>Signals</th>
          <th>Warnings</th>
        </tr>
      </thead>
      <tbody>
      @foreach($top20 as $i => $r)
        <tr>
          <td>{{ $i+1 }}</td>
          <td>{{ $r['symbol'] ?? '' }}</td>
          <td>{{ $r['name'] ?? '' }}</td>
          <td>{{ $r['bucket'] ?? '' }}</td>
          <td>{{ $r['score_total'] ?? '' }}</td>
          <td class="muted">{{ isset($r['signals']) ? json_encode($r['signals'], JSON_UNESCAPED_UNICODE) : '' }}</td>
          <td class="warn">{{ isset($r['warnings']) ? implode('、', $r['warnings']) : '' }}</td>
        </tr>
      @endforeach
      </tbody>
    </table>
  </div>

  {{-- ===== AI comment ===== --}}
  <div class="card">
    <h2>AI 文字解讀（v1｜規則型）</h2>
    <div class="pre">{{ $ai_comment }}</div>
  </div>

  <div class="muted">
    參數：?capital=100000&pick=5（資金配置表）｜本頁新增：全市場盤口 / 行動分數區間建議
  </div>

</body>
</html>