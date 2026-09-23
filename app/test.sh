#!/bin/bash
# Headless engine tests. No UI, no Xcode project needed beyond the SDK.
set -uo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
mkdir -p build
# Every file the tests compile: all of Sources/ that does not need SwiftUI or AppKit,
# plus Tests/. Listed by exclusion so a new engine file is tested by default rather
# than silently left out.
# Every engine file is tested; UI files are recognised by what they import, so a
# new view never has to be remembered here and a new engine file is never missed.
SRCS=()
for f in Sources/*.swift; do
    if grep -qE '^import (SwiftUI|AppKit)' "$f"; then continue; fi
    SRCS+=("$f")
done
# The old binary is deleted first and the compiler's own exit status is checked.
# Before this, `swiftc … | grep error: && exit` never fired under pipefail, and a
# failed compile quietly re-ran the previous binary — which reported all green.
rm -f build/tests
if ! xcrun swiftc -O -swift-version 5 -framework ImageIO -framework CoreGraphics \
        "${SRCS[@]}" Tests/*.swift -o build/tests > build/compile.log 2>&1; then
    grep -E 'error' build/compile.log | head -20
    echo "COMPILE FAILED"; exit 1
fi
PY=/opt/homebrew/Caskroom/miniforge/base/bin/python3
[ -x "$PY" ] || PY=python3

# `corpus` builds a known-answer corpus, runs the cascade, and asserts the result.
if [ "${1:-}" = "corpus" ]; then
    SRC="${2:-$HOME/Pictures}"
    DIR="${TMPDIR:-/tmp}/photomerge-corpus"
    echo "building corpus from $SRC"
    "$PY" Tests/make_corpus.py "$SRC" "$DIR" "${3:-60}" || exit 1
    echo "running the cascade"
    ./build/tests analyse "$DIR" 4 | sed -n 's/^  \(tier\|.*duplicates\|.*chain\)/  \1/p'
    echo "checking against ground truth"
    exec "$PY" Tests/verify_corpus.py "$DIR"
fi

exec ./build/tests "$@"
