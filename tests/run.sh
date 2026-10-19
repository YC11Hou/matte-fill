#!/bin/zsh
# The test gate (tests/README.md). Every step must pass after every change and before every push; the git
# hooks (tests/install-hooks.sh) run it on commit and on push and refuse when anything fails.
# Offline only: it never touches the screen, the pointer, the focus or the running agent.
#   tests/run.sh                 all three requirements
#   tests/run.sh --bless-bars    after an intended change to bar detection, rewrite its baseline (then review the diff)
set -e
ROOT=${0:A:h:h}; T=$ROOT/tests; B=$ROOT/build/tests; S=$ROOT/tools/bars-regression/samples
SCREEN=1470x956x32   # the built-in display; fixed, so results don't depend on the displays attached
FW=(-framework Cocoa -framework ScreenCaptureKit -framework Metal -F /System/Library/PrivateFrameworks -framework SkyLight)
fail() { print -P "%F{red}FAIL%f $1"; exit 1; }
step() { print -P "%F{cyan}==%f $1"; }
mkdir -p $B/main

step "build"
swiftc -O -o $ROOT/build/matte-fill $ROOT/src/main.swift $FW 2>&1 | grep -E "error" && fail "src/main.swift does not compile" || true
awk '/^\/\/ MARK: - Entry/{exit} {print}' $ROOT/src/main.swift > $B/lib.swift
cp $T/main.swift $B/main/main.swift
swiftc -O -o $B/checks $B/lib.swift $T/common.swift $T/1-external/external.swift $T/2-animation/animation.swift \
  $T/3-color/color.swift $B/main/main.swift $FW 2>&1 | grep -E "error" && fail "the checks do not compile" || true

step "requirements 1-3: logic and rendering"
$B/checks 1 2 3 || fail "checks"

step "requirements 1-2: source structure"
python3 $T/2-animation/structure.py $ROOT/src/main.swift || fail "structure"

step "requirement 3: bar detection against tests/3-color/bars/expected.txt"
python3 $ROOT/tools/bars-regression/synth.py
out=$B/bars.txt; : > $out
cd $S
while IFS= read -r c; do
  [[ -z $c || $c == \#* ]] && continue
  print "== $c" >> $out
  argv_=()
  for a in ${=c}; do [[ $a == --* ]] && argv_+=($a) || { [[ -f $a.png ]] || fail "missing sample $a.png"; argv_+=($a.png) }; done
  $ROOT/build/matte-fill --analyze --screen $SCREEN $argv_ | { grep -v '^color' || true } >> $out
done < $T/3-color/bars/cases.txt
grep -q unreadable $out && fail "a sample could not be read"
grep -q '^rect' $out || fail "no case produced any bar: the analyzer is not running"
awk '/^== --still/{s=1; next} /^==/{s=0} s && /^rect/{exit 1}' $out || fail "a static app screen (--still) got bars"
[[ ${1:-} == --bless-bars ]] && { cp $out $T/3-color/bars/expected.txt; print "baseline rewritten: review git diff before committing"; }
diff -u $T/3-color/bars/expected.txt $out || fail "bar detection differs from the baseline"

git -C $ROOT rev-parse HEAD > $B/last-pass 2>/dev/null || true
print -P "%F{green}all checks passed%f"
