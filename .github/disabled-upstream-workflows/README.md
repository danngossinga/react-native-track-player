# Archived upstream automation

GitHub only loads workflows from `.github/workflows/`. These inherited workflows
are retained here for provenance and are not active in this fork:

- `nightly.yml`: npm publication; releases remain frozen.
- `publish-docs.yml`: publishes a documentation site not included in consolidation.
- `stale-bot.yml`: comments on and closes issues and pull requests.
- `delete-buildjet-cache.yml`: operates on upstream BuildJet infrastructure.

Their historical tool versions are not maintained as supported CI. Re-enabling
any of these requires an intentional scope decision and a fresh review.
`repository-security.yml` in the active workflow directory checks tracked source
files and publication guard regressions. The private stack RC additionally scans
the actual installed RNTP tarball; this archive does not qualify any platform.
