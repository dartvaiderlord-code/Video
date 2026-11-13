import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, existsSync, statSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
const script = new URL('../deploy/configure.sh', import.meta.url).pathname;
function setup(t) {
  const dir = mkdtempSync(join(tmpdir(), 'screenroom-config-'));
  t.after(() => rmSync(dir, {recursive:true, force:true}));
  const file = join(dir, '.env');
  const run = (args, overrides = {}) => spawnSync('sh', [script, ...args], {
    env:{...process.env, SCREENROOM_ENV_FILE:file, HTTPS_PORT:'9443', APP_PORT:'3200', TURN_PORT:'3480', ABORDAGE_PORT:'3490', TURN_MIN_PORT:'41000', TURN_MAX_PORT:'41060', ...overrides}, encoding:'utf8'
  });
  return {file, run};
}
test('standalone configuration is private, portable, and never overwrites existing secrets', t => {
  const {file, run} = setup(t);
  const result = run(['stream.example.com', '203.0.113.10']);
  assert.equal(result.status, 0, result.stderr);
  const env = readFileSync(file, 'utf8');
  assert.match(env,/ABORDAGE_PORT=3490\n/);
  assert.match(env, /PUBLIC_ORIGIN=https:\/\/stream.example.com:9443\n/);
  assert.match(env, /TURN_URLS=turn:203.0.113.10:3480\?transport=udp,turn:203.0.113.10:3480\?transport=tcp/);
  assert.equal(statSync(file).mode & 0o777, 0o600);
  const secret = env.match(/^TURN_SECRET=(.+)$/m)[1];
  assert.match(secret, /^[a-f0-9]{64}$/);
  assert.equal(env.includes('ACCESS_KEY='), false);
  assert.equal(result.stdout.includes(secret), false);
  assert.notEqual(run(['203.0.113.20']).status, 0);
  assert.equal(readFileSync(file, 'utf8'), env);
});
test('invalid addresses, config injection, and overlapping ports do not create configuration', t => {
  const {file, run} = setup(t);
  for (const args of [[], ['https://example.com'], ['example.com'], ['999.1.1.1'], ['a.example\nINJECTED=1', '203.0.113.10'], ['a.example', '203.0.113.10\nOTHER=1']]) {
    assert.notEqual(run(args).status, 0); assert.equal(existsSync(file), false);
  }
  assert.notEqual(run(['203.0.113.10'], {TURN_PORT:'41020'}).status, 0);
  assert.notEqual(run(['203.0.113.10'], {ABORDAGE_PORT:'3480'}).status, 0);
  assert.notEqual(run(['203.0.113.10'], {ABORDAGE_PORT:'41020'}).status, 0);
  assert.equal(existsSync(file), false);
});
