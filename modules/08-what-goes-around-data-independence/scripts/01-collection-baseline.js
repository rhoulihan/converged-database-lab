// S3 stage 0: sales_orders as a plain MongoDB API collection.
// Seeds 8 orders, runs the probe and stores its normalized results in
// probe_runs as the baseline every later stage must match exactly.
// The probe and normalize functions below are byte-identical to 03/05/07.

// normalize: make two reads of the same data compare equal regardless of
// transport noise. It strips the _metadata (etag, asof) that the MongoDB API
// adds to duality view documents, sorts object keys recursively (field order
// is not part of a document's meaning) and renders every number with Number(),
// so int, long, double and decimal all print the same. Array order is kept:
// it is part of the data.
function normalize(x) {
  if (x === null || x === undefined) return null;
  if (Array.isArray(x)) return x.map(normalize);
  if (typeof x === 'number' || typeof x === 'bigint') return Number(x);
  if (typeof x === 'object') {
    if (['Int32', 'Long', 'Double', 'Decimal128'].includes(x._bsontype)) {
      return Number(x.toString());
    }
    const out = {};
    for (const k of Object.keys(x).sort()) {
      if (k === '_metadata') continue;
      out[k] = normalize(x[k]);
    }
    return out;
  }
  return x;
}

// probe: the application's own access patterns, written once and never edited.
// Reads first, then a write phase on scratch _id 900 that ends by deleting it,
// so every stage starts from the same 8 seeded orders.
function probe(col) {
  const byId = { _id: 1 };
  const r = {};
  r.findAll = col.find({}).sort(byId).toArray();
  r.findOpen = col.find({ status: 'open' }).sort(byId).toArray();
  r.findSkuA1 = col.find({ 'items.sku': 'A1' }).sort(byId).toArray();
  r.qtyBySku = col.aggregate([
    { $unwind: '$items' },
    { $group: { _id: '$items.sku', qty: { $sum: '$items.qty' } } },
    { $sort: { _id: 1 } }
  ]).toArray();

  const key = { _id: 900 };
  const upd = (u) => ({ matched: u.matchedCount, modified: u.modifiedCount });
  r.writes = [];
  const step = (name, result) => r.writes.push({ step: name, result: result, doc: col.findOne(key) });

  step('insertOne', { insertedId: col.insertOne({
    _id: 900, customer: 'Zoe', status: 'new',
    items: [{ lineId: 'L900-1', sku: 'A1', qty: 1 }, { lineId: 'L900-2', sku: 'B2', qty: 2 }],
    ship: { city: 'Austin', zip: '78701' }
  }).insertedId });
  step('setTopLevel', upd(col.updateOne(key, { $set: { status: 'open' } })));
  step('setNested', upd(col.updateOne(key, { $set: { 'ship.city': 'Dallas' } })));
  step('incPositional', upd(col.updateOne({ _id: 900, 'items.lineId': 'L900-1' }, { $inc: { 'items.$.qty': 5 } })));
  step('push', upd(col.updateOne(key, { $push: { items: { lineId: 'L900-3', sku: 'C3', qty: 3 } } })));
  step('pullTwoFields', upd(col.updateOne(key, { $pull: { items: { lineId: 'L900-2', sku: 'B2' } } })));
  step('replaceOne', upd(col.replaceOne(key, {
    customer: 'Zoe', status: 'shipped',
    items: [{ lineId: 'L900-1', sku: 'A1', qty: 6 }, { lineId: 'L900-3', sku: 'C3', qty: 4 }],
    ship: { city: 'Houston', zip: '77002' }
  })));
  r.findOne900 = col.findOne(key);
  step('deleteOne', { deleted: col.deleteOne(key).deletedCount });
  return r;
}

const same = (a, b) => JSON.stringify(normalize(a)) === JSON.stringify(normalize(b));

// Setup: start clean, then seed 8 deterministic orders. lineIds are globally
// unique strings; each order's lineIds sort in array order.
db.getCollection('sales_orders').drop();
db.getCollection('probe_runs').drop();
const cities = [['Boston', '02108'], ['Chicago', '60601'], ['Denver', '80202'], ['Seattle', '98101']];
const skus = ['A1', 'B2', 'C3', 'D4'];
const statuses = ['open', 'shipped', 'open', 'closed'];
const seed = [];
for (let i = 1; i <= 8; i++) {
  const items = [];
  for (let j = 1; j <= (i % 3) + 1; j++) {
    items.push({ lineId: 'L00' + i + '-' + j, sku: skus[(i + j) % 4], qty: i + j });
  }
  const c = cities[i % 4];
  seed.push({ _id: i, customer: 'Customer ' + i, status: statuses[i % 4], items: items, ship: { city: c[0], zip: c[1] } });
}
db.getCollection('sales_orders').insertMany(seed);

const results = normalize(probe(db.getCollection('sales_orders')));
db.getCollection('probe_runs').insertOne({ _id: 'stage0', results: results });
const stored = db.getCollection('probe_runs').findOne({ _id: 'stage0' });
const captured = stored !== null && same(stored.results, results) &&
  results.findAll.length === 8 && results.findOpen.length > 0 &&
  results.findSkuA1.length > 0 && results.writes.length === 8 &&
  results.findOne900 !== null && results.writes[7].doc === null;
print('ASSERT:s3-stage0-captured:' + (captured ? 'PASS' : 'FAIL'));

// Negative check: a deliberately changed copy must NOT compare equal,
// so "identical" in later stages cannot pass by accident.
const mutated = JSON.parse(JSON.stringify(results));
mutated.findAll[0].ship.city = mutated.findAll[0].ship.city + 'X';
print('ASSERT:s3-normalizer-detects-change:' + (!same(mutated, results) ? 'PASS' : 'FAIL'));
