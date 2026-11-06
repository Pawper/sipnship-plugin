'use strict';
// A fixture log copied as a session working now writes it: every entry's own
// time moved by the same amount, so its last entry is at `at` (default now),
// and the file's date set to match. The sample reads a session's time from its
// entries, never the file's date, so a copy alone would read as hours old.
const fs = require('fs');

function freshLog(src, dest, at = Date.now()) {
  const rows = fs.readFileSync(src, 'utf8').split('\n');
  const times = rows.map((r) => { const m = r.match(/"timestamp":"([^"]+)"/); return m ? Date.parse(m[1]) : NaN; }).filter((t) => !Number.isNaN(t));
  const shift = times.length ? at - Math.max(...times) : 0;
  const out = rows.map((r) => r.replace(/"timestamp":"([^"]+)"/g, (whole, t) => (Number.isNaN(Date.parse(t)) ? whole : `"timestamp":"${new Date(Date.parse(t) + shift).toISOString()}"`)));
  fs.writeFileSync(dest, out.join('\n'));
  fs.utimesSync(dest, new Date(at), new Date(at));
  return shift;
}

module.exports = { freshLog };
