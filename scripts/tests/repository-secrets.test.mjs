import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, symlinkSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import test from 'node:test';
import { scanFiles, trackedPaths } from '../verify-repository-secrets.mjs';

const repositoryRoot = resolve(import.meta.dirname, '../..');
function fixture(t, files) {
  const root = mkdtempSync(join(tmpdir(), 'rntp-secret-scan-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  for (const [path, text] of Object.entries(files)) {
    mkdirSync(resolve(root, path, '..'), { recursive: true });
    writeFileSync(join(root, path), text);
  }
  return root;
}

test('tracked repository has no signing identity or private key', () => {
  assert.deepEqual(scanFiles({ root: repositoryRoot, paths: trackedPaths(repositoryRoot) }), []);
});

test('rejects signing containers and credential filenames without printing bytes', t => {
  const files = Object.fromEntries(['identity.pfx', 'identity.p12', 'app.mobileprovision', 'id_ed25519', '.env.local'].map(path => [path, 'synthetic-sensitive-content']));
  const root = fixture(t, files);
  const findings = scanFiles({ root, paths: Object.keys(files) });
  assert.equal(findings.length, 5);
  assert.equal(JSON.stringify(findings).includes('synthetic-sensitive-content'), false);
});

test('rejects private PEM keys regardless of extension in a packed file inventory', t => {
  const header = ['-----BEGIN ', 'PRIVATE KEY', '-----'].join('');
  const root = fixture(t, { 'package/src/data.txt': `${header}\nsynthetic\n` });
  assert.deepEqual(scanFiles({ root, paths: ['package/src/data.txt'] }).map(item => item.code), ['PRIVATE_KEY']);
});

test('parses namespaced XML properties and encoded signing defaults', t => {
  const root = fixture(t, { 'app.vcxproj': '<m:Project xmlns:m="urn:msbuild"><m:PropertyGroup><m:PackageCertificatePassword>synthetic</m:PackageCertificatePassword><m:AppxPackageSigningEnabled>tr&#117;e</m:AppxPackageSigningEnabled></m:PropertyGroup></m:Project>' });
  assert.deepEqual(scanFiles({ root, paths: ['app.vcxproj'] }).map(item => item.code).sort(), ['SIGNING_ENABLED', 'SIGNING_IDENTITY_PROPERTY']);
});

test('ignores documentation and XML comments but rejects malformed XML and external entities', t => {
  const root = fixture(t, {
    'docs.md': 'The removed example_TemporaryKey.pfx remains an unknown signing identity.',
    'unsigned.vcxproj': '<Project><!-- <PackageCertificatePassword>removed</PackageCertificatePassword> --><AppxPackageSigningEnabled>false</AppxPackageSigningEnabled></Project>',
    'bad.vcxproj': '<Project><PropertyGroup></Project>',
    'entity.vcxproj': '<!DOCTYPE Project SYSTEM "file:///not-to-read"><Project/>',
  });
  assert.deepEqual(scanFiles({ root, paths: ['docs.md', 'unsigned.vcxproj'] }), []);
  assert.deepEqual(scanFiles({ root, paths: ['bad.vcxproj', 'entity.vcxproj'] }).map(item => item.code), ['INVALID_XML', 'XML_DOCTYPE']);
});

test('rejects path escapes, symlinks and missing inventory files without reading outside root', t => {
  const root = fixture(t, { 'inside.txt': 'safe' });
  symlinkSync('/does-not-exist', join(root, 'link.txt'));
  assert.deepEqual(scanFiles({ root, paths: ['../outside', 'link.txt', 'missing.txt'] }).map(item => item.code), ['INVALID_PATH', 'UNSAFE_FILE', 'UNREADABLE_FILE']);
});
