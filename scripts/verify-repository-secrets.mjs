import { execFileSync } from 'node:child_process';
import { lstatSync, readFileSync, realpathSync } from 'node:fs';
import { basename, isAbsolute, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { DOMParser } from '@xmldom/xmldom';

const forbiddenIdentityProperties = new Set([
  'packagecertificatekeyfile', 'packagecertificatethumbprint', 'packagecertificatepassword',
  'manifestcertificatekeyfile', 'manifestcertificatethumbprint', 'signingpassword',
]);
const privateKeyHeader = /-----BEGIN (?:RSA |EC |DSA |OPENSSH |ENCRYPTED )?PRIVATE KEY-----/;

export function trackedPaths(root) {
  return execFileSync('git', ['ls-files', '--cached', '-z'], { cwd: root, encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 })
    .split('\0').filter(Boolean);
}

function contained(root, path) {
  const child = relative(root, path);
  return child !== '' && !isAbsolute(child) && child !== '..' && !child.startsWith(`..${sep}`);
}

function signingXmlFindings(source) {
  if (/<!DOCTYPE/i.test(source)) return ['XML_DOCTYPE'];
  let document;
  try {
    document = new DOMParser({ onError: () => { throw new Error('Invalid project XML'); } }).parseFromString(source, 'application/xml');
  } catch { return ['INVALID_XML']; }
  const findings = new Set();
  for (const element of Array.from(document.getElementsByTagName('*'))) {
    const name = element.localName.toLowerCase();
    if (forbiddenIdentityProperties.has(name)) findings.add('SIGNING_IDENTITY_PROPERTY');
    if (['appxpackagesigningenabled', 'signmanifests'].includes(name)
      && element.textContent.trim().toLowerCase() !== 'false') findings.add('SIGNING_ENABLED');
    for (const attribute of Array.from(element.attributes)) {
      if (/\.(?:pfx|p12|mobileprovision)(?:$|[;"'])/i.test(attribute.value)) findings.add('SIGNING_IDENTITY_REFERENCE');
    }
  }
  return [...findings];
}

/** Findings contain paths and fixed codes only; never file contents or parser errors. */
export function scanFiles({ root, paths }) {
  root = realpathSync(root);
  if (!Array.isArray(paths) || paths.length === 0) throw new Error('A non-empty file inventory is required');
  const findings = [];
  for (const path of [...new Set(paths)]) {
    if (typeof path !== 'string' || isAbsolute(path) || !contained(root, resolve(root, path))) {
      findings.push({ path: typeof path === 'string' ? path : '<invalid>', code: 'INVALID_PATH' });
      continue;
    }
    const file = resolve(root, path);
    let contents;
    try {
      if (!lstatSync(file).isFile() || realpathSync(file) !== file) {
        findings.push({ path, code: 'UNSAFE_FILE' });
        continue;
      }
      const name = basename(path);
      if (/\.(?:pfx|p12|mobileprovision)$/i.test(name)
        || /^(?:id_(?:rsa|dsa|ecdsa|ed25519)|credentials(?:\.json)?|\.env(?:\.(?:local|production|development))?)$/i.test(name)) {
        findings.push({ path, code: 'CREDENTIAL_FILE' });
        continue;
      }
      contents = readFileSync(file, 'utf8');
    } catch {
      findings.push({ path, code: 'UNREADABLE_FILE' });
      continue;
    }
    if (privateKeyHeader.test(contents)) findings.push({ path, code: 'PRIVATE_KEY' });
    if (/\.(?:vcxproj|props|targets)$/i.test(path)) {
      for (const code of signingXmlFindings(contents)) findings.push({ path, code });
    }
  }
  return findings;
}

function main() {
  const args = process.argv.slice(2);
  let root = process.cwd();
  let inventory;
  for (let index = 0; index < args.length; index += 1) {
    const flag = args[index];
    const value = args[++index];
    if (!value || value.startsWith('--')) throw new Error('Missing scanner argument');
    if (flag === '--root') root = resolve(value);
    else if (flag === '--inventory') inventory = resolve(value);
    else throw new Error('Unknown scanner argument');
  }
  const paths = inventory ? JSON.parse(readFileSync(inventory, 'utf8')) : trackedPaths(root);
  const findings = scanFiles({ root, paths });
  process.stdout.write(`${JSON.stringify({ passed: findings.length === 0, findings })}\n`);
  if (findings.length) process.exitCode = 1;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { main(); } catch { process.stderr.write('REPOSITORY_SECRET_SCAN_FAILED\n'); process.exitCode = 1; }
}
