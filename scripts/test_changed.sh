#!/bin/bash

# ============================================================================
# Run only the suites related to files changed vs HEAD (staged, unstaged and
# untracked). A changed file maps to every tests/test_*.sh that mentions its
# basename; a changed test runs itself; a changed lib/ file runs the
# lib/**/tests/run_all.sh beside it. Quiet: failures plus a one-line summary.
# Falls back to tests/run_all.sh when nothing maps. Never touches vendor/.
# ============================================================================

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
changed=()
while IFS= read -r f; do
    [[ -n "$f" && -e "$f" && "$f" != vendor/* ]] && changed+=("$f")
done < <({ git diff --name-only HEAD 2>/dev/null || true; git ls-files --others --exclude-standard; } | sort -u)

if [[ ${#changed[@]} -eq 0 ]]; then echo "no changes vs HEAD: nothing to test"; exit 0; fi

declare -A picked=()
for f in "${changed[@]}"; do
    case "$f" in
        tests/run_all.sh) picked=(); picked[tests/run_all.sh]=1; break ;;
        tests/test_*.sh | */tests/run_all.sh) picked[$f]=1; continue ;;
        tests/*) ;;
        *.md | .github/* | .gitignore | .pre-commit-config.yaml) continue ;;
    esac
    base="$(basename "$f")"
    while IFS= read -r t; do picked[$t]=1; done \
        < <(grep -lF -- "$base" tests/test_*.sh 2>/dev/null || true)
    dir="$(dirname "$f")"
    while [[ "$dir" != "." && "$dir" == lib* ]]; do
        [[ -f "$dir/tests/run_all.sh" ]] && picked["$dir/tests/run_all.sh"]=1
        dir="$(dirname "$dir")"
    done
done

if [[ ${#picked[@]} -eq 0 ]]; then
    if [[ ${#changed[@]} -gt 0 ]] && ! printf '%s\n' "${changed[@]}" | grep -qvE '\.md$|^\.github/|^\.gitignore$|^\.pre-commit-config\.yaml$'; then
        echo "only docs/config changed: nothing to test"; exit 0
    fi
    echo "no mapped tests: running full suite"
    picked[tests/run_all.sh]=1
fi

rc=0
for t in "${!picked[@]}"; do
    if ! out="$(bash "$t" 2>&1)"; then rc=1; tail -n 25 <<<"$out"; echo "FAIL $t"; fi
done
echo "ran ${#picked[@]} suite(s): $([[ $rc -eq 0 ]] && echo pass || echo FAIL)"
exit "$rc"
