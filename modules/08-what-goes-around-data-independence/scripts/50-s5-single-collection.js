// S5: the single-collection pattern through the MongoDB API.
//
// Stonebraker and Pavlo (section 2.2) say that with a key-value store
// "developers must implement joins or multi-get operations in their
// application". The single-collection design answers that: an order header
// and its line items are separate documents that share a partition key (pk)
// and sort by a sort key (sk). One find on pk, sorted on sk, returns the
// header first and then every line, from one item collection, through one
// index. No app-side join, no multi-get. This is vendor-neutral document
// modeling theory, not a feature of any one database.
//
// Seeds 3 orders (5, 10 and 25 lines) in a scrambled insert order, reads each
// one with a single request, checks the result, checks the plan, then drops
// the collection.

const NAME = 'm08s5_single';
const col = db.getCollection(NAME);
col.drop();
col.createIndex({ pk: 1, sk: 1 });

const ORDERS = [{ n: 7, k: 5 }, { n: 8, k: 10 }, { n: 9, k: 25 }];
const pkOf = (n) => 'ORD#' + n;
const lineSk = (j) => 'LINE#' + String(j).padStart(3, '0');
const skus = ['A1', 'B2', 'C3', 'D4'];

// Build every document, then insert them interleaved across orders, lines in
// descending order and headers last, so a correct read cannot come from
// insert order.
const docs = [];
for (const o of ORDERS) {
  const pk = pkOf(o.n);
  for (let j = o.k; j >= 1; j--) {
    docs.push({ _id: pk + '#' + lineSk(j), pk: pk, sk: lineSk(j), type: 'line',
                sku: skus[(o.n + j) % 4], qty: j });
  }
}
docs.sort((a, b) => (b.qty - a.qty) || (a.pk < b.pk ? -1 : 1));
for (const o of ORDERS) {
  docs.push({ _id: pkOf(o.n), pk: pkOf(o.n), sk: '#ORDER', type: 'order',
              customer: 'Customer ' + o.n, status: 'open', lineCount: o.k });
}
col.insertMany(docs);

// The read: exactly one request per order.
let requests = 0;
const readOrder = (pk) => { requests++; return col.find({ pk: pk }).sort({ sk: 1 }).toArray(); };
const results = {};
const requestsPerOrder = {};
for (const o of ORDERS) {
  const before = requests;
  results[o.n] = readOrder(pkOf(o.n));
  requestsPerOrder[o.n] = requests - before;
}

// s5-one-find-returns-all: one find returns the header plus all k lines.
const okAll = ORDERS.every((o) => requestsPerOrder[o.n] === 1 && results[o.n].length === 1 + o.k);
print('ASSERT:s5-one-find-returns-all:' + (okAll ? 'PASS' : 'FAIL'));

// s5-types: exactly one order header and k lines.
const okTypes = ORDERS.every((o) => {
  const r = results[o.n];
  return r.filter((d) => d.type === 'order').length === 1 &&
         r.filter((d) => d.type === 'line').length === o.k;
});
print('ASSERT:s5-types:' + (okTypes ? 'PASS' : 'FAIL'));

// s5-sorted: the database's sort on sk puts "#ORDER" before every "LINE#..."
// key (checked, not assumed), and the lines come back LINE#001 .. LINE#k.
const okSorted = ORDERS.every((o) => {
  const r = results[o.n];
  if (r.length !== 1 + o.k || r[0].sk !== '#ORDER' || r[0].type !== 'order') return false;
  for (let j = 1; j <= o.k; j++) {
    if (r[j].sk !== lineSk(j) || !(r[j - 1].sk < r[j].sk)) return false;
  }
  return true;
});
print('ASSERT:s5-sorted:' + (okSorted ? 'PASS' : 'FAIL'));

// s5-index-used: the Oracle plan reads the pk/sk index by range scan, with no
// full scan of the table or the index.
const qp = col.find({ pk: pkOf(9) }).sort({ sk: 1 }).explain().queryPlanner;
print('generatedSql: ' + qp.generatedSql);
const plan = String(qp.winningPlan || '');
plan.split('\n').filter((l) => /^\|/.test(l)).forEach((l) => print('plan: ' + l));
const okIndex = /INDEX RANGE SCAN/.test(plan) && plan.includes(NAME + '.pk_1_sk_1') &&
                !/FULL/.test(plan);
print('ASSERT:s5-index-used:' + (okIndex ? 'PASS' : 'FAIL'));

// s5-no-cross-talk: a find for one pk returns only that order's documents.
const okNoCross = ORDERS.every((o) =>
  results[o.n].length > 0 && results[o.n].every((d) => d.pk === pkOf(o.n) && d._id.startsWith(pkOf(o.n))));
print('ASSERT:s5-no-cross-talk:' + (okNoCross ? 'PASS' : 'FAIL'));

print('METRIC:s5-requests:' + requestsPerOrder[9]);
print('METRIC:s5-docs-returned-k25:' + results[9].length);

col.drop();
const clean = !db.getCollectionNames().includes(NAME);
print('ASSERT:s5-teardown-clean:' + (clean ? 'PASS' : 'FAIL'));
