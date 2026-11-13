// S3 at scale (B): measure the unchanged app statements at the current stage.
// 61, 64, 66 and 68 are byte-identical (63 checks this). The script works out
// which storage stage it is looking at from the schema, so the app code never
// changes.
//
// For each of the six app statements below, at this stage:
//   1. explain() through the MongoDB API: the SQL the API generated, its
//      sql_id and the optimizer's plan;
//   2. purge that sql_id's cursors, so each statement is parsed for its own
//      bind value (SKU-HOT and SKU-RARE share one SQL text and would otherwise
//      share whichever plan was parsed first);
//   3. one warm-up run (its result is kept and compared across stages);
//   4. 20 measured runs, each fetching every result document;
//   5. the growth of v$sql for that sql_id over the 20 runs, divided by 20:
//      buffer gets (logical reads), CPU and elapsed time per call. These are
//      database-side numbers only: they leave out the API tier and the network;
//   6. purge again and run once more with statistics_level = ALL in the API's
//      database session, then dbms_xplan.display_cursor(sql_id, child,
//      'ALLSTATS LAST'): the executed plan, with rows and buffers per step.
//      Its plan hash must equal the measured cursor's.
// The measuring window is the delta over all child cursors of that sql_id.
//
// Direct-SQL controls (not app statements, so not compared across stages):
// at stage 1, the API's own JSON predicates run straight against the table's
// JSON column, to see whether the indexes on it can be used without the view;
// at stage 3, a GROUP BY and a sku lookup run straight against the lines table,
// to show what the move makes possible for new SQL.
//
// Results: each statement's normalized result is hashed and stored in
// m08b3_runs. normalize() strips _metadata, sorts object keys, renders every
// number with Number(), and sorts every array (array order excluded: the result
// order of a find without sort and of a $group is not part of the answer, and
// a duality view cannot order a nested array). Each stage must match stage 0.
//
// Checks: same results as stage 0, a plan captured for every statement, every
// measured cursor executed at least once per call, and the executed plan has
// the same plan hash as the measured cursor. No check compares costs: the
// costs are reported, not asserted.

const NAME = 'm08b3_orders';
const RUNS = 20;
const crypto = require('crypto');
const col = db.getCollection(NAME);
const runs = db.getCollection('m08b3_runs');
const sql = (statement, binds) =>
  db.aggregate([{ $sql: binds ? { statement: statement, binds: binds } : statement }]).toArray();
const bind1 = (v) => [{ index: 1, value: v }];

function normalize(x) {
  if (x === null || x === undefined) return null;
  if (Array.isArray(x)) {
    return x.map(normalize).map((e) => [JSON.stringify(e), e])
      .sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0)).map((p) => p[1]);
  }
  if (typeof x === 'number' || typeof x === 'bigint') return Number(x);
  if (typeof x === 'object') {
    if (['Int32', 'Long', 'Double', 'Decimal128'].includes(x._bsontype)) return Number(x.toString());
    const out = {};
    for (const k of Object.keys(x).sort()) {
      if (k === '_metadata') continue;
      out[k] = normalize(x[k]);
    }
    return out;
  }
  return x;
}
const digest = (rows) => crypto.createHash('sha256').update(JSON.stringify(normalize(rows))).digest('hex');

// The app's statements, written once and never edited.
const STMTS = [
  { name: 'byid',       q: () => col.find({ _id: 12345 }),
                        x: () => col.find({ _id: 12345 }).explain() },
  { name: 'status',     q: () => col.find({ status: 'open' }),
                        x: () => col.find({ status: 'open' }).explain() },
  { name: 'sku-hot',    q: () => col.find({ 'items.sku': 'SKU-HOT' }),
                        x: () => col.find({ 'items.sku': 'SKU-HOT' }).explain() },
  { name: 'sku-rare',   q: () => col.find({ 'items.sku': 'SKU-RARE' }),
                        x: () => col.find({ 'items.sku': 'SKU-RARE' }).explain() },
  { name: 'agg-status', p: [{ $match: { status: 'open' } }, { $group: { _id: '$customer', n: { $sum: 1 } } }] },
  { name: 'agg-unwind', p: [{ $unwind: '$items' }, { $group: { _id: '$items.sku', q: { $sum: '$items.qty' } } }] }
];
for (const s of STMTS) {
  if (s.p) { s.q = () => col.aggregate(s.p); s.x = () => col.explain().aggregate(s.p); }
}

// Direct-SQL controls per stage. Each text starts with a tag that finds it in v$sql.
const ctl = (name, text, bind) => ({ name: name, tag: '/* s3b-ctl-' + name + ' */',
  text: 'select /* s3b-ctl-' + name + ' */ ' + text, binds: bind === undefined ? null : bind1(bind) });
