// Module 02 proof 2: one enforcement domain — the engine's CHECK constraint
// rejects the same illegal write through every API.
//
// The shared domain declares CHECK (qty > 0) on order_items. This script
// attempts qty = -1 through two doors of the same engine: (a) the MongoDB
// document API, updating items.0.qty in the order_dv duality view, and (b) a
// SQL UPDATE submitted through the same MongoDB connection's $sql aggregation
// stage. Both are rejected with the same ORA-02290 check-constraint
// violation, and the data stays unchanged. There is no per-API validation
// layer to drift — the constraint lives in the engine, beneath every surface.
//
// NOTE on error text: the exact MongoServerError message format observed here
// (ORA-42692 wrapping ORA-02290 on the duality-view document path; a bare
// ORA-02290 on the $sql path) is observed behavior on Oracle AI Database 26ai
// Free as of June 2026, not a documented contract. The documented element is
// the ORA-02290 error code itself (docs.oracle.com/error-help/db/ora-02290),
// so assertions match on the code only. The check-constraint NAME is
// system-generated (SYS_C...), so assertions never reference it.

const col = db.getCollection('order_dv');
const before = col.findOne({ _id: 1 });
const origQty = before && before.items && before.items.length > 0 ? before.items[0].qty : null;
print('ASSERT:doc-read:' + (origQty !== null && origQty > 0 ? 'PASS' : 'FAIL'));

// (a) document API: push an illegal qty into the duality view.
let docErr = null;
try {
  col.updateOne({ _id: 1 }, { $set: { 'items.0.qty': -1 } });
} catch (e) {
  docErr = e;
}
const docMsg = docErr ? String(docErr.message || docErr.errmsg || docErr) : '';
print('ASSERT:mongo-api-rejected:' + (docErr !== null && docMsg.includes('ORA-02290') ? 'PASS' : 'FAIL'));

// the rejected write changed nothing — the document still carries the
// original qty.
const afterDoc = col.findOne({ _id: 1 });
print('ASSERT:doc-unchanged:' + (afterDoc.items[0].qty === origQty ? 'PASS' : 'FAIL'));

// (b) same violation as plain SQL through the same MongoDB connection: the
// $sql stage accepts the UPDATE and the engine rejects it with the same code.
let sqlErr = null;
try {
  db.aggregate([{ $sql: 'UPDATE order_items SET qty = -1 WHERE order_id = 1 AND line_no = 1' }]).toArray();
} catch (e) {
  sqlErr = e;
}
const sqlMsg = sqlErr ? String(sqlErr.message || sqlErr.errmsg || sqlErr) : '';
print('ASSERT:sql-update-rejected:' + (sqlErr !== null && sqlMsg.includes('ORA-02290') ? 'PASS' : 'FAIL'));

// final state: both the document projection and the relational rows still
// show the original qty — nothing to restore because nothing got through.
const finalDoc = col.findOne({ _id: 1 });
const finalRows = db.aggregate([
  { $sql: 'SELECT qty AS "qty" FROM order_items WHERE order_id = 1 AND line_no = 1' }
]).toArray();
print('ASSERT:final-state-unchanged:' + (
  finalDoc.items[0].qty === origQty &&
  finalRows.length === 1 &&
  Number(finalRows[0].qty) === origQty ? 'PASS' : 'FAIL'));
