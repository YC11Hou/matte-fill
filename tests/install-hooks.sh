#!/bin/zsh
# Links tests/hook.sh as the git pre-commit and pre-push hooks of this clone.
ROOT=$(git -C ${0:A:h} rev-parse --show-toplevel)
for h in pre-commit pre-push; do ln -sf ../../tests/hook.sh $ROOT/.git/hooks/$h; done
chmod +x $ROOT/tests/hook.sh $ROOT/tests/run.sh
print "installed: .git/hooks/pre-commit, .git/hooks/pre-push -> tests/hook.sh"
