[CmdletBinding()]
param(
    # 0 (or any value <= 0) means "all time" - spans from the earliest logged session.
    [int]$Days = 7,
    [string]$Project,
    [int]$TopSessions = 10,
    [ValidateSet('opus','opus-4-launch','sonnet')]
    [string]$Pricing = 'opus'
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'token-usage-lib.ps1')

$rates = Get-PricingPreset $Pricing

$logPath      = Join-Path $HOME '.claude\token-usage.csv'
$modelLogPath = Join-Path $HOME '.claude\token-usage-by-model.csv'
$outPath      = Join-Path $HOME '.claude\token-dashboard.html'

$rows = Import-TokenUsageRows $logPath

$today    = (Get-Date).Date
$isAllTime = $Days -le 0

if ($isAllTime) {
    $rowsForRange = if ($Project) { @($rows | Where-Object { $_.project -eq $Project }) } else { $rows }
    $earliest = if (@($rowsForRange).Count -gt 0) {
        ($rowsForRange | ForEach-Object { [datetime]::ParseExact($_.date, 'yyyy-MM-dd', $null) } | Measure-Object -Minimum).Minimum
    } else { $today }
    $cutoff = $earliest.Date
    $Days   = [int]([math]::Floor(($today - $cutoff).TotalDays)) + 1
} else {
    $cutoff = $today.AddDays(-($Days - 1))
}

$filtered = @($rows | Where-Object {
    $d = [datetime]::ParseExact($_.date, 'yyyy-MM-dd', $null)
    $d -ge $cutoff -and $d -le $today
})
if ($Project) { $filtered = @($filtered | Where-Object { $_.project -eq $Project }) }

$sessionModelMap = Import-TokenUsageByModel $modelLogPath

function ConvertTo-CompactNumber([double]$n) {
    $abs = [math]::Abs($n)
    if ($abs -ge 1e9) { return ('{0:N1}B' -f ($n / 1e9)) }
    if ($abs -ge 1e6) { return ('{0:N1}M' -f ($n / 1e6)) }
    if ($abs -ge 1e3) { return ('{0:N1}K' -f ($n / 1e3)) }
    return ('{0:N0}' -f $n)
}

$meta = [ordered]@{
    generatedAt   = (Get-Date).ToString('yyyy-MM-dd HH:mm')
    days          = $Days
    allTime       = $isAllTime
    dateFrom      = $cutoff.ToString('yyyy-MM-dd')
    dateTo        = $today.ToString('yyyy-MM-dd')
    project       = $Project
    pricingLabel  = $rates.Label
}

