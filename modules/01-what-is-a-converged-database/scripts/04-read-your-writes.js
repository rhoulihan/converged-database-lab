// Proof 4: write through the document API, read through SQL — same second, no
// sync pipeline, no lag window. The polyglot equivalent needs CDC + reindex delay.
const evts = db.getCollection('events');
const marker = 'rww-' + Math.floor(Math.random() * 1e9);
evts.insertOne({ type: 'consistency_probe', marker: marker });

const viaSql = db.aggregate([
  { $sql: 'SELECT COUNT(*) AS "n" FROM events e WHERE e.data.marker.string() = \'' + marker + '\'' }
]).toArray();
print('ASSERT:read-your-writes-sql:' + (viaSql.length === 1 && Number(viaSql[0].n) === 1 ? 'PASS' : 'FAIL'));

evts.deleteOne({ marker: marker });
print('ASSERT:probe-cleaned:' + (evts.countDocuments({ marker: marker }) === 0 ? 'PASS' : 'FAIL'));
