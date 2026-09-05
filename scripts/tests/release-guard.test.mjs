import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import test from 'node:test';

const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const guardPath = join(repositoryRoot, 'scripts/release-guard.mjs');
const frozenToken = 'RELEASE_BLOCKED program=008 status=frozen';
const expectedLockSha256 =
  'fb751ae2be74717854426fe15d3dbea0825343f5c861a5d7612c0ae0192b54de';
const expectedBaselines = {
  proxy: '176b5c8a8183c53343d3a6ec82595352c5d970c5',
  player: 'edafba80fa1c5cbf64bb0c52ce4104a3cf9cc5f9',
  rntp: '9e67ef896b2fdcecae2aaad5cd357e56a83fa629',
};
const expectedExitGates = [
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
];

function loadGuard() {
  return import(pathToFileURL(guardPath).href);
}

function releaseRecord(overrides = {}) {
  return {
    schemaVersion: 1,
    program: '008',
    status: 'approved',
    baselines: { ...expectedBaselines },
    reason: 'hardening_program_in_progress',
    exitGates: [...expectedExitGates],
    securityPrerequisites: [],
    ...overrides,
  };
}

function sha256(bytes) {
  return createHash('sha256').update(bytes).digest('hex');
}

function writeJson(path, value) {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`);
}

function createBoundPrerequisite(
  repositoryRootPath,
  {
    assessment = 'local_only_confirmed',
    remediation = 'not_required',
    artifactId = 'program-008/windows-signing-identity/v1',
    artifactPath = '.release/windows-signing-identity-attestation.json',
    assessmentPath = '.release/windows-signing-identity-assessment.json',
    writeArtifact = true,
    attestationArtifactId = artifactId,
    assessmentArtifactId = artifactId,
    assessmentArtifactPath = artifactPath,
    assessmentSha256,
    prerequisiteArtifactId = artifactId,
    prerequisiteArtifactPath = artifactPath,
    prerequisiteSha256,
    assessmentExtra = {},
    prerequisiteExtra = {},
  } = {},
) {
  const attestation = {
    schemaVersion: 1,
    artifactId: attestationArtifactId,
    identity: 'example_TemporaryKey.pfx',
    assessment,
    remediation,
    basis: ['synthetic release-guard fixture'],
  };
  const artifactBytes = Buffer.from(`${JSON.stringify(attestation, null, 2)}\n`);
  const actualSha256 = sha256(artifactBytes);

  if (writeArtifact) {
    const absoluteArtifactPath = resolve(repositoryRootPath, artifactPath);
    mkdirSync(dirname(absoluteArtifactPath), { recursive: true });
    writeFileSync(absoluteArtifactPath, artifactBytes);
  }

  const assessmentRecord = {
    schemaVersion: 1,
    identity: 'example_TemporaryKey.pfx',
    assessment,
    remediation,
    attestation: {
      artifactId: assessmentArtifactId,
      path: assessmentArtifactPath,
      sha256: assessmentSha256 ?? actualSha256,
    },
    ...assessmentExtra,
  };
  writeJson(resolve(repositoryRootPath, assessmentPath), assessmentRecord);

  return {
    prerequisite: {
      id: 'windows_signing_identity',
      assessmentPath,
      artifactId: prerequisiteArtifactId,
      artifactPath: prerequisiteArtifactPath,
      artifactSha256: prerequisiteSha256 ?? actualSha256,
      ...prerequisiteExtra,
    },
    actualSha256,
  };
}

function run(command, args, cwd) {
  return spawnSync(command, args, {
    cwd,
    encoding: 'utf8',
    env: {
      ...process.env,
      npm_config_cache: join(cwd, '.npm-cache'),
      npm_config_update_notifier: 'false',
    },
  });
}

function commandOutput(result) {
  return `${result.stdout ?? ''}${result.stderr ?? ''}`;
}

function createLifecycleFixture() {
  const root = mkdtempSync(join(tmpdir(), 'program-008-rntp-release-'));
  mkdirSync(join(root, 'scripts'), { recursive: true });
  mkdirSync(join(root, '.release'), { recursive: true });
  copyFileSync(guardPath, join(root, 'scripts/release-guard.mjs'));
  writeFileSync(
    join(root, 'scripts/sentinel.mjs'),
    "import { writeFileSync } from 'node:fs';\nwriteFileSync(`sentinel-${process.argv[2]}`, 'called');\n",
  );
  writeJson(join(root, '.release/program-008.json'),
    releaseRecord({ status: 'frozen' }),
  );
  writeJson(join(root, 'package.json'), {
    name: 'program-008-release-fixture',
    version: '1.2.3',
    private: false,
    scripts: {
      'release:guard': 'node scripts/release-guard.mjs',
      preversion: 'npm run release:guard',
      version: 'node scripts/sentinel.mjs version',
      prepublishOnly: 'npm run release:guard',
      publish: 'node scripts/sentinel.mjs publish',
      'publish:git':
        'npm run release:guard && node scripts/sentinel.mjs publish-git',
      'publish:npm':
        'npm run release:guard && node scripts/sentinel.mjs publish-npm',
      nightly: 'npm run release:guard && node scripts/sentinel.mjs nightly',
    },
  });
  return root;
}

test('declaredYarnMajorMatchesTrackedLockfile accepts Yarn 1.22.22 with a v1 lock only', async () => {
  const { declaredYarnMajorMatchesTrackedLockfile } = await loadGuard();
  const packageManager =
    'yarn@1.22.22+sha512.a6b2f7906b721bba3d67d4aff083df04dad64c399707841b7acf00f6b133b7ac24255f2652fa22ae3534329dc6180534e98d17432037ff6fd140556e2bb3137e';
  const v1Lock =
    '# THIS IS AN AUTOGENERATED FILE. DO NOT EDIT THIS FILE DIRECTLY.\n# yarn lockfile v1\n\n';
  const berryLock =
    '# This file is generated by running "yarn install" inside your project.\n\n__metadata:\n  version: 6\n';

  assert.equal(
    declaredYarnMajorMatchesTrackedLockfile({ packageManager }, v1Lock),
    true,
  );
  assert.equal(
    declaredYarnMajorMatchesTrackedLockfile({ packageManager }, berryLock),
    false,
  );
  assert.equal(
    declaredYarnMajorMatchesTrackedLockfile(
      { packageManager: 'yarn@4.9.2' },
      v1Lock,
    ),
    false,
  );
});

test('tracked package manager and lockfile are the immutable Yarn 1 baseline', async () => {
  const { declaredYarnMajorMatchesTrackedLockfile } = await loadGuard();
  const packageManifest = JSON.parse(
    readFileSync(join(repositoryRoot, 'package.json'), 'utf8'),
  );
  const lockfile = readFileSync(join(repositoryRoot, 'yarn.lock'));

  assert.equal(packageManifest.packageManager.startsWith('yarn@1.22.22+'), true);
  assert.equal(
    declaredYarnMajorMatchesTrackedLockfile(
      packageManifest,
      lockfile.toString('utf8'),
    ),
    true,
  );
  assert.equal(sha256(lockfile), expectedLockSha256);
});

test('release decision blocks every unsafe shared state and allows only approved public state', async () => {
  const { evaluateReleaseDecision } = await loadGuard();
  const publicPackage = { private: false };

  for (const isPrivate of [true, false]) {
    const decision = evaluateReleaseDecision({
      packageManifest: { private: isPrivate },
      releaseRecord: releaseRecord({ status: 'frozen' }),
    });
    assert.deepEqual(decision, {
      allowed: false,
      code: 'RELEASE_FROZEN',
      message: frozenToken,
    });
  }

  const blockedCases = [
    {
      name: 'approved private package',
      packageManifest: { private: true },
      releaseRecord: releaseRecord(),
    },
    {
      name: 'missing release record',
      packageManifest: publicPackage,
      releaseRecord: undefined,
    },
    {
      name: 'malformed release record',
      packageManifest: publicPackage,
      releaseRecord: { ...releaseRecord(), unexpected: true },
    },
    {
      name: 'missing prerequisite array',
      packageManifest: publicPackage,
      releaseRecord: (() => {
        const value = releaseRecord();
        delete value.securityPrerequisites;
        return value;
      })(),
    },
    {
      name: 'baseline mismatch',
      packageManifest: publicPackage,
      releaseRecord: releaseRecord({
        baselines: { ...expectedBaselines, rntp: '0'.repeat(40) },
      }),
    },
  ];

  for (const fixture of blockedCases) {
    assert.equal(
      evaluateReleaseDecision(fixture).allowed,
      false,
      fixture.name,
    );
  }

  assert.equal(evaluateReleaseDecision({
    packageManifest: publicPackage,
    releaseRecord: releaseRecord(),
  }).allowed, false, 'approval cannot omit the mandatory signing prerequisite');
});

test('cannot move or rename all matching signing artifacts to bypass the fixed identity contract', async () => {
  const { verifySecurityPrerequisites } = await loadGuard();
  for (const options of [
    { artifactId: 'another-identity/v1' },
    { artifactPath: '.release/another-attestation.json' },
    { assessmentPath: '.release/another-assessment.json' },
  ]) {
    const root = mkdtempSync(join(tmpdir(), 'program-008-fixed-identity-'));
    const { prerequisite } = createBoundPrerequisite(root, options);
    assert.equal((await verifySecurityPrerequisites({ repositoryRoot: root, prerequisites: [prerequisite] })).ok, false);
  }
});

test('real removed identity stays byte-bound and unresolved for any future unfreeze', async () => {
  const { evaluateReleaseDecision, verifySecurityPrerequisites } = await loadGuard();
  const record = JSON.parse(readFileSync(join(repositoryRoot, '.release/program-008.json'), 'utf8'));
  assert.equal(record.status, 'frozen');
  assert.equal(record.securityPrerequisites.length, 1);
  const prerequisite = record.securityPrerequisites[0];
  const artifactBytes = readFileSync(join(repositoryRoot, prerequisite.artifactPath));
  const attestation = JSON.parse(artifactBytes);
  const assessment = JSON.parse(readFileSync(join(repositoryRoot, prerequisite.assessmentPath), 'utf8'));
  assert.equal(sha256(artifactBytes), prerequisite.artifactSha256);
  assert.equal(sha256(artifactBytes), assessment.attestation.sha256);
  assert.equal(attestation.assessment, 'unknown');
  assert.equal(attestation.remediation, 'pending');
  const verification = await verifySecurityPrerequisites({ repositoryRoot, prerequisites: record.securityPrerequisites });
  assert.equal(verification.ok, false);
  assert.equal(evaluateReleaseDecision({ packageManifest: { private: false }, releaseRecord: { ...record, status: 'approved' }, prerequisiteVerification: verification }).allowed, false);
});

test('non-empty security prerequisites require verified, satisfied artifact evidence', async (t) => {
  const { evaluateReleaseDecision, verifySecurityPrerequisites } =
    await loadGuard();

  await t.test('pending and hashless prerequisites block', async () => {
    const root = mkdtempSync(join(tmpdir(), 'program-008-prerequisite-'));
    const pending = createBoundPrerequisite(root, {
      assessment: 'unknown',
      remediation: 'pending',
    }).prerequisite;
    const pendingVerification = await verifySecurityPrerequisites({
      repositoryRoot: root,
      prerequisites: [pending],
    });
    assert.equal(pendingVerification.ok, false);

    const hashless = { ...pending };
    delete hashless.artifactSha256;
    const hashlessVerification = await verifySecurityPrerequisites({
      repositoryRoot: root,
      prerequisites: [hashless],
    });
    assert.equal(hashlessVerification.ok, false);
  });

  await t.test('missing assessment or artifact bytes block', async () => {
    const missingAssessmentRoot = mkdtempSync(
      join(tmpdir(), 'program-008-prerequisite-'),
    );
    const prerequisite = createBoundPrerequisite(missingAssessmentRoot)
      .prerequisite;
    prerequisite.assessmentPath = '.release/does-not-exist.json';
    assert.equal(
      (
        await verifySecurityPrerequisites({
          repositoryRoot: missingAssessmentRoot,
          prerequisites: [prerequisite],
        })
      ).ok,
      false,
    );

    const missingArtifactRoot = mkdtempSync(
      join(tmpdir(), 'program-008-prerequisite-'),
    );
    const missingArtifact = createBoundPrerequisite(missingArtifactRoot, {
      writeArtifact: false,
    }).prerequisite;
    assert.equal(
      (
        await verifySecurityPrerequisites({
          repositoryRoot: missingArtifactRoot,
          prerequisites: [missingArtifact],
        })
      ).ok,
      false,
    );
  });

  await t.test('canonical paths cannot escape the repository', async () => {
    const root = mkdtempSync(join(tmpdir(), 'program-008-prerequisite-'));
    const outside = mkdtempSync(join(tmpdir(), 'program-008-outside-'));
    const fixture = createBoundPrerequisite(root);
    const outsideArtifact = join(outside, 'attestation.json');
    writeFileSync(
      outsideArtifact,
      readFileSync(resolve(root, fixture.prerequisite.artifactPath)),
    );
    const linkPath = join(root, '.release/escaped-attestation.json');
    symlinkSync(outsideArtifact, linkPath);
    fixture.prerequisite.artifactPath = relative(root, linkPath);
    assert.equal(
      (
        await verifySecurityPrerequisites({
          repositoryRoot: root,
          prerequisites: [fixture.prerequisite],
        })
      ).ok,
      false,
    );

    const assessmentEscape = {
      ...fixture.prerequisite,
      assessmentPath: '../outside-assessment.json',
    };
    assert.equal(
      (
        await verifySecurityPrerequisites({
          repositoryRoot: root,
          prerequisites: [assessmentEscape],
        })
      ).ok,
      false,
    );
  });

  await t.test('artifact ID, path, hash, and bytes must match both records', async () => {
    const cases = [
      { assessmentArtifactId: 'program-008/wrong-id/v1' },
      { assessmentArtifactPath: '.release/wrong-path.json' },
      { assessmentSha256: '0'.repeat(64) },
      { prerequisiteSha256: '0'.repeat(64) },
      { attestationArtifactId: 'program-008/wrong-attestation-id/v1' },
    ];
    for (const options of cases) {
      const root = mkdtempSync(join(tmpdir(), 'program-008-prerequisite-'));
      const prerequisite = createBoundPrerequisite(root, options).prerequisite;
      assert.equal(
        (
          await verifySecurityPrerequisites({
            repositoryRoot: root,
            prerequisites: [prerequisite],
          })
        ).ok,
        false,
        JSON.stringify(options),
      );
    }
  });

  await t.test('unknown fields and unknown prerequisite IDs block', async () => {
    const root = mkdtempSync(join(tmpdir(), 'program-008-prerequisite-'));
    const unknownAssessment = createBoundPrerequisite(root, {
      assessmentExtra: { unexpected: true },
    }).prerequisite;
    assert.equal(
      (
        await verifySecurityPrerequisites({
          repositoryRoot: root,
          prerequisites: [unknownAssessment],
        })
      ).ok,
      false,
    );

    const unknownIdRoot = mkdtempSync(
      join(tmpdir(), 'program-008-prerequisite-'),
    );
    const unknownId = createBoundPrerequisite(unknownIdRoot).prerequisite;
    unknownId.id = 'unknown_prerequisite';
    assert.equal(
      (
        await verifySecurityPrerequisites({
          repositoryRoot: unknownIdRoot,
          prerequisites: [unknownId],
        })
      ).ok,
      false,
    );
  });

  await t.test('only bound, gate-defined satisfied states allow approval', async () => {
    const states = [
      ['local_only_confirmed', 'not_required'],
      ['trusted_beyond_local', 'rotation_confirmed'],
      ['trusted_beyond_local', 'revocation_confirmed'],
    ];
    for (const [assessment, remediation] of states) {
      const root = mkdtempSync(join(tmpdir(), 'program-008-prerequisite-'));
      const prerequisite = createBoundPrerequisite(root, {
        assessment,
        remediation,
      }).prerequisite;
      const verification = await verifySecurityPrerequisites({
        repositoryRoot: root,
        prerequisites: [prerequisite],
      });
      assert.deepEqual(verification, { ok: true, failures: [] });

      const record = releaseRecord({ securityPrerequisites: [prerequisite] });
      assert.equal(
        evaluateReleaseDecision({
          packageManifest: { private: false },
          releaseRecord: record,
        }).allowed,
        false,
        'non-empty prerequisites cannot bypass verification',
      );
      assert.equal(
        evaluateReleaseDecision({
          packageManifest: { private: false },
          releaseRecord: record,
          prerequisiteVerification: verification,
        }).allowed,
        true,
      );
    }
  });
});

test('tracked package scripts guard every version, push, tag, and publication entry point first', () => {
  const packageManifest = JSON.parse(
    readFileSync(join(repositoryRoot, 'package.json'), 'utf8'),
  );
  const { scripts } = packageManifest;

  assert.equal(packageManifest.private, true);
  assert.equal(packageManifest.version, '4.1.2-bface-pingpong.0');
  assert.equal(
    packageManifest.repository.url,
    'https://github.com/doublesymmetry/react-native-track-player.git',
  );
  assert.equal(scripts['release:guard'], 'node scripts/release-guard.mjs');
  assert.equal(
    scripts['test:release'],
    'node --test scripts/tests/release-guard.test.mjs',
  );
  assert.equal(scripts.preversion, 'yarn release:guard && yarn lint');
  assert.equal(scripts.prepublishOnly, 'yarn release:guard && yarn lint');
  assert.equal(
    scripts.version,
    'yarn format && git add -A src && yarn changelog && git add CHANGELOG.md',
  );
  assert.equal(
    scripts.postversion,
    "if [[ ${npm_package_version} != *'nightly'* ]]; then yarn publish:git && yarn publish:npm; fi",
  );
  assert.equal(
    scripts['publish:git'],
    'yarn release:guard && git push && git push --tags',
  );
  assert.equal(
    scripts['publish:npm'],
    'yarn release:guard && yarn prepare && npm publish --access public',
  );
});

test('upstream automation is inactive and archived nightly retains its publication guard', () => {
  for (const name of ['nightly.yml', 'publish-docs.yml', 'stale-bot.yml', 'delete-buildjet-cache.yml']) {
    assert.equal(existsSync(join(repositoryRoot, '.github/workflows', name)), false);
    assert.equal(existsSync(join(repositoryRoot, '.github/disabled-upstream-workflows', name)), true);
  }
  const workflow = readFileSync(
    join(repositoryRoot, '.github/disabled-upstream-workflows/nightly.yml'),
    'utf8',
  );
  const install = workflow.indexOf('run: yarn install --frozen-lockfile');
  const guard = workflow.indexOf('run: yarn release:guard');
  const build = workflow.indexOf('run: yarn build');
  const extractVersion = workflow.indexOf('name: Extract Version');
  const mutateVersion = workflow.indexOf('run: yarn version');
  const publish = workflow.indexOf('uses: JS-DevTools/npm-publish@v1');

  assert.ok(install >= 0);
  assert.ok(guard > install);
  assert.ok(build > guard);
  assert.ok(extractVersion > guard);
  assert.ok(mutateVersion > guard);
  assert.ok(publish > guard);
});

test('fixture release entry points stop before version or remote-operation sentinels', () => {
  const root = createLifecycleFixture();
  const originalPackage = readFileSync(join(root, 'package.json'));

  const version = run(
    'npm',
    ['version', '--no-git-tag-version', 'patch'],
    root,
  );
  assert.notEqual(version.status, 0);
  assert.match(commandOutput(version), new RegExp(frozenToken));
  assert.deepEqual(readFileSync(join(root, 'package.json')), originalPackage);
  assert.equal(existsSync(join(root, 'sentinel-version')), false);

  const publishDryRun = run('npm', ['publish', '--dry-run'], root);
  assert.notEqual(publishDryRun.status, 0);
  assert.match(commandOutput(publishDryRun), new RegExp(frozenToken));
  assert.equal(existsSync(join(root, 'sentinel-publish')), false);

  for (const [script, sentinel] of [
    ['publish:git', 'sentinel-publish-git'],
    ['publish:npm', 'sentinel-publish-npm'],
    ['nightly', 'sentinel-nightly'],
  ]) {
    const result = run('npm', ['run', script], root);
    assert.notEqual(result.status, 0, script);
    assert.match(commandOutput(result), new RegExp(frozenToken), script);
    assert.equal(existsSync(join(root, sentinel)), false, script);
  }
});
