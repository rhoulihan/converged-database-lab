// Writes (D), through the MongoDB API: knob 3 as an app would write it.
// The same one-line change as 70-writes.sql part 2 (one line's qty in a
// 1,000-line order), sent as updateOne with a positional $set:
//   col : on a JSON collection table   (M08D_API_DOC)
//   dv  : on a duality view over orders + lines (M08D_API_DV)
// Each target: one warm-up call, then 20 measured calls, each setting a new qty.
//
// Two measuring windows around the 20 calls:
//   1. v$sql: the growth of every cursor whose text names the target's objects
//      (the API's generated SQL and, for the view, its per-row statements),
//      shown per statement, per statement class (METRIC) and summed:
//      executions, buffer gets (logical reads) and CPU per call. The cursors
//      are purged first. Database side only: no API tier, no network.
//   2. v$mystat, read with $sql in the API's own database session (checked: the
//      SID is the same before and after the 20 calls): logical reads, redo and
//      CPU per call for the whole session, the snapshot query's own cost
//      removed (an empty window, measured the same way). If the SID changed,
//      this window is not reported.
// Objects are created and dropped here with $sql; prefix M08D_API_.
// Checks (correctness only): the change is visible through the API and in SQL
// for both targets, the other 999 lines are unchanged, and every call matched
// and modified one document. No check compares costs.

const RUNS = 20;
const LINE = 1500; // line 500 of order 1
const sql = (statement, binds) =>
  db.aggregate([{ $sql: binds ? { statement: statement, binds: binds } : statement }]).toArray();
const bind1 = (v) => [{ index: 1, value: v }];
const DROP = ['drop view if exists m08d_api_dv', 'drop table if exists m08d_api_line purge',
              'drop table if exists m08d_api_ord purge', 'drop table if exists m08d_api_doc purge'];

// ===== Setup =====
for (const s of DROP) sql(s);
sql(`create table m08d_api_ord (ord_id number constraint m08d_api_ord_pk primary key,
       cust_id number not null, status varchar2(12) not null, total number not null)`);
sql(`create table m08d_api_line (line_id number constraint m08d_api_line_pk primary key,
       ord_id number not null constraint m08d_api_line_ord_fk references m08d_api_ord,
       sku varchar2(20) not null, qty number not null)`);
sql('create index m08d_api_line_ord_ix on m08d_api_line (ord_id)');
sql(`create json relational duality view m08d_api_dv as
     select json {'_id' : o.ord_id, 'custId' : o.cust_id, 'status' : o.status, 'total' : o.total,
                  'lines' : [ select json {'lineId' : l.line_id, 'sku' : l.sku, 'qty' : l.qty}
                                from m08d_api_line l with insert update delete
                               where l.ord_id = o.ord_id ]}
       from m08d_api_ord o with insert update delete`);
sql('create json collection table m08d_api_doc');
// Order 1 has 1,000 lines; orders 2 to 1001 have 10 each (as in 70-writes.sql).
sql(`insert into m08d_api_ord select level, mod(level, 50) + 1, 'OPEN', level * 10
       from dual connect by level <= 1001`);
sql(`insert into m08d_api_line select 1000 + level, 1, 'SKU-' || mod(level * 7, 97), mod(level, 5) + 1
       from dual connect by level <= 1000`);
sql(`insert into m08d_api_line select o.ord_id * 1000 + n.i, o.ord_id, 'SKU-' || mod(n.i * 7, 97), mod(n.i, 5) + 1
       from (select level + 1 ord_id from dual connect by level <= 1000) o,
            (select level i from dual connect by level <= 10) n`);
sql(`insert into m08d_api_doc (data)
     select json_object('_id' value o.ord_id, 'custId' value o.cust_id, 'status' value o.status,
                        'total' value o.total,
                        'lines' value (select json_arrayagg(json_object('lineId' value l.line_id,
                                                                        'sku' value l.sku, 'qty' value l.qty)
                                                            order by l.line_id returning json)
                                         from m08d_api_line l where l.ord_id = o.ord_id)
                        returning json)
       from m08d_api_ord o order by o.ord_id`);
sql('commit');
sql(`begin
  for t in (select table_name from user_tables where table_name like 'M08D\\_API\\_%' escape '\\') loop
    dbms_stats.gather_table_stats(user, t.table_name, cascade => true, no_invalidate => false);
  end loop;
end;`);

