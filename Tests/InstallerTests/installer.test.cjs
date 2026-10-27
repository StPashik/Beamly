'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { createHash } = require('node:crypto');
const { execFileSync } = require('node:child_process');
const { mkdtemp, writeFile, readFile, mkdir, readdir, rm } = require('node:fs/promises');
const { tmpdir } = require('node:os');
const { join, resolve } = require('node:path');
const { verifyArchive, installArchive } = require('../../bin/beamly.cjs');
const { version } = require('../../package.json');

test('checksum verification rejects corrupt downloads before installing', async t => {
  const folder = await mkdtemp(join(tmpdir(), 'beamly-checksum-test-'));
  t.after(() => rm(folder, { recursive: true, force: true }));
  const archive = join(folder, 'download.zip');
  await writeFile(archive, 'downloaded bytes');
  const checksum = createHash('sha256').update('downloaded bytes').digest('hex');
  await verifyArchive(archive, checksum);
  await assert.rejects(() => verifyArchive(archive, 'invalid'), /Invalid release checksum/);
  await writeFile(archive, 'corrupt bytes');
  await assert.rejects(() => installArchive(archive, checksum, join(folder, 'Applications')), /checksum mismatch/);
  assert.deepEqual((await readdir(folder)).sort(), ['download.zip']);
});

test('installer preserves an existing application', async t => {
  const folder = await mkdtemp(join(tmpdir(), 'beamly-existing-test-'));
  t.after(() => rm(folder, { recursive: true, force: true }));
  const app = join(folder, 'Beamly.app');
  await mkdir(app);
  await writeFile(join(app, 'sentinel'), 'existing app');
  await assert.rejects(() => installArchive('unused.zip', 'unused', folder), /already exists/);
  assert.equal(await readFile(join(app, 'sentinel'), 'utf8'), 'existing app');
});

test('installer rejects unexpected archive paths before extraction', { skip: process.platform !== 'darwin' }, async t => {
  const folder = await mkdtemp(join(tmpdir(), 'beamly-path-test-'));
  t.after(() => rm(folder, { recursive: true, force: true }));
  const file = join(folder, 'unexpected.txt');
  const archive = join(folder, 'unexpected.zip');
  await writeFile(file, 'unexpected content');
  execFileSync('/usr/bin/zip', ['-j', archive, file]);
  const checksum = createHash('sha256').update(await readFile(archive)).digest('hex');
  await assert.rejects(() => installArchive(archive, checksum, join(folder, 'Applications')), /Unexpected paths/);
  assert.deepEqual((await readdir(folder)).sort(), ['unexpected.txt', 'unexpected.zip']);
});

test('installs the actual signed release into an isolated Applications folder', { skip: process.platform !== 'darwin' }, async t => {
  const folder = await mkdtemp(join(tmpdir(), 'beamly-release-test-'));
  t.after(() => rm(folder, { recursive: true, force: true }));
  const name = `Beamly-${version}-universal.zip`;
  const archive = resolve('dist', name);
  const entry = (await readFile(resolve('dist/SHA256SUMS'), 'utf8')).trim().split(/\s+/);
  assert.equal(entry[1], name);
  const installed = await installArchive(archive, entry[0], folder);
  assert.equal(installed, join(folder, 'Beamly.app'));
  assert.ok((await readFile(join(installed, 'Contents', 'MacOS', 'Beamly'))).length > 0);
  const framework = join(installed, 'Contents/Frameworks/Sparkle.framework/Sparkle');
  execFileSync('/usr/bin/lipo', [framework, '-verify_arch', 'arm64', 'x86_64']);
  const plist = join(installed, 'Contents/Info.plist');
  const key = execFileSync('/usr/libexec/PlistBuddy', ['-c', 'Print :SUPublicEDKey', plist], { encoding: 'utf8' }).trim();
  const sourceKey = execFileSync('/usr/libexec/PlistBuddy', ['-c', 'Print :SUPublicEDKey', resolve('Resources/Info.plist')], { encoding: 'utf8' }).trim();
  assert.equal(key, sourceKey);
  assert.deepEqual(await readFile(join(installed, 'Contents/Resources/Sparkle.LICENSE')), await readFile(resolve('Resources/Sparkle.LICENSE')));
  for (const language of ['en', 'ru', 'de', 'fr', 'es']) {
    const resources = join(installed, 'Contents/Resources', language + '.lproj');
    const ui = execFileSync('/usr/bin/plutil', ['-convert', 'json', '-o', '-', join(resources, 'Localizable.strings')], { encoding: 'utf8' });
    assert.ok(JSON.parse(ui)['Check for Updates…']);
    assert.ok(JSON.parse(ui)['Restart Beamly to apply the language.']);
    const info = execFileSync('/usr/bin/plutil', ['-convert', 'json', '-o', '-', join(resources, 'InfoPlist.strings')], { encoding: 'utf8' });
    assert.ok(JSON.parse(info).NSLocalNetworkUsageDescription);
  }
  assert.deepEqual(await readdir(folder), ['Beamly.app']);
});
