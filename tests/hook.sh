#!/bin/zsh
# Git pre-commit / pre-push hook: the test gate must pass, on exactly the code being committed or pushed.
# Install once per clone: tests/install-hooks.sh
ROOT=$(git rev-parse --show-toplevel)
if [[ ${0:t} == pre-push ]] && [[ -n $(git -C $ROOT status --porcelain -- src tests tools) ]]; then
  print "pre-push: src/, tests/ or tools/ has uncommitted changes, so the pushed commit can't be the one tested. Commit or stash them first."
  exit 1
fi
mkdir -p $ROOT/build/tests
print "${0:t}: running tests/run.sh"
zsh $ROOT/tests/run.sh > $ROOT/build/tests/hook.log 2>&1 || {
  grep -E 'FAIL|error' $ROOT/build/tests/hook.log
  print "${0:t}: tests NOT all green -> refused (full log: build/tests/hook.log)"
  exit 1
}
print "${0:t}: all checks passed"
