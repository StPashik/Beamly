#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const { mkdtemp, mkdir, readFile, rename, rm } = require('node:fs/promises');
const { createHash } = require('node:crypto');
const { execFileSync } = require('node:child_process');
const { homedir, tmpdir } = require('node:os');
const { join } = require('node:path');
const { version } = require('../package.json');

const asset = `Beamly-${version}-universal.zip`;
const release = `https://github.com/StPashik/Beamly/releases/download/v${version}`;
const userApplications = join(homedir(), 'Applications');

async function verifyArchive(archive, expected) {
  if (!/^[a-f0-9]{64}$/i.test(expected)) throw new Error('Invalid release checksum.');
  const hash = createHash('sha256');
  for await (const chunk of fs.createReadStream(archive)) hash.update(chunk);
  if (hash.digest('hex') !== expected.toLowerCase()) throw new Error('Release checksum mismatch; nothing was installed.');
}

async function installArchive(archive, checksum, applications = userApplications) {
  const destination = join(applications, 'Beamly.app');
  if (fs.existsSync(destination)) throw new Error(`${destination} already exists. Quit Beamly and move that app to the Trash before reinstalling. Your queue is stored separately.`);
  // Check integrity before extracting any files from the downloaded archive.
  await verifyArchive(archive, checksum);
  const entries = execFileSync('/usr/bin/unzip', ['-Z', '-1', archive], { encoding: 'utf8' }).trim().split('\n');
  if (!entries.every(name => name.startsWith('Beamly.app/') && !name.includes('\\') && !name.split('/').includes('..'))) {
    throw new Error('Unexpected paths in the release archive.');
  }
  await mkdir(applications, { recursive: true });
  // Stage on the destination volume so the final rename is atomic.
  const staging = await mkdtemp(join(applications, '.beamly-install-'));
  try {
    execFileSync('/usr/bin/ditto', ['-x', '-k', archive, staging]);
    const bundle = join(staging, 'Beamly.app');
    const info = join(bundle, 'Contents', 'Info.plist');
    const identifier = execFileSync('/usr/libexec/PlistBuddy', ['-c', 'Print :CFBundleIdentifier', info], { encoding: 'utf8' }).trim();
    const appVersion = execFileSync('/usr/libexec/PlistBuddy', ['-c', 'Print :CFBundleShortVersionString', info], { encoding: 'utf8' }).trim();
    if (identifier !== 'app.peamer.mac' || appVersion !== version) throw new Error('Unexpected app identity or release version.');
    execFileSync('/usr/bin/codesign', ['--verify', '--deep', '--strict', bundle]);
    await rename(bundle, destination);
  } finally {
    await rm(staging, { recursive: true, force: true });
  }
  return destination;
}

function download(url, destination, maxSize) {
  execFileSync('/usr/bin/curl', ['--fail', '--location', '--silent', '--show-error', '--retry', '2', '--connect-timeout', '15', '--max-time', '120', '--max-filesize', String(maxSize), '--output', destination, url], { stdio: 'inherit' });
}

async function main() {
  const command = process.argv[2] || 'open';
  if (command === '--version') { console.log(version); return; }
  if (command === '--help' || command === '-h') {
    console.log('Beamly — native macOS AirPlay player\n\nbeamly install   Download, verify, and install to ~/Applications\nbeamly           Open the installed app\nbeamly --version Show the installer version\n\nFFmpeg is installed separately: brew install ffmpeg-full');
    return;
  }
  if (process.platform !== 'darwin') throw new Error('Beamly requires macOS 14 or later.');
  if (command === 'install') {
    const temporary = await mkdtemp(join(tmpdir(), 'beamly-download-'));
    try {
      console.log(`Downloading Beamly ${version} for Apple Silicon and Intel…`);
      const checksums = join(temporary, 'SHA256SUMS');
      const archive = join(temporary, asset);
      download(`${release}/SHA256SUMS`, checksums, 8192);
      const entry = (await readFile(checksums, 'utf8')).split('\n').map(line => line.trim().split(/\s+/)).find(parts => parts[1] === asset);
      if (!entry) throw new Error('The release does not list the expected archive.');
      download(`${release}/${asset}`, archive, 100 * 1024 * 1024);
      const destination = await installArchive(archive, entry[0]);
      console.log(`Installed ${destination}\nRun beamly to open it. This build is ad-hoc signed and is not notarized by Apple.`);
    } finally {
      await rm(temporary, { recursive: true, force: true });
    }
  } else if (command === 'open') {
    const app = [join(userApplications, 'Beamly.app'), '/Applications/Beamly.app'].find(path => fs.existsSync(path));
    if (!app) throw new Error('Beamly is not installed. Run beamly install first.');
    execFileSync('/usr/bin/open', [app]);
  } else {
    throw new Error('Unknown command. Run beamly --help.');
  }
}

if (require.main === module) main().catch(error => { console.error(error.message); process.exitCode = 1; });
module.exports = { verifyArchive, installArchive };