if (@($filtered).Count -eq 0) {
    $data = [ordered]@{ meta = $meta; empty = $true }
} else {
    $total       = ($filtered | Measure-Object total          -Sum).Sum
    $subTotal    = ($filtered | Measure-Object subagent_total -Sum).Sum
    $cacheRead   = ($filtered | Measure-Object cache_read     -Sum).Sum
    $cacheCreate = ($filtered | Measure-Object cache_creation -Sum).Sum
    $inTok       = ($filtered | Measure-Object input          -Sum).Sum
    $outTok      = ($filtered | Measure-Object output         -Sum).Sum
    $sessions    = @($filtered).Count
    $subPct      = if ($total -gt 0) { [math]::Round(100 * $subTotal / $total, 1) } else { 0 }
    $cacheHitPct = if (($cacheRead + $cacheCreate) -gt 0) { [math]::Round(100 * $cacheRead / ($cacheRead + $cacheCreate), 1) } else { 0 }

    $inCost = 0.0; $outCost = 0.0; $cwCost5m = 0.0; $cwCost1h = 0.0; $crCost = 0.0
    $withModel = 0; $withoutModel = 0
    foreach ($row in $filtered) {
        $p = Get-SessionCostParts $row $sessionModelMap $rates
        $inCost   += $p.In
        $outCost  += $p.Out
        $cwCost5m += $p.Cw5m
        $cwCost1h += $p.Cw1h
        $crCost   += $p.Cr
        if ($p.HasModel) { $withModel++ } else { $withoutModel++ }
    }
    $totalLow  = $inCost + $outCost + $cwCost5m + $crCost
    $totalHigh = $inCost + $outCost + $cwCost1h + $crCost

    $totals = [ordered]@{
        total        = $total
        sessions     = $sessions
        input        = $inTok
        output       = $outTok
        cacheRead    = $cacheRead
        cacheCreate  = $cacheCreate
        subTotal     = $subTotal
        subPct       = $subPct
        cacheHitPct  = $cacheHitPct
    }

    $cost = [ordered]@{
        input          = [math]::Round($inCost, 2)
        output         = [math]::Round($outCost, 2)
        cacheWrite5m   = [math]::Round($cwCost5m, 2)
        cacheWrite1h   = [math]::Round($cwCost1h, 2)
        cacheRead      = [math]::Round($crCost, 2)
        totalLow       = [math]::Round($totalLow, 2)
        totalHigh      = [math]::Round($totalHigh, 2)
        withModel      = $withModel
        withoutModel   = $withoutModel
    }

    # BY MODEL
    $modelAgg = @{}
    function Add-ModelAgg($name, $tokens, $subTokens, $c) {
        if (-not $modelAgg.ContainsKey($name)) {
            $modelAgg[$name] = [pscustomobject]@{ Tokens = 0L; Sub = 0L; Cost = 0.0 }
        }
        $modelAgg[$name].Tokens += [int64]$tokens
        $modelAgg[$name].Sub    += [int64]$subTokens
        $modelAgg[$name].Cost   += [double]$c
    }
    foreach ($row in $filtered) {
        if ($sessionModelMap.ContainsKey($row.session_id)) {
            foreach ($mr in $sessionModelMap[$row.session_id]) {
                $rt   = Get-ModelRates $mr.model
                $c    = ($mr.input * $rt.Input + $mr.output * $rt.Output + $mr.cache_creation * $rt.CacheWrite5m + $mr.cache_read * $rt.CacheRead) / 1e6
                $sub  = if ($mr.scope -eq 'subagent') { $mr.total } else { 0 }
                Add-ModelAgg $mr.model $mr.total $sub $c
            }
        } else {
            $c = Get-SessionCost5m $row $sessionModelMap $rates
            Add-ModelAgg "(no model data - $Pricing)" $row.total $row.subagent_total $c
        }
    }
    $byModel = @($modelAgg.GetEnumerator() | Sort-Object { $_.Value.Tokens } -Descending | ForEach-Object {
        $sp = if ($_.Value.Tokens -gt 0) { [math]::Round(100 * $_.Value.Sub / $_.Value.Tokens, 1) } else { 0 }
        [ordered]@{ name = $_.Key; tokens = $_.Value.Tokens; cost = [math]::Round($_.Value.Cost, 2); subPct = $sp }
    })

    # BY PROJECT (only meaningful when not already filtered to one project)
    $byProject = $null
    if (-not $Project) {
        $byProject = @($filtered | Group-Object project | Sort-Object { ($_.Group | Measure-Object total -Sum).Sum } -Descending | ForEach-Object {
            $g    = $_.Group
            $t    = ($g | Measure-Object total          -Sum).Sum
            $s    = ($g | Measure-Object subagent_total -Sum).Sum
            $sp   = if ($t -gt 0) { [math]::Round(100 * $s / $t, 1) } else { 0 }
            $sess = @($g).Count
            $c    = ($g | ForEach-Object { Get-SessionCost5m $_ $sessionModelMap $rates } | Measure-Object -Sum).Sum
            [ordered]@{ name = $_.Name; tokens = $t; cost = [math]::Round($c, 2); sessions = $sess; subPct = $sp }
        })
    }

    # BY DAY (fill zero-days across the full window, oldest -> newest)
    $byDayMap = @{}
    $filtered | Group-Object date | ForEach-Object {
        $c = ($_.Group | ForEach-Object { Get-SessionCost5m $_ $sessionModelMap $rates } | Measure-Object -Sum).Sum
        $byDayMap[$_.Name] = [pscustomobject]@{
            Sessions = @($_.Group).Count
            Total    = ($_.Group | Measure-Object total -Sum).Sum
            Cost     = $c
        }
    }
    $byDay = @()
    for ($i = $Days - 1; $i -ge 0; $i--) {
        $d = $today.AddDays(-$i).ToString('yyyy-MM-dd')
        if ($byDayMap.ContainsKey($d)) {
            $byDay += [ordered]@{ date = $d; tokens = $byDayMap[$d].Total; cost = [math]::Round($byDayMap[$d].Cost, 2); sessions = $byDayMap[$d].Sessions }
        } else {
            $byDay += [ordered]@{ date = $d; tokens = 0; cost = 0.0; sessions = 0 }
        }
    }

    # TOP SESSIONS
    $topSessionRows = @()
    if ($TopSessions -gt 0) {
        $topSessionRows = @($filtered | Sort-Object total -Descending | Select-Object -First $TopSessions | ForEach-Object {
            $sp = if ($_.total -gt 0) { [math]::Round(100 * $_.subagent_total / $_.total, 1) } else { 0 }
            $c  = Get-SessionCost5m $_ $sessionModelMap $rates
            [ordered]@{ date = $_.date; project = $_.project; tokens = $_.total; cost = [math]::Round($c, 2); subPct = $sp }
        })
    }

    $data = [ordered]@{
        meta         = $meta
        empty        = $false
        totals       = $totals
        cost         = $cost
        byModel      = $byModel
        byProject    = $byProject
        byDay        = $byDay
        topSessions  = $topSessionRows
    }
}

