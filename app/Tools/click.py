#!/usr/bin/env python3
"""Click at a screen point. A dev aid for driving the app in tests: SwiftUI
controls expose almost nothing to AppleScript, and `System Events`' own
`click at` times out on this app."""
import sys, time
import Quartz

def click(x, y):
    # Click state must be set: AppKit controls such as NSSegmentedControl ignore
    # a mouse-down whose click count is 0, while list rows accept it — so a
    # helper without it appears to work, then silently fails on some controls.
    for kind in (Quartz.kCGEventMouseMoved,
                 Quartz.kCGEventLeftMouseDown,
                 Quartz.kCGEventLeftMouseUp):
        e = Quartz.CGEventCreateMouseEvent(None, kind, (x, y),
                                           Quartz.kCGMouseButtonLeft)
        if kind != Quartz.kCGEventMouseMoved:
            Quartz.CGEventSetIntegerValueField(e, Quartz.kCGMouseEventClickState, 1)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, e)
        time.sleep(0.08)

def scroll(x, y, lines):
    e = Quartz.CGEventCreateMouseEvent(None, Quartz.kCGEventMouseMoved, (x, y),
                                       Quartz.kCGMouseButtonLeft)
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, e)
    time.sleep(0.1)
    e = Quartz.CGEventCreateScrollWheelEvent(None, Quartz.kCGScrollEventUnitLine,
                                             1, int(lines))
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, e)

def window_origin(owner="PhotoMerge"):
    """Top-left of the app's largest on-screen window, in screen points. Looked up
    on every call: the window reopens wherever macOS puts it, and clicking with
    remembered coordinates silently hits the wrong control."""
    wins = Quartz.CGWindowListCopyWindowInfo(
        Quartz.kCGWindowListOptionOnScreenOnly, Quartz.kCGNullWindowID)
    best = None
    for w in wins:
        if w.get("kCGWindowOwnerName") != owner or w.get("kCGWindowLayer") != 0:
            continue
        b = w["kCGWindowBounds"]
        if best is None or b["Width"] * b["Height"] > best["Width"] * best["Height"]:
            best = b
    if best is None:
        sys.exit(f"no on-screen window for {owner}")
    return best["X"], best["Y"]

if __name__ == "__main__":
    # `click.py win X Y` — X, Y in points relative to the window's top-left, which
    # is a screenshot pixel divided by the display scale (2 on Retina).
    if sys.argv[1] == "win":
        ox, oy = window_origin()
        click(ox + float(sys.argv[2]), oy + float(sys.argv[3]))
        sys.exit(0)
    if sys.argv[1] == "scroll":
        scroll(float(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4]))
    else:
        click(float(sys.argv[1]), float(sys.argv[2]))
