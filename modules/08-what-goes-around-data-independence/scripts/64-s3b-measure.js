// S3 at scale (B): measure the unchanged app statements at the current stage.
// 61, 64, 66 and 68 are byte-identical. The script works out which storage
// stage it is looking at from the schema, so the app code never changes.
//
// For each of the six app statements below, at this stage:
//   1. explain() through the MongoDB API: the SQL the API generated, its
//      sql_id and the plan;
//   2. one warm-up run (its result is kept and compared across stages);
//   3. 20 measured runs, each fetching every result document;
//   4. the growth of v$sql for that sql_id over the 20 runs, divided by 20:
//      buffer gets (logical reads), CPU and elapsed time per call.
// The whole window is the delta over all child cursors of that sql_id, so a
// new child cursor (same SQL text over a new object) is still counted.
//
// Results: each statement's normalized result is hashed and stored in
// m08b3_runs. normalize() strips _metadata, sorts object keys, renders every
// number with Number(), and sorts every array (array order excluded: the result
// order of a find without sort and of a $group is not part of the answer, and
// a duality view cannot order a nested array). Each stage must match stage 0.
//
// Checks: same results as stage 0, a plan captured for every statement, and
// every measured cursor executed at least once per call. No check compares
// costs: the costs are reported, not asserted.

const NAME = 'm08b3_orders';
const RUNS = 20;
const crypto = require('crypto');
const col = db.getCollection(NAME);
const runs = db.getCollection('m08b3_runs');
const sql = (statement, binds) =>
  db.aggregate([{ $sql: binds ? { statement: statement, binds: binds } : statement }]).toArray();

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

// Which stage is under the collection name?
const st = sql(`select (select count(*) from user_objects
                         where object_name = 'm08b3_orders' and object_type = 'VIEW') v,
                       (select count(*) from user_tab_columns
                         where table_name = 'M08B3_ORDERS_T' and column_name = 'STATUS') s,
                       (select count(*) from user_tables where table_name = 'M08B3_LINES') l
                  from dual`)[0];
const STAGE = Number(st.V) === 0 ? 0 : Number(st.L) > 0 ? 3 : Number(st.S) > 0 ? 2 : 1;
print('stage ' + STAGE);

const vsql = (id) => sql(`select nvl(sum(executions), 0) e, nvl(sum(buffer_gets), 0) g,
                                 nvl(sum(cpu_time), 0) c, nvl(sum(elapsed_time), 0) t
                            from v$sql where sql_id = :1`, [{ index: 1, value: id }])[0];

const rec = { _id: 'stage' + STAGE, stage: STAGE, stmts: {} };
let plansOk = true;
let measuredOk = true;
for (const s of STMTS) {
  const qp = s.x().queryPlanner || {};
  const sqlid = qp.sqlid || '';
  const gen = qp.generatedSql || '';
  const plan = typeof qp.winningPlan === 'string' ? qp.winningPlan : JSON.stringify(qp.winningPlan || '');
  if (!sqlid || !gen.trim() || !plan.trim()) plansOk = false;

  const rows = s.q().toArray();
  const b = vsql(sqlid);
  for (let i = 0; i < RUNS; i++) s.q().toArray();
  const a = vsql(sqlid);
  const execs = Number(a.E) - Number(b.E);
  if (execs < RUNS) measuredOk = false;
  const per = (k) => (Number(a[k]) - Number(b[k])) / RUNS;
  const m = { count: rows.length, digest: digest(rows), sqlid: sqlid, generatedSql: gen, plan: plan,
              execsPerCall: execs / RUNS, gets: per('G'), cpuUs: Math.round(per('C')), elaUs: Math.round(per('T')) };
  rec.stmts[s.name] = m;

  const children = sql(`select child_number, to_char(plan_hash_value) plan_hash_value, executions, buffer_gets
                          from v$sql where sql_id = :1 order by child_number`, [{ index: 1, value: sqlid }]);
  print('---- ' + s.name + ' stage ' + STAGE + ': ' + m.count + ' docs, sqlid ' + sqlid +
        ', execs/call ' + m.execsPerCall + ', gets/call ' + m.gets + ', cpu-us/call ' + m.cpuUs +
        ', ela-us/call ' + m.elaUs);
  print('children: ' + JSON.stringify(children));
  print('generatedSql:\n' + gen);
  print('plan:\n' + plan);
  print('METRIC:s3b-' + s.name + '-stage' + STAGE + '-gets:' + m.gets.toFixed(1));
  print('METRIC:s3b-' + s.name + '-stage' + STAGE + '-cpu-us:' + m.cpuUs);
  print('METRIC:s3b-' + s.name + '-stage' + STAGE + '-ela-us:' + m.elaUs);
}

rec.plansOk = plansOk;
rec.measuredOk = measuredOk;
runs.deleteOne({ _id: rec._id });
runs.insertOne(rec);

print('ASSERT:s3b-stage' + STAGE + '-plans-captured:' + (plansOk ? 'PASS' : 'FAIL'));
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