const CONTROLS = {
  1: [ctl('status', `t.data from m08b3_orders_t t
                      where json_exists(t.data, '$?(@.status.stringOnly() == $B0)' passing :1 as "B0" type(strict))`, 'open'),
      ctl('status-jv', `t.data from m08b3_orders_t t where json_value(t.data, '$.status') = :1`, 'open'),
      ctl('sku-rare', `t.data from m08b3_orders_t t
                        where json_exists(t.data, '$?(@.items.sku.stringOnly() == $B0)' passing :1 as "B0" type(strict))`, 'SKU-RARE'),
      ctl('sku-rare-mv', `t.data from m08b3_orders_t t
                           where json_exists(t.data, '$.items[*]?(@.sku.string() == $B0)' passing :1 as "B0")`, 'SKU-RARE')],
  3: [ctl('group', `sku, sum(qty) q from m08b3_lines group by sku`),
      ctl('lines-rare', `line_id, order_id, sku, qty from m08b3_lines where sku = :1`, 'SKU-RARE')]
};

// Which stage is under the collection name?
const st = sql(`select (select count(*) from user_objects
                         where object_name = 'm08b3_orders' and object_type = 'VIEW') v,
                       (select count(*) from user_tab_columns
                         where table_name = 'M08B3_ORDERS_T' and column_name = 'STATUS') s,
                       (select count(*) from user_tables where table_name = 'M08B3_LINES') l
                  from dual`)[0];
const STAGE = Number(st.V) === 0 ? 0 : Number(st.L) > 0 ? 3 : Number(st.S) > 0 ? 2 : 1;
print('stage ' + STAGE);

// Histograms on the indexed columns (the move scripts gather them explicitly).
const hist = sql(`select i.index_name, i.table_name, i.column_name, nvl(s.histogram, 'NONE') histogram
                    from user_ind_columns i
                    left join user_tab_col_statistics s
                      on s.table_name = i.table_name and s.column_name = i.column_name
                   where i.table_name in ('m08b3_orders', 'M08B3_ORDERS_T', 'M08B3_LINES')
                   order by i.table_name, i.index_name`);
print('histograms: ' + JSON.stringify(hist));
for (const h of hist) {
  if (/^M08B3_/.test(h.INDEX_NAME)) {
    print('METRIC:s3b-stage' + STAGE + '-hist-' + h.INDEX_NAME.toLowerCase().replace(/_/g, '-') + ':' +
          (h.HISTOGRAM === 'NONE' ? 0 : 1));
  }
}

const vsql = (id) => sql(`select nvl(sum(executions), 0) e, nvl(sum(buffer_gets), 0) g,
                                 nvl(sum(cpu_time), 0) c, nvl(sum(elapsed_time), 0) t
                            from v$sql where sql_id = :1`, bind1(id))[0];
const children = (id) => sql(`select child_number, to_char(plan_hash_value) phv, executions
                                from v$sql where sql_id = :1 order by child_number`, bind1(id));
const purge = (id) => sql(`begin
  for c in (select address || ',' || hash_value n from v$sql where sql_id = '${id}') loop
    sys.dbms_shared_pool.purge(c.n, 'C');
  end loop;
end;`);
const grew = (before, after) => {
  // the child whose executions grew the most between two children() snapshots
  let best = null;
  for (const a of after) {
    const b = before.find((x) => x.CHILD_NUMBER === a.CHILD_NUMBER);
    const d = Number(a.EXECUTIONS) - (b ? Number(b.EXECUTIONS) : 0);
    if (d > 0 && (!best || d > best.d)) best = { child: Number(a.CHILD_NUMBER), phv: a.PHV, d: d };
  }
  return best;
};

