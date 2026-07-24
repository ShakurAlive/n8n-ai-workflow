const { Client } = require('pg');
(async () => {
  const c = new Client();
  await c.connect();
  await c.query('CREATE TABLE IF NOT EXISTS _pgtest(id serial primary key, t timestamptz default now())');
  const r = await c.query('INSERT INTO _pgtest DEFAULT VALUES RETURNING id');
  const s = await c.query('SELECT count(*)::int AS n FROM _pgtest');
  await c.end();
  console.log('DB_OK id=' + r.rows[0].id + ' total=' + s.rows[0].n);
})().catch((e) => { console.error('DB_ERR ' + e.message); process.exit(1); });
