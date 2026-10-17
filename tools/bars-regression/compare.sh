#!/bin/zsh
# Run every bar case through the current build and a reference revision side by side (left = reference).
set -e
HERE=${0:A:h}; ROOT=${HERE:h:h}; REV=${1:-HEAD}; S=$HERE/samples
python3 "$HERE/synth.py"
git -C "$ROOT" show "${REV}:src/main.swift" > "$ROOT/build/ref.swift"
swiftc -O -o "$ROOT/build/matte-fill-ref" "$ROOT/build/ref.swift" -framework Cocoa -framework ScreenCaptureKit \
  -F /System/Library/PrivateFrameworks -framework SkyLight 2>&1 | grep error || true
run() {
  echo "== ${(j: :)@:t}"
  paste <("$ROOT/build/matte-fill-ref" --analyze "$@" | grep -v color) <("$ROOT/build/matte-fill" --analyze "$@" | grep -v color) \
    | sed 's/rect: //g; s/after //g'
}
cd "$S"
for f in s_letter s_letter_esc s_letter_dark s_letter_darktop s_letter_darkband s_full s_full_darkedge s_pillar_icon; do run $f.png; done
[[ -f bili-dark.png ]] && run bili-dark.png
run s_letter.png s_letter_darkband.png s_letter_darktop.png s_letter_dark.png s_letter_esc.png s_letter2.png
run s_full.png s_full_darkedge.png s_full.png
run s_letter.png s_full.png s_full.png s_full.png
run s_full.png s_full.png s_full.png s_letter.png s_letter.png s_letter.png
run s_letter_darkband.png s_letter_darktop.png s_letter_darktop.png s_letter_darktop.png
run s_full_darkall.png s_full_darkedge.png s_full_darkedge.png s_full_darkedge.png
