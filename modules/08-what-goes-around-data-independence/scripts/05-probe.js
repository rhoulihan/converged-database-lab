// S3 probe: the unchanged application code, run after a storage move.
// 03, 05 and 07 are byte-identical; the probe and normalize functions are
// also byte-identical to 01. Passes only if every read and every write result
// matches the stage-0 baseline in probe_runs.

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

function firstDiff(a, b, path) {
  if (JSON.stringify(a) === JSON.stringify(b)) return null;
  if (a && b && typeof a === 'object' && typeof b === 'object') {
    for (const k of new Set(Object.keys(a).concat(Object.keys(b)))) {
      const d = firstDiff(a[k], b[k], path + '.' + k);
      if (d) return d;
    }
  }
  return path + ': expected ' + JSON.stringify(a) + ' got ' + JSON.stringify(b);
}

const baseline = db.getCollection('probe_runs').findOne({ _id: 'stage0' });
const now = normalize(probe(db.getCollection('sales_orders')));
const identical = baseline !== null && same(baseline.results, now);
if (!identical && baseline !== null) print('diff ' + firstDiff(normalize(baseline.results), now, 'results'));
print('ASSERT:s3-stage-identical:' + (identical ? 'PASS' : 'FAIL'));
