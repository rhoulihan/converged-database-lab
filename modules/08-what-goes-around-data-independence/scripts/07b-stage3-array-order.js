// S3 stage 3: what happens to array order once the array lives in a table.
// Duality views cannot order a nested array (ORDER BY in a nested array
// subquery raises ORA-40895). Once an array lives in a child table, its order
// is the database's read order, not a guaranteed array order. Move only arrays
// whose order the app does not rely on, or that carry an ordering field the
// app sorts by.
//
// Writes scratch order _id 901 with items deliberately out of lineId order,
// checks that the same lines come back (as a set keyed by lineId), records
// whether the inserted order survived (informational METRIC, not asserted),
// then deletes 901.

const col = db.getCollection('sales_orders');
const inserted = [
  { lineId: 'L901-3', sku: 'C3', qty: 3 },
  { lineId: 'L901-1', sku: 'A1', qty: 1 },
  { lineId: 'L901-2', sku: 'B2', qty: 2 }
];
col.deleteOne({ _id: 901 });
col.insertOne({ _id: 901, customer: 'Order Check', status: 'new', items: inserted,
                ship: { city: 'Austin', zip: '78701' } });
const back = col.findOne({ _id: 901 });
const got = back && Array.isArray(back.items) ? back.items : [];

const asMap = (items) => {
  const m = {};
  for (const it of items) m[it.lineId] = it.sku + ':' + Number(it.qty.toString());
  return JSON.stringify(Object.keys(m).sort().map((k) => [k, m[k]]));
};
const sameSet = got.length === inserted.length && asMap(got) === asMap(inserted);
print('ASSERT:s3-stage3-items-same-set:' + (sameSet ? 'PASS' : 'FAIL'));

const orderPreserved = got.map((it) => it.lineId).join(',') === inserted.map((it) => it.lineId).join(',');
print('read-back order: ' + got.map((it) => it.lineId).join(','));
print('METRIC:s3-stage3-order-preserved:' + (orderPreserved ? 1 : 0));

col.deleteOne({ _id: 901 });
