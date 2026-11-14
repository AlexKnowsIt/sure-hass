# AGENTS.md

Guidance for AI agents and contributors working on this repository.

This repository is a Home Assistant add-on that wraps the official Sure image
(`ghcr.io/we-promise/sure`). It does not build Sure from source.

## Goals, in priority order

1. **Standalone.** The add-on runs with nothing outside its own container:
   PostgreSQL and Redis are bundled, every secret is generated in `/data`.
   Never add a dependency on another add-on, an external database, or an
   external service that must exist for Sure to start.
2. **Secure and data-safe.** Users store bank credentials here. A failed start
   is always better than silent data loss or a weakened default.
3. **Backed up and restorable.** A normal Home Assistant backup alone must be
   enough to bring an install back on a fresh system, with all data and
   stored credentials readable.
4. **Easy to maintain.** Small diffs, no abstractions nobody asked for. Prefer
   deleting over adding.
5. **In sync with upstream Sure.** Follow upstream's behaviour and environment
   variables instead of re-implementing or patching them.

## Layout

| Path | Purpose |
| --- | --- |
| `sure/Dockerfile` | Upstream image + PostgreSQL (pinned major) + Redis. Asserts the upstream layout at build time. |
| `sure/run.sh` | Entrypoint (PID 1, root). Prepares `/data`, starts every service with reduced privileges, handles shutdown. |
| `sure/config.yaml` | Add-on manifest. Options: `onboarding_state`, `env_vars` only. |
| `sure/README.md` | User docs: backup, restore, migration, security notes. |
| `sure/CHANGELOG.md` | One entry per add-on version. |
| `.github/workflows/build.yaml` | PR build + smoke test; weekly upstream bump; image push. |
| `.github/bump.sh` | Points the add-on at a Sure release. |
| `DEBUG.md` | Troubleshooting a running add-on. |

## Hard rules

- **`/data` is the only persistent state.** Anything not in `/data` is lost on
  update. Never move, rename or reformat existing files in `/data`
  (`secret_key_base`, `postgres/`, `redis/`, `storage/`, `backups/`) without a
  migration path for existing installs.
- **Never change or regenerate `SECRET_KEY_BASE`** for an existing install. It
  derives the Active Record encryption keys and keys Sure's encrypted settings.
  Losing it makes stored provider credentials unreadable.
- **Encryption keys** (`ACTIVE_RECORD_ENCRYPTION_*`) are derived from the
  effective `SECRET_KEY_BASE` with upstream's own formula
  (`derived_keys` in upstream `lib/active_record_encryption_config.rb`). If
  upstream changes that formula, update `run.sh` to match, or existing data
  becomes unreadable.
- **PostgreSQL major is pinned** (`PG_MAJOR` in the Dockerfile). Changing it
  requires a dump/restore path for users; `run.sh` refuses a mismatched data
  directory on purpose.
- **Least privilege.** Only `run.sh` runs as root. Every long-running process
  goes through `drop` (setpriv). PostgreSQL and Redis listen on `127.0.0.1`
  only. Secrets are exported only to the Rails processes, after the database
  processes have started.
- **Never log secret values.** `run.sh` prints `env_vars` names only.
- **Fail loudly.** `set -euo pipefail` stays. Invalid input or a missing
  prerequisite exits non-zero instead of being skipped.
- **Shutdown order matters:** app, then Redis, then PostgreSQL with a fast
  shutdown. Keep the signal trap; `config.yaml` `timeout` must cover it.
- **No new add-on options** unless something cannot be done through `env_vars`.
  Upstream variables go through `env_vars`; user entries override defaults.

## Backup and restore

- **Keep `backup: cold`** in `config.yaml`. Home Assistant stops the add-on
  first, so the PostgreSQL files in `/data` are consistent. Switching to a hot
  backup requires a dump step that the backup waits for.
- **Everything needed to restore lives in `/data`**: database, Redis, uploads
  (`storage/`), `secret_key_base`. Never keep state or keys anywhere else, and
  never exclude any of these from the backup.
- **A backup without `secret_key_base` is useless** for encrypted data. Any
  change touching keys must keep old backups restorable, including restoring
  a dump under a `SECRET_KEY_BASE` passed through `env_vars`.
- **Pre-migration dump:** every start writes a `pg_dump` to `/data/backups`
  before migrations and keeps the 3 newest. A failed dump of an existing
  database aborts startup. Do not make this best-effort.
- **Restore paths are documented in `sure/README.md`** (dump restore, migration
  from an external PostgreSQL). Any change to `/data` layout, database name,
  user or PostgreSQL major must update those steps and keep them working.
- **Shutdown must be clean** (CI checks exit code 0), otherwise a cold backup
  may capture a database that needs crash recovery.

## Staying in sync with Sure

- The weekly workflow picks the latest stable upstream release (no
  prereleases), checks the image exists on ghcr.io, builds, smoke-tests,
  pushes images, then commits the bump to `main`. Images must be pushed before
  `config.yaml` changes on `main`, because Home Assistant reads it from there.
- Manual bump: `.github/bump.sh <sure_version>`, then add a CHANGELOG entry.
- On every upstream bump, check upstream release notes and these upstream files
  for changes that affect `run.sh`:
  - `bin/docker-entrypoint`, `config/database.yml` (env variable names)
  - `config/initializers/active_record_encryption.rb`,
    `lib/active_record_encryption_config.rb` (key derivation, warnings)
  - `compose.example.yml` (new required services or variables)
- Do not patch upstream code in the image. If upstream needs a change, it
  belongs upstream.

## Versioning

`version` in `config.yaml` is `<addon_version>-<sure_version>`. Bump the left
half (semver) for add-on changes, with a CHANGELOG entry. Breaking changes are
marked **BREAKING** and explain the migration.

## Checks before pushing

- `bash -n sure/run.sh` and `shellcheck sure/run.sh`.
- For changes to `run.sh` or the Dockerfile, CI builds both architectures and
  runs the smoke test (two starts on the same `/data`, clean exit, dump
  written). It must stay green; never weaken or skip it.
- For changes affecting backup or restore, test a restore by hand: dump,
  restore with the README commands into a fresh `/data`, start, log in, and
  check that a stored provider credential is still readable. CI covers the
  database part (dump, restore, marker row survives), not encrypted values.
- Update `sure/README.md` when user-visible behaviour, security notes or
  restore steps change.

## Style

- Comments explain *why*, not *what*.
- Shell: bash, quoted variables, no new tools in the image unless required.
- Commits, docs and comments in English.
