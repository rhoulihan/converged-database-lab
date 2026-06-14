// Module 05 proof 2 (companion): ETag optimistic-concurrency conflict through the
// MongoDB API. Each Mongo operation is its own committed statement, so the
// stale-write rejection is deterministic here (cleaner than pure-SQL, where the
// etag is computed against last-committed data). This proves the duality view's
// content-based ETag gives lock-free optimistic concurrency over a NORMALIZED
// store — relational ACID safety with document (replaceOne) ergonomics.
//
// Mechanism: order_dv is a duality view exposed as a Mongo collection. Each
// document carries _metadata.etag (a content hash, auto-renewed on read). A write
// is rejected if the document's etag no longer matches the current persistent
// (last-committed) data — raising ORA-42699 (HTTP 412 over REST).
//
// Cleanup: JS has no rollback, so the base row is restored explicitly at the end.

const col = db.getCollection('order_dv');

// 1. Capture a document (and its etag) the way a client would before editing.
const stale = col.findOne({ _id: 1 });
print('ASSERT:etag-doc-captured:' +
      (stale && stale._metadata && stale._metadata.etag ? 'PASS' : 'FAIL'));

const orig = stale.status;
const bumped = (orig === 'shipped') ? 'placed' : 'shipped';

// 2. Another writer changes the underlying ORDER row via $sql (one engine
//    underneath) — this bumps the persistent etag, making our captured doc stale.
db.aggregate([{ $sql: "UPDATE orders SET status = '" + bumped + "' WHERE order_id = 1" }]).toArray();
const probe = db.aggregate([{ $sql: "SELECT status AS \"s\" FROM orders WHERE order_id = 1" }]).toArray();
print('ASSERT:base-row-bumped:' + (probe.length === 1 && probe[0].s === bumped ? 'PASS' : 'FAIL'));

// 3. Try to write the STALE document back (it still carries the OLD etag) ->
//    the duality view must reject it with an ETag mismatch (ORA-42699).
let conflict = false;
try {
  stale.status = orig;                 // attempt to revert through the stale doc
  col.replaceOne({ _id: 1 }, stale);
} catch (e) {
  const msg = (e && e.message ? e.message : String(e));
  conflict = /ORA-42699|ETAG|did not match/i.test(msg);
}
print('ASSERT:stale-write-rejected:' + (conflict ? 'PASS' : 'FAIL'));

// 4. Restore the base row so the domain is unchanged, and confirm.
db.aggregate([{ $sql: "UPDATE orders SET status = '" + orig + "' WHERE order_id = 1" }]).toArray();
const back = col.findOne({ _id: 1 });
print('ASSERT:etag-restored:' + (back.status === orig ? 'PASS' : 'FAIL'));
