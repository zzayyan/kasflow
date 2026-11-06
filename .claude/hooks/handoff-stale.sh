#!/usr/bin/env bash
# Stop hook: when work in progress is newer than .agents/HANDOFF.md, block the
# stop once and ask Claude to rewrite the handoff (see AGENTS.md, "Handoff").
# ponytail: mtime comparison, fires once per turn that changed files; switch to
# a SessionEnd reminder if the extra step per turn costs too much.

input=$(cat)
# Second pass after a block: let Claude stop, so the hook never loops.
echo "$input" | grep -q '"stop_hook_active": *true' && exit 0

cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0
handoff=.agents/HANDOFF.md
changed=$(git status --porcelain --untracked-files=all | cut -c4-)

# Nothing in progress: on main with a clean tree.
[ "$(git branch --show-current)" = main ] && [ -z "$changed" ] && exit 0

newest=$(git log -1 --format=%ct)
IFS=$'\n'
for f in $changed; do
  [ -f "$f" ] || continue
  t=$(stat -c %Y "$f")
  [ "$t" -gt "$newest" ] && newest=$t
done

[ -f "$handoff" ] && [ "$(stat -c %Y "$handoff")" -ge "$newest" ] && exit 0

echo "Work in progress is newer than $handoff. Rewrite it as AGENTS.md (Handoff) describes, then stop." >&2
exit 2