// Measure one statement: purge, warm up, 20 runs, then one ALLSTATS run.
function measure(label, id, run) {
  purge(id);
  const rows = run();
  const c0 = children(id);
  const b = vsql(id);
  for (let i = 0; i < RUNS; i++) run();
  const a = vsql(id);
  const c1 = children(id);
  // Row-source statistics are only collected by a cursor parsed with
  // statistics_level = ALL, so purge again and parse it fresh, same bind value.
  purge(id);
  sql('alter session set statistics_level = all');
  try { run(); } finally { sql('alter session set statistics_level = typical'); }
  const c2 = children(id);
  const measured = grew(c0, c1);
  const statsRun = grew([], c2);
  const xplan = statsRun ? sql(`select plan_table_output l from
                                  table(dbms_xplan.display_cursor('${id}', ${statsRun.child}, 'ALLSTATS LAST'))`)
                             .map((r) => r.L).join('\n') : '';
  const per = (k) => (Number(a[k]) - Number(b[k])) / RUNS;
  const m = { rows: rows, execs: Number(a.E) - Number(b.E), gets: per('G'),
              cpuUs: Math.round(per('C')), elaUs: Math.round(per('T')), xplan: xplan,
              measuredPhv: measured ? measured.phv : null, xplanPhv: statsRun ? statsRun.phv : null };
  print('---- ' + label + ' stage ' + STAGE + ': ' + rows.length + ' rows, sqlid ' + id +
        ', execs/call ' + (m.execs / RUNS) + ', gets/call ' + m.gets + ', cpu-us/call ' + m.cpuUs +
        ', ela-us/call ' + m.elaUs + ', measured plan hash ' + m.measuredPhv + ', executed-plan hash ' + m.xplanPhv);
  print('executed plan (ALLSTATS LAST):\n' + xplan);
  print('METRIC:s3b-' + label + '-stage' + STAGE + '-gets:' + m.gets.toFixed(1));
  print('METRIC:s3b-' + label + '-stage' + STAGE + '-cpu-us:' + m.cpuUs);
  print('METRIC:s3b-' + label + '-stage' + STAGE + '-ela-us:' + m.elaUs);
  return m;
}

const rec = { _id: 'stage' + STAGE, stage: STAGE, stmts: {}, controls: {} };
let plansOk = true;
let measuredOk = true;
let xplanOk = true;
for (const s of STMTS) {
  const qp = s.x().queryPlanner || {};
  const sqlid = qp.sqlid || '';
  const gen = qp.generatedSql || '';
  const plan = typeof qp.winningPlan === 'string' ? qp.winningPlan : JSON.stringify(qp.winningPlan || '');
  if (!sqlid || !gen.trim() || !plan.trim()) plansOk = false;
  print('==== ' + s.name + ' stage ' + STAGE + ' generatedSql:\n' + gen + '\nexplain plan:\n' + plan);

  const m = measure(s.name, sqlid, () => s.q().toArray());
  if (m.execs < RUNS) measuredOk = false;
  if (!/Buffers/.test(m.xplan) || m.measuredPhv === null || m.measuredPhv !== m.xplanPhv) xplanOk = false;
  rec.stmts[s.name] = { count: m.rows.length, digest: digest(m.rows), sqlid: sqlid, generatedSql: gen,
                        plan: plan, xplan: m.xplan, gets: m.gets, cpuUs: m.cpuUs, elaUs: m.elaUs };
}

for (const c of CONTROLS[STAGE] || []) {
  const run = () => sql(c.text, c.binds);
  run();
  const found = sql(`select sql_id from v$sql where sql_text like :1 and rownum = 1`, bind1('select ' + c.tag + '%'));
  if (!found.length) { print('control ' + c.name + ': sql_id not found'); measuredOk = false; continue; }
  const m = measure('ctl-' + c.name, found[0].SQL_ID, run);
  if (m.execs < RUNS || !/Buffers/.test(m.xplan)) measuredOk = false;
  rec.controls[c.name] = { text: c.text, rows: m.rows.length, gets: m.gets, cpuUs: m.cpuUs, xplan: m.xplan };
}

rec.plansOk = plansOk && xplanOk;
rec.measuredOk = measuredOk;
runs.deleteOne({ _id: rec._id });
runs.insertOne(rec);

print('ASSERT:s3b-stage' + STAGE + '-plans-captured:' + (plansOk ? 'PASS' : 'FAIL'));
print('ASSERT:s3b-stage' + STAGE + '-executed-plan-matches:' + (xplanOk ? 'PASS' : 'FAIL'));
print('ASSERT:s3b-stage' + STAGE + '-measured:' + (measuredOk ? 'PASS' : 'FAIL'));

// Same results as stage 0, statement by statement.
const base = runs.findOne({ _id: 'stage0' });
let same = base !== null;
for (const s of STMTS) {
  const b0 = base && base.stmts[s.name];
  const now = rec.stmts[s.name];
  const ok = !!b0 && b0.digest === now.digest && Number(b0.count) === now.count && now.count > 0;
  if (!ok) print('differs from stage 0: ' + s.name + ' (' + (b0 ? b0.count : '?') + ' vs ' + now.count + ')');
  same = same && ok;
}
print('ASSERT:s3b-stage' + STAGE + '-same-results:' + (same ? 'PASS' : 'FAIL'));

// Negative check: a changed result must not hash the same.
const one = col.find({ _id: 12345 }).toArray();
const changed = JSON.parse(JSON.stringify(normalize(one)));
changed[0].ship.city = changed[0].ship.city + 'X';
print('ASSERT:s3b-stage' + STAGE + '-normalizer-detects-change:' +
      (digest(changed) !== digest(one) ? 'PASS' : 'FAIL'));