// ===== Measuring helpers =====
const sid = () => String(sql(`select sys_context('userenv', 'sid') s from dual`)[0].S);
const mystat = () => {
  const r = {};
  for (const x of sql(`select sn.name n, ms.value v from v$mystat ms join v$statname sn
                         on sn.statistic# = ms.statistic#
                        where sn.name in ('session logical reads', 'redo size', 'CPU used by this session')`)) {
    r[x.N] = Number(x.V);
  }
  return r;
};
// Every cursor naming the target's objects, except this script's own queries.
const cursors = (pat) => sql(`select sql_id, child_number c, executions e, buffer_gets g, cpu_time t,
                                     sql_text txt
                                from v$sql
                               where upper(sql_text) like :1
                                 and upper(sql_text) not like '%V$SQL%'
                                 and upper(sql_text) not like '%V$MYSTAT%'
                                 and upper(sql_text) not like 'CREATE %'
                                 and upper(sql_text) not like 'INSERT INTO M08D%'
                                 and upper(sql_text) not like 'DROP %'`, bind1(pat));
const key = (x) => x.SQL_ID + '/' + x.C;
// Purge the target's cursors first, so their counts start fresh (a cursor
// reloaded after an earlier run's DROP would otherwise mis-count).
// A purge that fails is not fatal (the counts are deltas), but it is made
// visible: the cursors still left afterwards are reported as
// wr-api-<target>-purge-left (0 when every purge worked).
const purge = (pat) => {
  sql(`begin
  for c in (select distinct address || ',' || hash_value n from v$sql
             where upper(sql_text) like '${pat}' and upper(sql_text) not like '%V$SQL%') loop
    begin sys.dbms_shared_pool.purge(c.n, 'C'); exception when others then null; end;
  end loop;
end;`);
  return Number(sql(`select count(*) n from v$sql
                      where upper(sql_text) like :1 and upper(sql_text) not like '%V$SQL%'`, bind1(pat))[0].N);
};
// The schema the API works in (the line table's owner in the generated SQL).
const SCHEMA = sql(`select sys_context('userenv', 'current_schema') s from dual`)[0].S;
const LINE_UPDATE = new RegExp('^update "' + SCHEMA + '"\\."M08D_API_LINE"', 'i');
// Statement class, for one METRIC per kind of statement the API ran.
const cls = (t) => /for update/i.test(t) ? 'select-for-update'
  : /DRDUALV/.test(t) ? 'etag-select-dr'
  : /DUALV/.test(t) ? 'etag-select'
  : LINE_UPDATE.test(t) ? 'update-line'
  : /^update/i.test(t) ? 'update-doc'
  : 'other';
const diff = (b, a, k) => Number(a[k]) - Number(b[k]);

