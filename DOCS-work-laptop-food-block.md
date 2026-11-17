# Work laptop food-delivery block

`work_laptop/food_block/` blocks food and quick-grocery delivery sites
(Uber Eats, Wolt, Glovo, Pyszne, Bolt Food, Delio, Jush, Lisek, Frisco, ...)
on the Ubuntu work laptop. The full list is `domains.txt`.

## Install (on the laptop)

```
curl -fsSL https://raw.githubusercontent.com/kuhyx/digital-wellbeing/<rev>/work_laptop/food_block/bootstrap.sh | sudo bash -s <rev>
```

`<rev>` is a commit hash. Re-running with a newer hash is the update path.
There is deliberately no uninstall script.

## Layers

| layer | file | reverted by |
|---|---|---|
| `/etc/hosts` block, `0.0.0.0` and `::` per name | `lib/fb_hosts.sh` | `food-block.path` (seconds), timer |
| Chromium-family managed policy: `URLBlocklist`, DoH off, built-in DNS client off, Tor off | `lib/fb_policies.sh` | timer (5 min), `chattr +i` |
| Firefox `policies.json`: `WebsiteFilter`, DoH off and locked | `lib/fb_policies.sh` | timer, `chattr +i` |

Chromium policy dirs: a fixed list (Chrome, Chromium/Helium, snap Chromium,
Brave, Thorium guesses) plus every `/etc/.../policies` string found in large
executables under `/opt`, `/usr/lib`, `/usr/bin`. That scan picks up forks the
list misses on the next tick. Snap/Flatpak browsers get a journal warning.

## Failure modes

- `apply.sh` fails loudly: any error exits non-zero and shows as a failed
  `food-block.service`. Layers already written stay.
- A `chattr` failure only warns: the timer is the guarantee, `+i` slows down
  manual edits.

## Tests

- `tests/test_food_block.sh`: apply against a scratch root (`FOOD_BLOCK_ROOT`).
- Verified on 2026-11-17 in an Ubuntu 24.04 container running systemd with
  Chrome 158: install, `ERR_BLOCKED_BY_ADMINISTRATOR` on ubereats.com and
  jush.pl, uber.com still loads, hosts edit restored by the path unit within
  3 s. Not yet verified on the laptop itself.
