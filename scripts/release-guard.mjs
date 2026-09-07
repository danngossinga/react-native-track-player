import { createHash } from 'node:crypto';
import { readFile as readFileFromDisk, realpath as realpathFromDisk } from 'node:fs/promises';
import { dirname, isAbsolute, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const PROGRAM = '008';
const RELEASE_RECORD_PATH = '.release/program-008.json';
const FROZEN_MESSAGE = 'RELEASE_BLOCKED program=008 status=frozen';
const APPROVED_MESSAGE = 'RELEASE_ALLOWED program=008 status=approved';
const SIGNING_ARTIFACT_ID = 'program-008/windows-signing-identity/v1';
const SIGNING_ARTIFACT_PATH = '.release/windows-signing-identity-attestation.json';
const SIGNING_ASSESSMENT_PATH = '.release/windows-signing-identity-assessment.json';

export const EXPECTED_BASELINES = Object.freeze({
  proxy: '176b5c8a8183c53343d3a6ec82595352c5d970c5',
  player: 'edafba80fa1c5cbf64bb0c52ce4104a3cf9cc5f9',
  rntp: '9e67ef896b2fdcecae2aaad5cd357e56a83fa629',
});

const EXPECTED_EXIT_GATES = Object.freeze([
  1,
  2,
  3,
  4,
  5,
  6,
  7,
  8,
  9,
  'global_review',
  'explicit_unfreeze',
]);
const RELEASE_RECORD_KEYS = Object.freeze([
  'baselines',
  'exitGates',
  'program',
  'reason',
  'schemaVersion',
  'securityPrerequisites',
  'status',
]);
const PREREQUISITE_KEYS = Object.freeze([
  'artifactId',
  'artifactPath',
  'artifactSha256',
  'assessmentPath',
  'id',
]);
const ASSESSMENT_KEYS = Object.freeze([
  'assessment',
  'attestation',
  'identity',
  'remediation',
  'schemaVersion',
]);
const ASSESSMENT_ATTESTATION_KEYS = Object.freeze([
  'artifactId',
  'path',
  'sha256',
]);
const ATTESTATION_KEYS = Object.freeze([
  'artifactId',
  'assessment',
  'basis',
  'identity',
  'remediation',
  'schemaVersion',
]);

function blocked(code, detail = code.toLowerCase()) {
  return {
    allowed: false,
    code,
    message: `RELEASE_BLOCKED program=${PROGRAM} reason=${detail}`,
  };
}

function isPlainObject(value) {
  return (
    value !== null &&
    typeof value === 'object' &&
    !Array.isArray(value) &&
    Object.getPrototypeOf(value) === Object.prototype
  );
}

function hasExactKeys(value, expectedKeys) {
  return (
    isPlainObject(value) &&
    JSON.stringify(Object.keys(value).sort()) ===
      JSON.stringify([...expectedKeys].sort())
  );
}

function arraysEqual(actual, expected) {
  return (
    Array.isArray(actual) &&
    actual.length === expected.length &&
    actual.every((value, index) => value === expected[index])
  );
}

function baselinesEqual(actual, expected) {
  return (
    hasExactKeys(actual, Object.keys(expected)) &&
    Object.entries(expected).every(([name, sha]) => actual[name] === sha)
  );
}

function isLowercaseSha256(value) {
  return typeof value === 'string' && /^[a-f0-9]{64}$/.test(value);
}

function isNonEmptyString(value) {
  return typeof value === 'string' && value.trim().length > 0;
}

function prerequisiteShapeIsValid(prerequisite) {
  return (
    hasExactKeys(prerequisite, PREREQUISITE_KEYS) &&
    prerequisite.id === 'windows_signing_identity' &&
    prerequisite.assessmentPath === SIGNING_ASSESSMENT_PATH &&
    prerequisite.artifactId === SIGNING_ARTIFACT_ID &&
    prerequisite.artifactPath === SIGNING_ARTIFACT_PATH &&
    isLowercaseSha256(prerequisite.artifactSha256)
  );
}

function releaseRecordShapeIsValid(releaseRecord, expectedBaselines) {
  if (!hasExactKeys(releaseRecord, RELEASE_RECORD_KEYS)) {
    return false;
  }
  if (
    releaseRecord.schemaVersion !== 1 ||
    releaseRecord.program !== PROGRAM ||
    releaseRecord.reason !== 'hardening_program_in_progress' ||
    !baselinesEqual(releaseRecord.baselines, expectedBaselines) ||
    !arraysEqual(releaseRecord.exitGates, EXPECTED_EXIT_GATES) ||
    !Array.isArray(releaseRecord.securityPrerequisites) ||
    releaseRecord.securityPrerequisites.length !== 1
  ) {
    return false;
  }

  const ids = new Set();
  for (const prerequisite of releaseRecord.securityPrerequisites) {
    if (!prerequisiteShapeIsValid(prerequisite) || ids.has(prerequisite.id)) {
      return false;
    }
    ids.add(prerequisite.id);
  }
  return true;
}

export function evaluateReleaseDecision({
  packageManifest,
  releaseRecord,
  expectedBaselines = EXPECTED_BASELINES,
  prerequisiteVerification = null,
} = {}) {
  if (
    isPlainObject(releaseRecord) &&
    releaseRecord.program === PROGRAM &&
    releaseRecord.status === 'frozen'
  ) {
    return {
      allowed: false,
      code: 'RELEASE_FROZEN',
      message: FROZEN_MESSAGE,
    };
  }

  if (!releaseRecordShapeIsValid(releaseRecord, expectedBaselines)) {
    return blocked('RELEASE_RECORD_INVALID', 'release_record_invalid');
  }
  if (releaseRecord.status !== 'approved') {
    return blocked('RELEASE_STATUS_INVALID', 'release_status_invalid');
  }
  if (!isPlainObject(packageManifest) || packageManifest.private !== false) {
    return blocked('PACKAGE_NOT_PUBLIC', 'package_not_public');
  }
  if (
    releaseRecord.securityPrerequisites.length > 0 &&
    (prerequisiteVerification?.ok !== true ||
      !Array.isArray(prerequisiteVerification.failures) ||
      prerequisiteVerification.failures.length !== 0)
  ) {
    return blocked(
      'SECURITY_PREREQUISITES_UNVERIFIED',
      'security_prerequisites_unverified',
    );
  }

  return {
    allowed: true,
    code: 'RELEASE_ALLOWED',
    message: APPROVED_MESSAGE,
  };
}

function pathIsWithinRoot(root, candidate) {
  const pathFromRoot = relative(root, candidate);
  return (
    pathFromRoot !== '' &&
    !isAbsolute(pathFromRoot) &&
    pathFromRoot !== '..' &&
    !pathFromRoot.startsWith(`..${process.platform === 'win32' ? '\\' : '/'}`)
  );
}

async function canonicalFileInsideRoot({
  repositoryRoot,
  repositoryRootRealpath,
  path,
  realpath,
}) {
  if (!isNonEmptyString(path) || isAbsolute(path)) {
    throw new Error('path_not_repository_relative');
  }
  const absolutePath = resolve(repositoryRoot, path);
  if (!pathIsWithinRoot(repositoryRoot, absolutePath)) {
    throw new Error('path_outside_repository');
  }
  const canonicalPath = await realpath(absolutePath);
  if (!pathIsWithinRoot(repositoryRootRealpath, canonicalPath)) {
    throw new Error('canonical_path_outside_repository');
  }
  return canonicalPath;
}

function parseClosedJson(bytes, keys) {
  const parsed = JSON.parse(Buffer.from(bytes).toString('utf8'));
  if (!hasExactKeys(parsed, keys)) {
    throw new Error('json_schema_invalid');
  }
  return parsed;
}

function assessmentShapeIsValid(assessment) {
  return (
    assessment.schemaVersion === 1 &&
    assessment.identity === 'example_TemporaryKey.pfx' &&
    isNonEmptyString(assessment.assessment) &&
    isNonEmptyString(assessment.remediation) &&
    hasExactKeys(assessment.attestation, ASSESSMENT_ATTESTATION_KEYS) &&
    isNonEmptyString(assessment.attestation.artifactId) &&
    isNonEmptyString(assessment.attestation.path) &&
    isLowercaseSha256(assessment.attestation.sha256)
  );
}

function attestationShapeIsValid(attestation) {
  return (
    attestation.schemaVersion === 1 &&
    isNonEmptyString(attestation.artifactId) &&
    attestation.identity === 'example_TemporaryKey.pfx' &&
    isNonEmptyString(attestation.assessment) &&
    isNonEmptyString(attestation.remediation) &&
    Array.isArray(attestation.basis) &&
    attestation.basis.length > 0 &&
    attestation.basis.every(isNonEmptyString)
  );
}

function signingStateIsSatisfied(assessment, remediation) {
  return (
    (assessment === 'local_only_confirmed' && remediation === 'not_required') ||
    (assessment === 'trusted_beyond_local' &&
      (remediation === 'rotation_confirmed' ||
        remediation === 'revocation_confirmed'))
  );
}

export async function verifySecurityPrerequisites({
  repositoryRoot,
  prerequisites,
  readFile = readFileFromDisk,
  realpath = realpathFromDisk,
} = {}) {
  const failures = [];
  if (!Array.isArray(prerequisites)) {
    return {
      ok: false,
      failures: [{ id: '<securityPrerequisites>', code: 'INVALID_ARRAY' }],
    };
  }
  if (prerequisites.length === 0) {
    return { ok: false, failures: [{ id: 'windows_signing_identity', code: 'MISSING_PREREQUISITE' }] };
  }
  if (!isNonEmptyString(repositoryRoot) || !isAbsolute(repositoryRoot)) {
    return {
      ok: false,
      failures: [{ id: '<repositoryRoot>', code: 'INVALID_ROOT' }],
    };
  }

  let repositoryRootRealpath;
  try {
    repositoryRootRealpath = await realpath(repositoryRoot);
  } catch {
    return {
      ok: false,
      failures: [{ id: '<repositoryRoot>', code: 'ROOT_UNREADABLE' }],
    };
  }

  const seenIds = new Set();
  for (const prerequisite of prerequisites) {
    const id = isNonEmptyString(prerequisite?.id)
      ? prerequisite.id
      : '<unknown>';
    if (!prerequisiteShapeIsValid(prerequisite) || seenIds.has(id)) {
      failures.push({ id, code: 'PREREQUISITE_INVALID' });
      continue;
    }
    seenIds.add(id);

    try {
      const assessmentPath = await canonicalFileInsideRoot({
        repositoryRoot,
        repositoryRootRealpath,
        path: prerequisite.assessmentPath,
        realpath,
      });
      const artifactPath = await canonicalFileInsideRoot({
        repositoryRoot,
        repositoryRootRealpath,
        path: prerequisite.artifactPath,
        realpath,
      });
      const assessment = parseClosedJson(
        await readFile(assessmentPath),
        ASSESSMENT_KEYS,
      );
      const artifactBytes = await readFile(artifactPath);
      const attestation = parseClosedJson(artifactBytes, ATTESTATION_KEYS);
      const artifactSha256 = createHash('sha256')
        .update(artifactBytes)
        .digest('hex');

      if (!assessmentShapeIsValid(assessment)) {
        throw new Error('assessment_invalid');
      }
      if (!attestationShapeIsValid(attestation)) {
        throw new Error('attestation_invalid');
      }
      if (
        prerequisite.artifactId !== assessment.attestation.artifactId ||
        prerequisite.artifactId !== attestation.artifactId ||
        prerequisite.artifactPath !== assessment.attestation.path ||
        prerequisite.artifactSha256 !== assessment.attestation.sha256 ||
        prerequisite.artifactSha256 !== artifactSha256 ||
        assessment.identity !== attestation.identity ||
        assessment.assessment !== attestation.assessment ||
        assessment.remediation !== attestation.remediation
      ) {
        throw new Error('artifact_binding_mismatch');
      }
      if (
        !signingStateIsSatisfied(
          assessment.assessment,
          assessment.remediation,
        )
      ) {
        throw new Error('prerequisite_unsatisfied');
      }
    } catch {
      failures.push({ id, code: 'PREREQUISITE_UNVERIFIED' });
    }
  }

  return { ok: failures.length === 0, failures };
}

export function declaredYarnMajorMatchesTrackedLockfile(
  packageManifest,
  lockfile,
) {
  if (!isPlainObject(packageManifest) || typeof lockfile !== 'string') {
    return false;
  }
  const packageManagerMatches =
    /^yarn@1\.22\.22(?:\+sha512\.[A-Za-z0-9+/=]+)?$/.test(
      packageManifest.packageManager,
    );
  const hasV1Header =
    /^# THIS IS AN AUTOGENERATED FILE\. DO NOT EDIT THIS FILE DIRECTLY\.\r?\n# yarn lockfile v1(?:\r?\n|$)/.test(
      lockfile,
    );
  const hasBerryMetadata = /^__metadata:\s*$/m.test(lockfile);
  return packageManagerMatches && hasV1Header && !hasBerryMetadata;
}

