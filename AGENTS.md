# Agent instructions

Guidance for AI coding agents (and humans) working in this repository.

## Running checks

```sh
shellcheck lib.sh process_mp3merge.sh runscript.sh hashupdate  # CI lint job
bats tests/                                                     # CI test job (lib.sh unit tests)
```

The Docker workflows (`ci.yml` build job, `publish.yml`) cannot be run
locally in this container — verify via the CI checks on the PR.

## Git hooks

Local hooks run through [lefthook](https://github.com/evilmartians/lefthook), a
single static binary (this repo has no package-manager hook install). Install
it, then register the hooks:

```sh
curl -fsSL -o /tmp/lefthook.gz \
  https://github.com/evilmartians/lefthook/releases/download/v2.1.12/lefthook_2.1.12_Linux_x86_64.gz
gunzip /tmp/lefthook.gz && chmod +x /tmp/lefthook && mv /tmp/lefthook ~/.local/bin/
# (arm64/macOS: pick the matching `lefthook_2.1.12_<OS>_<ARCH>` release asset)
PATH="$HOME/.local/bin:$PATH" lefthook install   # idempotent; re-run after a fresh clone
```

`lefthook.yml` pins the shared `MartinCa/lefthook-configs` fragments at `v2.0.0`:
- **pre-commit** — `langs/shell.yml` runs `shfmt -w` and a *blocking* `shellcheck`
  on staged `*.sh`/`*.bash` (re-staging fixed files); `lefthook-shared.yml`
  secret-scans the staged diff with `betterleaks` (blocks the commit on a leak)
  and audits staged `.github/workflows/*` files with `zizmor` (blocks on a
  finding).
- **commit-msg** — `commit-msg.yml` enforces Conventional Commits, e.g.
  `feat: ...`, `fix(api): ...`.

`lefthook-local.yml` is a repo-wide override layer (not a personal one): it
excludes `.github/workflows/bump.yml` from the `zizmor` hook scan because that
workflow has a pre-existing HIGH zizmor finding (GitHub App token used without
scoped `permission-*` inputs). It remains visible in CI's non-blocking zizmor
SARIF upload, and its comment carries the TODO to fix and remove the exclusion.

Coverage vs. CI (`ci.yml`): shellcheck is enforced in **both** the hook and the
`lint` job (`shellcheck lib.sh process_mp3merge.sh runscript.sh hashupdate`);
the hook covers `*.sh`/`*.bash` while CI additionally names the extensionless
`hashupdate` script explicitly, so keep it lint-clean. `shfmt`, `betterleaks`,
and the commit-msg check are **hook-only** — CI does not run them. `zizmor` runs
in both places but in CI it only uploads a SARIF report to code scanning
(non-blocking, not a merge gate); the pre-commit hook is the blocking check.
`tests/lib.bats` is outside both the hook's `*.sh`/`*.bash` glob and CI's explicit
`shellcheck` list, so it is not linted — a known (informational) parity gap; it is
still exercised via `bats tests/`.

Two hook tools must be on `PATH`: `betterleaks` (secret scan, install per its
project README) and `zizmor` (workflow audit, install from zizmor.sh). If a tool
is missing, `LEFTHOOK=0 git commit` skips the hooks entirely — a pragmatic escape
hatch for restricted setups, not a way to dodge the gates. `lefthook dump` shows
the merged hook config; `lefthook run pre-commit --all-files` verifies it.