$dataJson = $data | ConvertTo-Json -Depth 8 -Compress

$html = @'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Claude Code token usage</title>
<style>
  :root {
    --page:           #f9f9f7;
    --surface-1:      #fcfcfb;
    --text-primary:   #0b0b0b;
    --text-secondary: #52514e;
    --text-muted:     #898781;
    --gridline:       #e1e0d9;
    --baseline:       #c3c2b7;
    --series-1:       #2a78d6;
    --series-1-wash:  rgba(42,120,214,0.10);
    --border:         rgba(11,11,11,0.10);
    --good:           #006300;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --page:           #0d0d0d;
      --surface-1:      #1a1a19;
      --text-primary:   #ffffff;
      --text-secondary: #c3c2b7;
      --text-muted:     #898781;
      --gridline:       #2c2c2a;
      --baseline:       #383835;
      --series-1:       #3987e5;
      --series-1-wash:  rgba(57,135,229,0.14);
      --border:         rgba(255,255,255,0.10);
      --good:           #0ca30c;
    }
  }
  * { box-sizing: border-box; }
  html, body {
    margin: 0;
    background: var(--page);
    color: var(--text-primary);
    font-family: system-ui, -apple-system, "Segoe UI", sans-serif;
  }
  body { padding: 24px; }
  .wrap { max-width: 1080px; margin: 0 auto; }
  header { margin-bottom: 24px; }
  h1 { font-size: 20px; margin: 0 0 4px; }
  .subtitle { color: var(--text-secondary); font-size: 13px; }
  .card {
    background: var(--surface-1);
    border: 1px solid var(--border);
    border-radius: 10px;
    padding: 20px;
    margin-bottom: 20px;
  }
  .card h2 {
    font-size: 13px;
    text-transform: uppercase;
    letter-spacing: 0.04em;
    color: var(--text-secondary);
    margin: 0 0 16px;
    display: flex;
    align-items: center;
    justify-content: space-between;
  }
  .stat-row {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
    gap: 16px;
  }
  .stat-tile .label { font-size: 12px; color: var(--text-secondary); margin-bottom: 6px; }
  .stat-tile .value { font-size: 26px; font-weight: 600; }
  .stat-tile .sub { font-size: 12px; color: var(--text-muted); margin-top: 4px; }
  .toggle-btn {
    font-size: 11px;
    color: var(--text-secondary);
    background: transparent;
    border: 1px solid var(--border);
    border-radius: 6px;
    padding: 3px 9px;
    cursor: pointer;
    font-family: inherit;
  }
  .toggle-btn:hover { color: var(--text-primary); border-color: var(--text-secondary); }
  .hbar-row { display: grid; grid-template-columns: 160px 1fr 96px; align-items: center; gap: 10px; margin-bottom: 6px; font-size: 13px; position: relative; }
  .hbar-label { color: var(--text-secondary); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .hbar-track { position: relative; height: 20px; }
  .hbar-fill { position: absolute; left: 0; top: 0; height: 20px; background: var(--series-1); border-radius: 4px; min-width: 2px; }
  .hbar-value { text-align: right; font-variant-numeric: tabular-nums; color: var(--text-primary); font-size: 12px; }
  .hbar-value .cost { color: var(--text-muted); margin-left: 4px; }
  .vbars { display: flex; align-items: flex-end; gap: 2px; height: 160px; padding-top: 8px; border-bottom: 1px solid var(--baseline); overflow-x: auto; }
  .vbar-col { flex: 1; display: flex; flex-direction: column; align-items: center; justify-content: flex-end; height: 100%; min-width: 4px; position: relative; }
  .vbar { width: 100%; max-width: 24px; background: var(--series-1); border-radius: 4px 4px 0 0; min-height: 2px; cursor: default; }
  .vbar-axis { display: flex; gap: 2px; margin-top: 6px; overflow-x: auto; }
  .vbar-axis-label { flex: 1; text-align: center; font-size: 10px; color: var(--text-muted); min-width: 4px; }
  .tooltip {
    position: fixed;
    pointer-events: none;
    background: var(--surface-1);
    border: 1px solid var(--border);
    border-radius: 6px;
    padding: 6px 10px;
    font-size: 12px;
    color: var(--text-primary);
    box-shadow: 0 4px 12px rgba(0,0,0,0.15);
    z-index: 10;
    display: none;
    white-space: nowrap;
  }
  table { width: 100%; border-collapse: collapse; font-size: 13px; }
  th, td { text-align: left; padding: 6px 10px; border-bottom: 1px solid var(--gridline); }
  th { color: var(--text-secondary); font-weight: 500; font-size: 11px; text-transform: uppercase; letter-spacing: 0.03em; }
  td.num, th.num { text-align: right; font-variant-numeric: tabular-nums; }
  .empty-state { text-align: center; padding: 60px 20px; color: var(--text-secondary); }
  .hidden { display: none !important; }
</style>
</head>
<body>
<div class="viz-root wrap">
  <header>
    <h1>Claude Code token usage</h1>
    <div class="subtitle" id="subtitle"></div>
  </header>
  <div id="content"></div>
</div>
<div class="tooltip" id="tooltip"></div>
<script>
const DATA = __DATA_JSON__;
const tooltip = document.getElementById('tooltip');

function showTip(evt, html) {
  tooltip.innerHTML = html;
  tooltip.style.display = 'block';
  tooltip.style.left = (evt.clientX + 12) + 'px';
  tooltip.style.top = (evt.clientY + 12) + 'px';
}
function hideTip() { tooltip.style.display = 'none'; }

function compact(n) {
  const abs = Math.abs(n);
  if (abs >= 1e9) return (n / 1e9).toFixed(1) + 'B';
  if (abs >= 1e6) return (n / 1e6).toFixed(1) + 'M';
  if (abs >= 1e3) return (n / 1e3).toFixed(1) + 'K';
  return n.toLocaleString();
}
function money(n) { return '$' + n.toLocaleString(undefined, {minimumFractionDigits: 2, maximumFractionDigits: 2}); }

function el(tag, cls, html) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (html !== undefined) e.innerHTML = html;
  return e;
}