async function readJson(path) {
  return JSON.parse(await readFileFromDisk(path, 'utf8'));
}

export async function runReleaseGuard({
  repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..'),
} = {}) {
  let packageManifest;
  let releaseRecord;
  try {
    packageManifest = await readJson(resolve(repositoryRoot, 'package.json'));
  } catch {
    return blocked('PACKAGE_MANIFEST_INVALID', 'package_manifest_invalid');
  }
  try {
    releaseRecord = await readJson(
      resolve(repositoryRoot, RELEASE_RECORD_PATH),
    );
  } catch {
    return blocked('RELEASE_RECORD_INVALID', 'release_record_invalid');
  }

  const frozenDecision = evaluateReleaseDecision({
    packageManifest,
    releaseRecord,
  });
  if (frozenDecision.code === 'RELEASE_FROZEN') {
    return frozenDecision;
  }

  let lockfile;
  try {
    lockfile = await readFileFromDisk(resolve(repositoryRoot, 'yarn.lock'), 'utf8');
  } catch {
    return blocked('YARN_LOCK_INVALID', 'yarn_lock_invalid');
  }
  if (!declaredYarnMajorMatchesTrackedLockfile(packageManifest, lockfile)) {
    return blocked('YARN_LOCK_INVALID', 'yarn_lock_invalid');
  }

  const prerequisiteVerification = await verifySecurityPrerequisites({
    repositoryRoot,
    prerequisites: releaseRecord?.securityPrerequisites,
  });
  return evaluateReleaseDecision({
    packageManifest,
    releaseRecord,
    prerequisiteVerification,
  });
}

const invokedPath = process.argv[1] ? resolve(process.argv[1]) : null;
if (invokedPath === fileURLToPath(import.meta.url)) {
  const decision = await runReleaseGuard();
  const output = decision.allowed ? process.stdout : process.stderr;
  output.write(`${decision.message}\n`);
  if (!decision.allowed) {
    process.exitCode = 1;
  }
}
