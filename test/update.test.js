import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync} from 'node:fs';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {spawnSync} from 'node:child_process';
const script = new URL('../deploy/update.sh', import.meta.url).pathname;
function setup(t, extra={}) {
  const dir=mkdtempSync(join(tmpdir(),'pirate-update-')); t.after(()=>rmSync(dir,{recursive:true,force:true}));
  const bin=join(dir,'bin'), log=join(dir,'docker.log');mkdirSync(bin);
  writeFileSync(join(dir,'compose.yaml'),'services: {}\n');
  writeFileSync(join(dir,'.env'),'PUBLIC_ORIGIN=https://test.example:8443\nTURN_SECRET=test-unchanged\n',{mode:0o600});
  writeFileSync(join(bin,'docker'),`#!/bin/sh
printf '%s\\n' "$*" >> "$PIRATE_TEST_LOG"
case "$*" in
  *'ps -aq app') [ "\${PIRATE_TEST_MISSING:-0}" = 1 ] || echo existing-app ;;
  *'build app') exit "\${PIRATE_TEST_BUILD_EXIT:-0}" ;;
  *'exec -T app node'*) echo 'Server 1.2.2: text and voice chat available.' ;;
esac
`,{mode:0o755});
  return {dir,log,run:()=>spawnSync('sh',[script,'screenroom'],{cwd:dir,encoding:'utf8',env:{...process.env,PATH:bin+':'+process.env.PATH,PIRATE_TEST_LOG:log,...extra}})};
}
test('update rebuilds only the existing app, preserving environment and other services', t=>{
  const {dir,log,run}=setup(t);const original=readFileSync(join(dir,'.env'),'utf8');
  const result=run();assert.equal(result.status,0,result.stderr);
  const lines=readFileSync(log,'utf8');
  assert.match(lines,/compose -p screenroom -f compose.yaml build app/);
  assert.match(lines,/up -d --no-deps app/);
  assert.doesNotMatch(lines,/\b(down|caddy|turn|volume|prune)\b/);
  assert.equal(readFileSync(join(dir,'.env'),'utf8'),original);
});
test('unknown project and failed builds never recreate the running app',t=>{
  for (const extra of [{PIRATE_TEST_MISSING:'1'},{PIRATE_TEST_BUILD_EXIT:'17'}]) {
    const {log,run}=setup(t,extra);assert.notEqual(run().status,0);
    assert.doesNotMatch(readFileSync(log,'utf8'),/up -d/);
  }
});
