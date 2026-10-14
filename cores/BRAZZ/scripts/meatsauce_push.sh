#!/usr/bin/env bash
# Publish this project's HEAD to github.com/meathax/meatsauce under cores/BRAZZ.
# The local repo keeps the project at its root; this grafts HEAD's tree into
# meatsauce's main tree at cores/BRAZZ/ and pushes one commit on top of main.
# Usage: git pushms   (alias for: bash scripts/meatsauce_push.sh)
set -euo pipefail

remote=origin
branch=main
prefix=cores/BRAZZ

cd "$(git rev-parse --show-toplevel)"
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "note: uncommitted changes are not published (only HEAD)" >&2
fi

git fetch -q "$remote" "$branch"
base=$(git rev-parse "$remote/$branch")
head=$(git rev-parse HEAD)

export GIT_INDEX_FILE="$(git rev-parse --git-dir)/meatsauce-index"
trap 'rm -f "$GIT_INDEX_FILE"' EXIT
git read-tree "$base"
git rm -r -q --cached --ignore-unmatch "$prefix"
git read-tree --prefix="$prefix/" "$head"
tree=$(git write-tree)

if [ "$tree" = "$(git rev-parse "$base^{tree}")" ]; then
  echo "meatsauce $prefix already matches HEAD ($(git rev-parse --short "$head"))"
  exit 0
fi

msg="BRAZZ: $(git log -1 --format=%s "$head")

Crystal System core at commit $(git rev-parse --short "$head")."
commit=$(git log -1 --format=%B "$head" | sed -n '/^Co-Authored-By:/p' |
  { trailers=$(cat); printf '%s\n%s' "$msg" "${trailers:+
$trailers}"; } | git commit-tree "$tree" -p "$base")

git push "$remote" "$commit:refs/heads/$branch"
echo "pushed $(git rev-parse --short "$commit") -> $remote/$branch ($prefix @ $(git rev-parse --short "$head"))"