function statTile(label, value, sub) {
  const t = el('div', 'stat-tile');
  t.appendChild(el('div', 'label', label));
  t.appendChild(el('div', 'value', value));
  if (sub) t.appendChild(el('div', 'sub', sub));
  return t;
}

// Horizontal ranked bar chart: items = [{label, value, valueLabel, tipHtml}]
function hbarChart(container, items) {
  const max = Math.max(1, ...items.map(i => i.value));
  items.forEach(item => {
    const row = el('div', 'hbar-row');
    row.appendChild(el('div', 'hbar-label', item.label));
    const track = el('div', 'hbar-track');
    const fill = el('div', 'hbar-fill');
    fill.style.width = Math.max(1, 100 * item.value / max) + '%';
    fill.addEventListener('mousemove', e => showTip(e, item.tipHtml || item.label));
    fill.addEventListener('mouseleave', hideTip);
    track.appendChild(fill);
    row.appendChild(track);
    row.appendChild(el('div', 'hbar-value', item.valueLabel));
    container.appendChild(row);
  });
}

// Vertical time-series bar chart: items = [{label, value, tipHtml}]
function vbarChart(container, items) {
  const max = Math.max(1, ...items.map(i => i.value));
  const bars = el('div', 'vbars');
  const axis = el('div', 'vbar-axis');
  const n = items.length;
  const labelEvery = n > 20 ? Math.ceil(n / 10) : (n > 10 ? 2 : 1);
  items.forEach((item, i) => {
    const col = el('div', 'vbar-col');
    const bar = el('div', 'vbar');
    bar.style.height = Math.max(1, 100 * item.value / max) + '%';
    bar.addEventListener('mousemove', e => showTip(e, item.tipHtml || item.label));
    bar.addEventListener('mouseleave', hideTip);
    col.appendChild(bar);
    bars.appendChild(col);
    const lbl = el('div', 'vbar-axis-label', (i % labelEvery === 0) ? item.label : '');
    axis.appendChild(lbl);
  });
  container.appendChild(bars);
  container.appendChild(axis);
}

