// Proof 2: a duality view document and its relational rows are the same data.
// Plain CRUD via the MongoDB API (no beta stages needed); $sql shows the
// relational view of the same write in the same engine.
const col = db.getCollection('customer_profile_dv');
const before = col.findOne({ _id: 42 });
print('ASSERT:dv-doc-exists:' + (before && before.fullName === 'Customer 42' ? 'PASS' : 'FAIL'));

// Update segment THROUGH THE DOCUMENT API...
col.updateOne({ _id: 42 }, { $set: { segment: 'vip' } });
const after = col.findOne({ _id: 42 });
print('ASSERT:dv-doc-updated:' + (after.segment === 'vip' ? 'PASS' : 'FAIL'));

// ...and read it back through SQL in the SAME api (one engine underneath):
const rows = db.aggregate([{ $sql: 'SELECT segment AS "segment" FROM customers WHERE customer_id = 42' }]).toArray();
print('ASSERT:dv-sql-sees-doc-write:' + (rows.length === 1 && rows[0].segment === 'vip' ? 'PASS' : 'FAIL'));

// restore (JS has no rollback; put the row back explicitly)
col.updateOne({ _id: 42 }, { $set: { segment: 'standard' } });
const restored = col.findOne({ _id: 42 });
print('ASSERT:dv-restored:' + (restored.segment === 'standard' ? 'PASS' : 'FAIL'));
