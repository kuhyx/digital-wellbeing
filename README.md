# digital-wellbeing

Self-commitment tooling: a pacman/makepkg wrapper that refuses blocked
packages, a midnight shutdown timer, browser extension seeding (LeechBlock,
uBlock), music-parallelism limits, and a night lockdown.

Extracted from the `testsAndMisc` monorepo with full history (88 commits).

## Expected checkout location

Monorepo scripts invoke this repo by absolute path, resolved as
`<invoking user's home>/digital-wellbeing`:

```bash
git clone https://github.com/kuhyx/digital-wellbeing ~/digital-wellbeing
```

A missing checkout fails loudly with a clone instruction rather than silently
skipping the installer.

## Layout

| Path | Role |
| --- | --- |
| `pacman/` | The pacman + makepkg wrappers, their policy lists and installers |
| `lib/` | Per-phase libraries from the 250-line-cap splits, each with `lib/tests/` |
| `tests/` | The six regression suites, plus `tests/run_all.sh` |
| `vendor/` | Verbatim copy of the monorepo's shared `lib/common.sh` |
| `virtualbox/` | VirtualBox hosts enforcement |
| `systemd/` | Unit files |

## Tests

```bash
./tests/run_all.sh
```

Runs the six top-level suites and discovers every `lib/tests/run_all.sh`.
None needs root, pacman or an Arch userland — they run bare on an Ubuntu CI
runner, which is why this repo has no `arch-tests` job even though five of
these suites lived in the monorepo's.

## `vendor/common.sh`

The four entry-point scripts (`music_parallelism.sh`,
`youtube-music-wrapper.sh`, `setup_midnight_shutdown.sh`,
`setup_night_lockdown.sh`) need `log`, `log_message`, `require_root` and
`set_actual_user_vars` from the monorepo's `linux_configuration/lib/common.sh`.

That file is **vendored verbatim** rather than trimmed to those four:
`set_actual_user_vars` calls `get_actual_user` and `get_actual_user_home`, so
a trimmed copy would break silently. It is deliberately duplicated — the two
copies may diverge, and that is fine now that they are separate repos. Do not
"fix" this by re-coupling them to the monorepo.

It lives in `vendor/` rather than `lib/` on purpose: `lib/` is the unit's own
split libraries, and `test_music_parallelism.sh` copies that whole directory
into a scratch worktree while stubbing the shared lib. Putting both in one
directory made the real `common.sh` collide with the stub.

## After installing the pacman wrapper

`install_pacman_wrapper.sh` writes a drift manifest to
`/var/lib/pacman-wrapper/source.sha256` containing **absolute** source paths.
Moving this code invalidates that manifest, and `check_and_enable_services.sh`
in the monorepo then reports a permanent "stale or tampered" error even when
the deployed wrapper is byte-correct. Re-run the installer once after cloning
to regenerate it.