function tableFromRows(headers, rows) {
  const t = el('table');
  const thead = el('thead');
  const htr = el('tr');
  headers.forEach(h => htr.appendChild(el(h.num ? 'th' : 'th', h.num ? 'num' : '', h.label)));
  thead.appendChild(htr);
  t.appendChild(thead);
  const tbody = el('tbody');
  rows.forEach(r => {
    const tr = el('tr');
    r.forEach((cell, i) => tr.appendChild(el('td', headers[i].num ? 'num' : '', cell)));
    tbody.appendChild(tr);
  });
  t.appendChild(tbody);
  return t;
}

function cardWithToggle(title, chartBuilder, tableBuilder) {
  const card = el('div', 'card');
  const h = el('h2');
  h.appendChild(document.createTextNode(title));
  const btn = el('button', 'toggle-btn', 'Table');
  h.appendChild(btn);
  card.appendChild(h);
  const chartDiv = el('div');
  const tableDiv = el('div', 'hidden');
  chartBuilder(chartDiv);
  tableDiv.appendChild(tableBuilder());
  card.appendChild(chartDiv);
  card.appendChild(tableDiv);
  let showingTable = false;
  btn.addEventListener('click', () => {
    showingTable = !showingTable;
    chartDiv.classList.toggle('hidden', showingTable);
    tableDiv.classList.toggle('hidden', !showingTable);
    btn.textContent = showingTable ? 'Chart' : 'Table';
  });
  return card;
}

