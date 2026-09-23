#!/bin/bash
# Crash tests: kill -9 the clean-library writer, Undo and Tidy at random moments and
# exactly at their commit points, resume, and check nothing was lost, duplicated,
# half-written or left behind — and that no original was touched.
#
#   Tests/crash_test.sh <scratch-dir> [random-kills] [rounds]
#
# Uses a synthetic library (drawn here, no real photographs) and a stand-in Trash
# folder inside <scratch-dir>; never the real Trash. Build first with ./test.sh.
set -u
cd "$(dirname "$0")/.."
W=$(mkdir -p "$1" && cd "$1" && pwd); KILLS=${2:-12} ROUNDS=${3:-3}
LIB=$W/lib CAT=$W/cat.sqlite OUT=$W/out TRASH=$W/trash
[ -x ./build/tests ] || { echo "build/tests is missing: run ./test.sh first"; exit 1; }
T=./build/tests; CHECK="python3 Tests/crash_check.py $LIB $CAT"
rm -rf "$W"/{lib,out,trash} "$CAT"*
fails=0
verdict() { if "$@"; then :; else fails=$((fails+1)); fi; }

python3 - "$LIB" <<'PY'
import random, shutil, subprocess, sys
from pathlib import Path
from PIL import Image, ImageDraw
out = Path(sys.argv[1]); (out / "Camera").mkdir(parents=True); (out / "Backup").mkdir()
for i in range(300):
    r = random.Random(i); im = Image.new("RGB", (800, 600), tuple(r.randrange(256) for _ in range(3)))
    d = ImageDraw.Draw(im)
    for _ in range(12):
        x, y, s = r.randrange(800), r.randrange(600), r.randrange(40, 300)
        d.ellipse([x, y, x + s, y + s], fill=tuple(r.randrange(256) for _ in range(3)))
    ex = im.getexif(); ifd = ex.get_ifd(0x8769)
    ifd[0x9003] = f"2021:0{1 + i % 9}:{1 + i % 28:02d} {i % 24:02d}:{i % 60:02d}:00"; ifd[0x9011] = "+01:00"
    p = out / "Camera" / f"IMG_{i:04d}.jpg"; im.save(p, quality=90, exif=ex)
    if i % 4 == 0: shutil.copy(p, out / "Backup" / p.name)
for i in range(4):
    p = out / "Camera" / f"clip_{i}.mov"
    subprocess.run(["ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i", f"testsrc2=size=640x360:rate=24:duration={3 + i}",
                    "-vf", f"hue=h={i * 70}", "-c:v", "libx264", "-pix_fmt", "yuv420p", str(p)], check=True)
    if i % 2 == 0: shutil.copy(p, out / "Backup" / p.name)
print(sum(1 for _ in out.rglob("*.*")), "files")
PY
$CHECK snapshot >/dev/null
$T prep "$LIB" "$CAT"

# Kill a step at a random moment within DUR seconds, again and again, until KILLS
# kills have landed on unfinished work (or a run ends on its own); then let it finish.
killer() {  # killer <label> <command...>
    local label=$1; shift; local n=0 tries=0
    while [ $n -lt "$KILLS" ] && [ $tries -lt $((KILLS * 4)) ]; do
        tries=$((tries+1))
        "$@" > "$W/run.log" 2>&1 & local pid=$!
        sleep "$(python3 -c "import random; print(round(random.uniform(0.02, $DUR), 3))")"
        if kill -9 $pid 2>/dev/null; then n=$((n+1)); wait $pid 2>/dev/null; else wait $pid; break; fi
    done
    "$@" > "$W/run.log" 2>&1
    echo "  $label: killed $n times mid-run, then finished: $(tail -1 "$W/run.log")"
}
# Kill a step exactly at a commit point the n-th time it is reached, then finish.
inject() {  # inject <point> <n> <command...>
    local point=$1 n=$2; shift 2
    PM_CRASH=$point:$n "$@" > "$W/run.log" 2>&1; local st=$?
    "$@" > "$W/run.log" 2>&1
    echo "  $point #$n: first run exit $st, then: $(tail -1 "$W/run.log")"
}

# how long an uninterrupted write takes, so kills can land anywhere inside one
t0=$(python3 -c "import time; print(time.time())"); $T actc "$CAT" "$W/timing" >/dev/null
DUR=$(python3 -c "import time; print(round((time.time() - $t0) * 0.9, 2))"); $T undoc "$CAT" "$W/timing" >/dev/null
echo "an uninterrupted write takes ~${DUR}s"
for round in $(seq 1 "$ROUNDS"); do
    echo "clean library, then undo, random kills (round $round)"
    killer act $T actc "$CAT" "$OUT";            verdict $CHECK output "$OUT"
    DUR=0.05 killer undo $T undoc "$CAT" "$OUT"; verdict $CHECK undone "$OUT"
done
echo "clean library, killed right after a file is moved into place"
for n in 1 7 40; do inject act.moved $n $T actc "$CAT" "$OUT"; verdict $CHECK output "$OUT"; $T undoc "$CAT" "$OUT" >/dev/null; done
verdict $CHECK undone "$OUT"

echo "tidy, random kills"
DUR=0.05 killer tidy $T tidyc "$CAT" "$TRASH";      verdict $CHECK tidied "$TRASH"
DUR=0.05 killer restore $T restorec "$CAT" "$TRASH";         verdict $CHECK restored "$TRASH"
echo "tidy, killed right after a file is moved to the Trash"
for n in 1 9; do inject tidy.moved $n $T tidyc "$CAT" "$TRASH"; verdict $CHECK tidied "$TRASH"
                 $T restorec "$CAT" "$TRASH" > "$W/run.log"; echo "  restore: $(tail -1 "$W/run.log")"; verdict $CHECK restored "$TRASH"; done

[ $fails -eq 0 ] && echo "ALL CRASH CHECKS PASSED" || echo "$fails CRASH CHECK(S) FAILED"
exit $fails