function measure(label, coll, pat) {
  const C = db.getCollection(coll);
  const results = [];
  const upd = (q) => C.updateOne({ _id: 1, 'lines.lineId': LINE }, { $set: { 'lines.$.qty': q } });
  const purgeLeft = purge(pat);
  print('METRIC:wr-api-' + label + '-purge-left:' + purgeLeft);
  results.push(upd(500)); // warm-up
  // Empty window: the snapshot queries alone.
  const e0 = mystat();
  const e1 = mystat();
  const s0 = sid();
  const c0 = cursors(pat);
  const m0 = mystat();
  for (let i = 1; i <= RUNS; i++) results.push(upd(500 + i));
  const m1 = mystat();
  const c1 = cursors(pat);
  const s1 = sid();
  const same = s0 === s1 ? 1 : 0;

  // Per-statement growth over the 20 calls.
  const before = {};
  for (const x of c0) before[key(x)] = x;
  let gets = 0, cpu = 0, stmts = 0;
  const byCls = {};
  print('---- ' + label + ': statements that ran during the ' + RUNS + ' calls');
  for (const x of c1) {
    const b = before[key(x)] || { E: 0, G: 0, T: 0 };
    const de = diff(b, x, 'E');
    if (de <= 0) continue;
    stmts += 1;
    gets += diff(b, x, 'G');
    cpu += diff(b, x, 'T');
    const k = cls(String(x.TXT).trim());
    byCls[k] = byCls[k] || { e: 0, g: 0 };
    byCls[k].e += de;
    byCls[k].g += diff(b, x, 'G');
    print('  ' + x.SQL_ID + ' child ' + x.C + ': execs/call ' + (de / RUNS) + ', gets/call ' +
          (diff(b, x, 'G') / RUNS).toFixed(1) + ', cpu-us/call ' + Math.round(diff(b, x, 'T') / RUNS) +
          '\n     ' + String(x.TXT).replace(/\s+/g, ' ').slice(0, 200));
  }
  const ov = (k) => e1[k] - e0[k];
  const per = (k) => Math.max((m1[k] - m0[k]) - ov(k), 0) / RUNS;
  print('---- ' + label + ': sid ' + s0 + ' -> ' + s1 + ', session reads/call ' + per('session logical reads') +
        ', redo/call ' + per('redo size') + ', cpu-cs/call ' + per('CPU used by this session') +
        ' (snapshot overhead reads ' + ov('session logical reads') + ', redo ' + ov('redo size') + ')');
  print('METRIC:wr-api-' + label + '-statements:' + stmts);
  for (const k of Object.keys(byCls).sort()) {
    print('METRIC:wr-api-' + label + '-' + k + '-execs-per-call:' + (byCls[k].e / RUNS).toFixed(2));
    print('METRIC:wr-api-' + label + '-' + k + '-gets-per-call:' + (byCls[k].g / RUNS).toFixed(1));
  }
  print('METRIC:wr-api-' + label + '-vsql-gets-per-call:' + (gets / RUNS).toFixed(1));
  print('METRIC:wr-api-' + label + '-vsql-cpu-us-per-call:' + Math.round(cpu / RUNS));
  print('METRIC:wr-api-' + label + '-same-session:' + same);
  if (same === 1) {
    print('METRIC:wr-api-' + label + '-session-reads-per-call:' + per('session logical reads').toFixed(1));
    print('METRIC:wr-api-' + label + '-session-redo-per-call:' + Math.round(per('redo size')));
    print('METRIC:wr-api-' + label + '-session-cpu-cs-per-call:' + per('CPU used by this session').toFixed(2));
  }
  return { results: results, stmts: stmts, byCls: byCls };
}

// ===== Measure =====
const col = measure('col', 'M08D_API_DOC', '%"M08D_API_DOC"%');
const dv = measure('dv', 'M08D_API_DV', '%"M08D_API_%');

// ===== Checks =====
const allOne = (rs) => rs.length === RUNS + 1 && rs.every((r) => Number(r.matchedCount) === 1 && Number(r.modifiedCount) === 1);
const lineQty = (coll, id) => {
  const d = db.getCollection(coll).findOne({ _id: 1 });
  const l = d.lines.find((x) => Number(x.lineId) === id);
  return { qty: l ? Number(l.qty) : null, n: d.lines.length,
           others: d.lines.filter((x) => Number(x.lineId) !== LINE)
                          .every((x) => Number(x.qty) === (Number(x.lineId) - 1000) % 5 + 1) };
};
const c = lineQty('M08D_API_DOC', LINE);
const v = lineQty('M08D_API_DV', LINE);
const tab = Number(sql('select qty q from m08d_api_line where line_id = :1', bind1(LINE))[0].Q);
const doc = Number(sql(`select jt.qty q from m08d_api_doc d,
                          json_table(d.data, '$.lines[*]' columns (l number path '$.lineId', qty number path '$.qty')) jt
                         where d.data."_id" = 1 and jt.l = :1`, bind1(LINE))[0].Q);
const last = 500 + RUNS;
const visible = c.qty === last && v.qty === last && tab === last && doc === last &&
                c.n === 1000 && v.n === 1000 && c.others && v.others;
print('check: col qty ' + c.qty + ', dv qty ' + v.qty + ', table ' + tab + ', sql doc ' + doc +
      ', lines ' + c.n + '/' + v.n + ', others unchanged ' + c.others + '/' + v.others);
print('ASSERT:wr-api-one-doc-per-call:' + (allOne(col.results) && allOne(dv.results) ? 'PASS' : 'FAIL'));
print('ASSERT:wr-api-change-visible:' + (visible ? 'PASS' : 'FAIL'));
// The collection runs 2 statements (read for update, write); the view 5 (read
// for update, two etag reads, the line update, the view update).
print('ASSERT:wr-api-statements-found:' + (col.stmts === 2 && dv.stmts === 5 ? 'PASS' : 'FAIL'));

// ===== Teardown =====
for (const s of DROP) sql(s);
const left = Number(sql(`select count(*) n from user_objects where upper(object_name) like 'M08D\\_API\\_%' escape '\\'`)[0].N);
print('ASSERT:wr-api-teardown-clean:' + (left === 0 ? 'PASS' : 'FAIL'));