function render() {
  const subtitle = document.getElementById('subtitle');
  const content = document.getElementById('content');
  const rangeLabel = DATA.meta.dateFrom + ' to ' + DATA.meta.dateTo + (DATA.meta.project ? ('  -  project=' + DATA.meta.project) : '');
  const periodLabel = DATA.meta.allTime ? 'All time' : ('Last ' + DATA.meta.days + ' day(s)');
  subtitle.textContent = periodLabel + '  (' + rangeLabel + ')  -  generated ' + DATA.meta.generatedAt;

  if (DATA.empty) {
    content.appendChild(el('div', 'card empty-state', 'No sessions in this window.'));
    return;
  }

  // Stat tiles
  const statsCard = el('div', 'card');
  const statsRow = el('div', 'stat-row');
  statsRow.appendChild(statTile('Total tokens', compact(DATA.totals.total), DATA.totals.sessions + ' sessions'));
  statsRow.appendChild(statTile('Estimated cost', money(DATA.cost.totalLow) + '-' + money(DATA.cost.totalHigh), DATA.meta.pricingLabel));
  statsRow.appendChild(statTile('Cache hit rate', DATA.totals.cacheHitPct + '%', 'read / (read+write)'));
  statsRow.appendChild(statTile('Subagent share', DATA.totals.subPct + '%', compact(DATA.totals.subTotal) + ' tokens'));
  statsCard.appendChild(statsRow);
  content.appendChild(statsCard);

  // Tokens by day
  const dayItems = DATA.byDay.map(d => ({
    label: d.date.slice(5),
    value: d.tokens,
    tipHtml: '<b>' + d.date + '</b><br>' + d.tokens.toLocaleString() + ' tokens<br>' + money(d.cost) + '  -  ' + d.sessions + ' sessions'
  }));
  content.appendChild(cardWithToggle('Tokens by day', c => vbarChart(c, dayItems), () =>
    tableFromRows(
      [{label:'Date'}, {label:'Tokens', num:true}, {label:'Est. cost', num:true}, {label:'Sessions', num:true}],
      DATA.byDay.map(d => [d.date, d.tokens.toLocaleString(), money(d.cost), d.sessions])
    )
  ));

  // Cost breakdown
  const costParts = [
    { label: 'Input', value: DATA.cost.input },
    { label: 'Output', value: DATA.cost.output },
    { label: 'Cache write (5m)', value: DATA.cost.cacheWrite5m },
    { label: 'Cache read', value: DATA.cost.cacheRead },
  ];
  const costItems = costParts.map(p => ({ label: p.label, value: p.value, valueLabel: money(p.value), tipHtml: p.label + ': ' + money(p.value) }));
  content.appendChild(cardWithToggle('Estimated cost breakdown', c => hbarChart(c, costItems), () =>
    tableFromRows(
      [{label:'Category'}, {label:'Est. cost', num:true}],
      costParts.map(p => [p.label, money(p.value)])
    )
  ));

  // By model
  const modelItems = DATA.byModel.map(m => ({
    label: m.name, value: m.tokens,
    valueLabel: compact(m.tokens) + '<span class="cost">' + money(m.cost) + '</span>',
    tipHtml: '<b>' + m.name + '</b><br>' + m.tokens.toLocaleString() + ' tokens<br>' + money(m.cost) + '  -  ' + m.subPct + '% subagent'
  }));
  content.appendChild(cardWithToggle('Tokens by model', c => hbarChart(c, modelItems), () =>
    tableFromRows(
      [{label:'Model'}, {label:'Tokens', num:true}, {label:'Est. cost', num:true}, {label:'Subagent %', num:true}],
      DATA.byModel.map(m => [m.name, m.tokens.toLocaleString(), money(m.cost), m.subPct + '%'])
    )
  ));

  // By project
  if (DATA.byProject) {
    const projItems = DATA.byProject.map(p => ({
      label: p.name, value: p.tokens,
      valueLabel: compact(p.tokens) + '<span class="cost">' + money(p.cost) + '</span>',
      tipHtml: '<b>' + p.name + '</b><br>' + p.tokens.toLocaleString() + ' tokens<br>' + money(p.cost) + '  -  ' + p.sessions + ' sessions  -  ' + p.subPct + '% subagent'
    }));
    content.appendChild(cardWithToggle('Tokens by project', c => hbarChart(c, projItems), () =>
      tableFromRows(
        [{label:'Project'}, {label:'Tokens', num:true}, {label:'Est. cost', num:true}, {label:'Sessions', num:true}, {label:'Subagent %', num:true}],
        DATA.byProject.map(p => [p.name, p.tokens.toLocaleString(), money(p.cost), p.sessions, p.subPct + '%'])
      )
    ));
  }

  // Top sessions (table only - no ranking chart adds value over the list itself)
  if (DATA.topSessions && DATA.topSessions.length) {
    const card = el('div', 'card');
    card.appendChild(el('h2', '', 'Top sessions by tokens'));
    card.appendChild(tableFromRows(
      [{label:'Date'}, {label:'Project'}, {label:'Tokens', num:true}, {label:'Est. cost', num:true}, {label:'Subagent %', num:true}],
      DATA.topSessions.map(s => [s.date, s.project, s.tokens.toLocaleString(), money(s.cost), s.subPct + '%'])
    ));
    content.appendChild(card);
  }
}

render();
</script>
</body>
</html>
'@

$html = $html.Replace('__DATA_JSON__', $dataJson)
[System.IO.File]::WriteAllText($outPath, $html, [System.Text.UTF8Encoding]::new($false))

Write-Host "Dashboard written to $outPath"
Start-Process $outPath
