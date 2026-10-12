#!/usr/bin/env bash
# Run the gate on one commit, in a throwaway worktree outside this checkout.
#
# Why this file exists: the gate was being launched by a fresh script written
# for the occasion and reviewed by nobody. One of those linked
# dashboard/node_modules in from the main checkout, Turbopack refused a link
# that points outside the worktree root, and "next build" failed for a reason
# that had nothing to do with the commit under test. A launcher decides what the
# gate actually sees, so it belongs in the repository with the rest of the
# enforcement (ARCHITECTURE 11).
#
# What it never does: copy, link or read authority/.env, dashboard/.env.local,
# any *.pem, or anything under authority/keys/. Those are made by hand on the
# machine that needs them and never travel into a worktree. The worktree is
# checked for them before gate.sh starts and the run fails if one is there.
#
# Usage: scripts/gate-at-commit.sh <commit>
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

if [ "$#" -ne 1 ]; then
	echo "usage: scripts/gate-at-commit.sh <commit>" >&2
	exit 2
fi

COMMIT="$(git rev-parse --verify "$1^{commit}" 2>/dev/null)" || {
	echo "gate-at-commit: no such commit: $1" >&2
	exit 2
}

# A dirty checkout and a worktree disagree about what is under test, and the
# header would then name a commit that is not what ran.
DIRTY="$(git status --porcelain --untracked-files=no | wc -l)"
if [ "$DIRTY" -ne 0 ]; then
	echo "gate-at-commit: the checkout has $DIRTY tracked change(s), commit or stash them first" >&2
	exit 2
fi

SHORT="$(git rev-parse --short "$COMMIT")"
WT="${TMPDIR:-/tmp}/quiethop-gate-$SHORT.$$"
TARGET="${TMPDIR:-/tmp}/quiethop-gate-target-$SHORT.$$"
LOG="$TARGET/gate.log"

cleanup() {
	git worktree remove --force "$WT" >/dev/null 2>&1 || rm -rf "$WT"
	rm -rf "$TARGET"
}
trap cleanup EXIT

mkdir -p "$TARGET" || exit 1
git worktree add --detach "$WT" "$COMMIT" >/dev/null || exit 1

# A target directory of its own, so the run cannot pass on something the main
# checkout built earlier.
export CARGO_TARGET_DIR="$TARGET"
# Byte order in sorts and character classes, so a check that greps a class
# behaves here the way it does for whoever wrote it.
export LC_ALL=C.UTF-8

printf 'commit:  %s\n' "$COMMIT"
printf 'subject: %s\n' "$(git log -1 --pretty=%s "$COMMIT")"
printf 'tracked changes in the checkout: %s\n' "$DIRTY"
printf 'worktree: %s\n' "$WT"
echo

# A real install inside the worktree, because the dashboard steps mean nothing
# without one and a link to the main checkout's copy is what Turbopack refuses.
if ! (cd "$WT/dashboard" && npm ci); then
	echo "gate-at-commit: npm ci failed, so the dashboard steps would prove nothing" >&2
	exit 1
fi

# The secrets check, immediately before the gate. Installed packages under
# node_modules ship their own test fixtures, so they are left out of the *.pem
# sweep: the rule is about this project's own keys and environment files.
found=0
for p in authority/.env dashboard/.env.local authority/keys; do
	if [ -e "$WT/$p" ]; then
		echo "gate-at-commit: $p is in the worktree and must never be" >&2
		found=1
	fi
done
while IFS= read -r pem; do
	echo "gate-at-commit: ${pem#"$WT/"} is in the worktree and must never be" >&2
	found=1
done < <(find "$WT" -name '*.pem' -not -path "$WT/dashboard/node_modules/*" -print)
if [ "$found" -ne 0 ]; then
	exit 1
fi

bash "$WT/gate.sh" 2>&1 | tee "$LOG"
status="${PIPESTATUS[0]}"

echo
grep -E '^GATE (PASS|FAIL)' "$LOG" | tail -1
exit "$status"
