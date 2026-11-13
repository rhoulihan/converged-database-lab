// S3 at scale (B), stage 0: m08b3_orders as a plain MongoDB API collection.
//
// S3 (scripts 01 to 08) proves that the same app code gets the same results
// while the storage moves, on 8 orders, and measures no cost. S3 (B) repeats
// the same four storage stages on a separate, larger collection and measures
// what each unchanged app statement costs at each stage (scripts 61 to 69).
//
// This script seeds the collection through the MongoDB API, the way the app
// would: 20,000 orders in insertMany batches of 1,000. Each order has 5 to 15
// lines {lineId, sku, qty}, a customer, a status and a ship address. The data
// comes from a fixed-seed generator, so every run seeds the same orders.
//
// Stage-0 indexes (what a DBA would add for the probe's predicates), both made
// with createIndex: a multivalue index on items.sku and an index on status.
// They are created on the empty collection, before the load: on this stack,
// createIndex on a loaded collection fails with ORA-00910 (MAX_STRING_SIZE is
// STANDARD), and on an empty one it succeeds and indexes every later insert.
// Statistics are gathered after the load, as at every later stage, with a
// histogram on every indexed column (FOR ALL INDEXED COLUMNS SIZE 254), so the
// optimizer sees the skew in status and sku. Gathered right after the load,
// the default (SIZE AUTO) builds no histograms, because no query has used
// the columns yet. Multivalue index columns cannot carry a histogram.

const NAME = 'm08b3_orders';
const N_ORDERS = 20000;
const BATCH = 1000;

// mulberry32: a small fixed-seed generator, so the data is the same every run.
function rng(seed) {
  let a = seed >>> 0;
  return function () {
    a = (a + 0x6D2B79F5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
const r = rng(20261113);
const pad = (n, w) => String(n).padStart(w, '0');

// 500 skus: SKU-HOT, SKU-RARE and SKU-001 to SKU-498.
// SKU-HOT is 1.5% of all lines (about 1 order in 7 has one).
// SKU-RARE is on exactly 3 orders, one line each.
// The other 498 are skewed: a squared uniform draw favors the low numbers.
const RARE_ORDERS = new Set([777, 7777, 17777]);
function pickSku() {
  if (r() < 0.015) return 'SKU-HOT';
  return 'SKU-' + pad(Math.floor(r() * r() * 498) + 1, 3);
}
// status: 5 values; open is about 10% of orders.
function pickStatus() {
  const x = r();
  if (x < 0.10) return 'open';
  if (x < 0.55) return 'shipped';
  if (x < 0.90) return 'closed';
  if (x < 0.95) return 'new';
  return 'cancelled';
}
const cities = [['Boston', '02108'], ['Chicago', '60601'], ['Denver', '80202'],
                ['Seattle', '98101'], ['Austin', '78701'], ['Miami', '33101']];

// Start clean, whichever stage an earlier run stopped at.
for (const stmt of ['drop view if exists "m08b3_orders"', 'drop table if exists m08b3_lines purge',
                    'drop table if exists m08b3_orders_t purge', 'drop table if exists m08b3_orders_v0 purge']) {
  db.aggregate([{ $sql: stmt }]).toArray();
}
db.getCollection('m08b3_runs').drop();
const col = db.getCollection(NAME);
col.drop();
col.createIndex({ 'items.sku': 1 });
col.createIndex({ status: 1 });

let batch = [];
let lines = 0;
for (let i = 1; i <= N_ORDERS; i++) {
  const k = 5 + Math.floor(r() * 11);
  const items = [];
  for (let j = 1; j <= k; j++) {
    const sku = (RARE_ORDERS.has(i) && j === 1) ? 'SKU-RARE' : pickSku();
    items.push({ lineId: 'L' + pad(i, 5) + '-' + pad(j, 2), sku: sku, qty: 1 + Math.floor(r() * 10) });
  }
  lines += k;
  const c = cities[Math.floor(r() * cities.length)];
  batch.push({ _id: i, customer: 'C' + pad(1 + Math.floor(r() * 2000), 4), status: pickStatus(),
               items: items, ship: { city: c[0], zip: c[1] } });
  if (batch.length === BATCH) { col.insertMany(batch, { ordered: false }); batch = []; }
}
if (batch.length) col.insertMany(batch, { ordered: false });

db.aggregate([{ $sql: `begin dbms_stats.gather_table_stats(user, '"${NAME}"', method_opt => 'FOR ALL COLUMNS SIZE AUTO FOR ALL INDEXED COLUMNS SIZE 254', cascade => true, no_invalidate => false); end;` }]).toArray();

const idx = col.getIndexes().map((x) => Object.keys(x.key).join(',')).sort();
const seeded = col.countDocuments({}) === N_ORDERS &&
  idx.includes('items.sku') && idx.includes('status') &&
  col.countDocuments({ 'items.sku': 'SKU-RARE' }) === RARE_ORDERS.size;
print('seeded ' + N_ORDERS + ' orders, ' + lines + ' lines; indexes: ' + idx.join(' | '));
print('ASSERT:s3b-seeded:' + (seeded ? 'PASS' : 'FAIL'));
