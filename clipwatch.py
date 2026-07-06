#!/usr/bin/env python3
# clipwatch.py — clipboard watcher for the right-click→Claude tool.
#
# Two jobs on every clipboard change:
#   1. Freshness/security meta → ~/.claude/state/clipboard.json
#      {epoch, bundle, blocked}. The worker uses the clipboard as a fallback only
#      if FRESH (<TTL) and not blocked.
#   2. History → ~/.claude/state/cliphistory/ (index.json + item files), capped,
#      for the ClipHistory picker. Text and images. Secrets are never stored.
#
# Runs as a LaunchAgent (install-clipwatch.sh). Stores contents on disk for
# history — but never from a blocked/secret source.

import os, sys, json, time, stat
from collections import deque
from AppKit import (NSPasteboard, NSWorkspace, NSBitmapImageRep,
                    NSBitmapImageFileTypePNG)

# Clipboard history is plaintext on disk and can contain anything you copy
# (tokens, 2FA codes, private messages). Keep it strictly owner-only so other
# local users on a shared Mac can't read it. umask 0o077 → new files 0600,
# new dirs 0700.
os.umask(0o077)

STATE_DIR   = os.path.expanduser("~/.claude/state")
META        = os.path.join(STATE_DIR, "clipboard.json")
HIST        = os.path.join(STATE_DIR, "cliphistory")
INDEX       = os.path.join(HIST, "index.json")
CONFIG      = os.path.join(STATE_DIR, "command-config.json")
COPY_SOURCE = os.path.join(STATE_DIR, "last_copy.json")
os.makedirs(HIST, mode=0o700, exist_ok=True)

def _lock_down():
    # Tighten perms on the dir + any pre-existing files from older versions
    # that may have been created world-readable under a 0022 umask.
    try: os.chmod(HIST, 0o700)
    except OSError: pass
    try:
        for name in os.listdir(HIST):
            try: os.chmod(os.path.join(HIST, name), 0o600)
            except OSError: pass
    except OSError: pass

_lock_down()

# Retention is time-based (set in the menu-bar UI → command-config.json). The
# count cap is just a disk-safety backstop, not the real limit.
DEFAULT_RETENTION_DAYS = 7
MAX_ITEMS = 1000
PREVIEW_LEN = 90

def retention_days():
    env = os.environ.get("CLIP_RETENTION_DAYS")
    if env:
        try: return max(1, int(env))
        except ValueError: pass
    try:
        with open(CONFIG) as f:
            v = json.load(f).get("retentionDays")
            if isinstance(v, (int, float)) and v >= 1: return int(v)
    except Exception:
        pass
    return DEFAULT_RETENTION_DAYS

BLOCK_BUNDLES = {
    "com.apple.keychainaccess", "com.apple.SecurityAgent",
    "com.1password.1password", "com.agilebits.onepassword7",
    "com.apple.wallet", "com.apple.Passwords",
    "com.claudecommand",   # truly-internal writes (e.g. Settings UI copy) — never recorded
}

# Sentinel bundles ClaudeCommand stamps onto its OWN clipboard writes, via last_copy.json,
# so this watcher can tell "I just wrote this" apart from a real user copy — deterministically,
# by exact NSPasteboard changeCount match (see read_copy_source), not a timing guess.
# Each carries an `origin` tag for the picker's filter chips instead of a real source app.
SELF_WRITE_ORIGIN = {
    "com.claudecommand.dictation": "dictation",  # dictation insert/dictate-to-claude
    "com.claudecommand.send": "sent",            # wrapped-prompt copy for a hotkey/custom action
}

# Screenshot apps dismiss before clipboard fires; we need recent frontmost history
# to attribute screenshot items correctly.
SCREENSHOT_BUNDLES = {"com.apple.screencaptureui", "com.apple.Screenshot"}
CONCEAL_TYPES = {
    "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
    "com.agilebits.onepassword.metadata",
}

def front_bundle():
    a = NSWorkspace.sharedWorkspace().frontmostApplication()
    return (a.bundleIdentifier() or "") if a else ""

def write_meta(epoch, bundle, blocked):
    tmp = META + ".tmp"
    with open(tmp, "w") as f:
        json.dump({"epoch": epoch, "bundle": bundle, "blocked": bool(blocked)}, f)
    os.replace(tmp, META)

def load_index():
    try:
        with open(INDEX) as f: return json.load(f)
    except Exception:
        return []

def save_index(items):
    tmp = INDEX + ".tmp"
    with open(tmp, "w") as f: json.dump(items, f)
    os.replace(tmp, INDEX)

def prune(items):
    # Drop anything older than the retention window (items are newest-first).
    cutoff = int(time.time()) - retention_days() * 86400
    kept = []
    for it in items:
        if it.get("ts", cutoff) < cutoff:
            try: os.remove(os.path.join(HIST, it["file"]))
            except Exception: pass
        else:
            kept.append(it)
    # Disk-safety backstop on count.
    while len(kept) > MAX_ITEMS:
        old = kept.pop()
        try: os.remove(os.path.join(HIST, old["file"]))
        except Exception: pass
    return kept

def prune_now():
    items = load_index()
    pruned = prune(items)
    if len(pruned) != len(items):
        save_index(pruned)

def save_image(pb, path):
    d = pb.dataForType_("public.png")
    if d:
        d.writeToFile_atomically_(path, True); return True
    d = pb.dataForType_("public.tiff")
    if d:
        rep = NSBitmapImageRep.imageRepWithData_(d)
        if rep:
            png = rep.representationUsingType_properties_(NSBitmapImageFileTypePNG, {})
            if png: png.writeToFile_atomically_(path, True); return True
    return False

def add_history(epoch, pb, bundle, origin=""):
    items = load_index()
    types = set(pb.types() or [])
    text = pb.stringForType_("public.utf8-plain-text") or pb.stringForType_("public.text")
    is_img = bool(types & {"public.png", "public.tiff"})
    if text and text.strip():
        if items and items[0].get("type") == "text":
            same_text = items[0].get("full") == text
            # A "sent" write (ClaudeCommand wrapping whatever you just copied — source
            # prefix, research hint, a custom prompt template — before pasting it into
            # Claude) is *always* a decorated version of the thing you just copied, even
            # when the wrapped text no longer matches byte-for-byte. Recency is what ties
            # them together, not content equality — merge into that row instead of
            # inserting a second one, so "Add"/custom actions never produce two entries
            # for what is, from your perspective, one action.
            recently_ours = origin == "sent" and (epoch - items[0].get("ts", epoch)) < 5
            if same_text or recently_ours:
                if origin and items[0].get("origin") != origin:
                    items[0]["origin"] = origin
                    save_index(prune(items))
                return
        fid = f"{epoch}.txt"
        with open(os.path.join(HIST, fid), "w") as f: f.write(text)
        item = {"id": str(epoch), "type": "text", "file": fid,
                "preview": text.strip().replace("\n", " ")[:PREVIEW_LEN],
                "full": text, "ts": epoch, "bundle": bundle}
        if origin: item["origin"] = origin
        items.insert(0, item)
    elif is_img:
        fid = f"{epoch}.png"
        if save_image(pb, os.path.join(HIST, fid)):
            item = {"id": str(epoch), "type": "image", "file": fid,
                    "preview": "image", "ts": epoch, "bundle": bundle}
            if origin: item["origin"] = origin
            items.insert(0, item)
        else:
            return
    else:
        return
    save_index(prune(items))

ATTR_LOG = os.path.expanduser("~/.claude/logs/attribution.log")

def alog(msg):
    try:
        line = f"{time.strftime('%H:%M:%S')} [clipwatch] {msg}\n"
        with open(ATTR_LOG, "a") as f: f.write(line)
    except Exception: pass

def read_copy_source(cc):
    # cc = the NSPasteboard changeCount that was just observed. The stamp records the
    # EXACT changeCount our own write produced — an exact match is proof positive it's
    # ours, no timing guess involved. Falls back to the old age<1s heuristic only for
    # stamps written before this field existed (shouldn't happen post-upgrade, but the
    # file could in theory be mid-write from a version skew during an update).
    try:
        with open(COPY_SOURCE) as f:
            d = json.load(f)
        ts = float(d.get("ts", 0))
        b  = d.get("bundle", "")
        stamped_cc = d.get("cc")
        age = time.time() - ts
        if age > 5.0:
            alog(f"read_copy_source → STALE (b={b!r} age={age:.1f}s) — ignoring")
            return None
        if stamped_cc is not None:
            if b and stamped_cc == cc:
                try: os.remove(COPY_SOURCE)
                except Exception: pass
                alog(f"read_copy_source → {b} (exact cc={cc}) ✓")
                return b
            alog(f"read_copy_source → cc mismatch (stamped={stamped_cc} actual={cc}) — not ours")
            return None
        if b and age < 1.0:
            try: os.remove(COPY_SOURCE)
            except Exception: pass
            alog(f"read_copy_source → {b} (legacy age={age:.3f}s) ✓")
            return b
        alog(f"read_copy_source → EXPIRED/EMPTY (b={b!r} age={age:.1f}s)")
    except FileNotFoundError:
        alog("read_copy_source → no file")
    except Exception as e:
        alog(f"read_copy_source → error: {e}")
    return None

def main():
    pb = NSPasteboard.generalPasteboard()
    last = pb.changeCount()
    write_meta(int(time.time()), front_bundle(), False)
    last_prune = 0
    # Keep last 10s of frontmost apps to reliably attribute screenshot items.
    # Screencapture selection can take several seconds; 400 × 25ms = 10s window.
    recent_front: deque = deque(maxlen=400)
    # Track explicit app-switch events for precise attribution:
    # When user copies then immediately switches apps, the previous app is the copier.
    prev_front_bundle = ""
    prev_front_changed_at = 0.0
    _current_front_cached = ""
    while True:
        try:
            now_float = time.time()
            now = int(now_float)
            current_front = front_bundle()
            # Detect app switch — record previous app and when it changed
            if current_front != _current_front_cached:
                prev_front_bundle = _current_front_cached
                prev_front_changed_at = now_float
                _current_front_cached = current_front
            recent_front.append(current_front)
            cc = pb.changeCount()
            if cc != last:
                last = cc
                copy_src = read_copy_source(cc)
                if copy_src is None and os.path.exists(COPY_SOURCE):
                    # The stamp write (same-process, right after the pasteboard write in
                    # the writer) can in rare cases still land a beat after our 25ms poll
                    # wakes. Two quick re-checks absorb that jitter before we fall back
                    # to frontmost-app guessing.
                    for _ in range(2):
                        time.sleep(0.015)
                        copy_src = read_copy_source(cc)
                        if copy_src is not None: break
                if copy_src:
                    bundle = copy_src
                    origin = SELF_WRITE_ORIGIN.get(bundle, "")
                    source_method = "last_copy.json"
                else:
                    origin = ""
                    # No Cmd+C intercept. Use best available attribution:
                    # 1. If frontmost app switched within last 500ms, the PREVIOUS app
                    #    likely did the copy (user copied then switched).
                    # 2. Otherwise use current_front (copy happened in active app).
                    switched_recently = (now_float - prev_front_changed_at) < 0.5
                    if (switched_recently and prev_front_bundle
                            and prev_front_bundle not in BLOCK_BUNDLES):
                        bundle = prev_front_bundle
                        source_method = "prev_front_recent_switch"
                    else:
                        bundle = current_front if current_front not in BLOCK_BUNDLES else ""
                        source_method = "current_front"
                types = set(pb.types() or [])
                is_img = bool(types & {"public.png", "public.tiff"})
                if is_img and not copy_src:
                    # Screenshots: screencaptureui is frontmost during selection, then
                    # dismissed. Find the app active just BEFORE screencaptureui entered
                    # the window — that's the app the screenshot was taken "of".
                    deque_list = list(recent_front)  # oldest→newest
                    in_shot = False
                    pre_shot = None
                    for rb in reversed(deque_list):   # scan newest→oldest
                        if rb in SCREENSHOT_BUNDLES:
                            in_shot = True
                        elif in_shot and rb:
                            pre_shot = rb; break
                    if pre_shot:
                        bundle = pre_shot; source_method = "pre_screenshot_app"
                    elif in_shot:
                        bundle = "com.apple.screencaptureui"; source_method = "screenshot_history"
                concealed = bool(types & CONCEAL_TYPES)
                blocked = concealed or (bundle in BLOCK_BUNDLES)
                alog(f"CHANGE → bundle={bundle} via={source_method} blocked={blocked} img={is_img} current_front={current_front}")
                print(f"[clipwatch] change: bundle={bundle} via={source_method} blocked={blocked}", file=sys.stderr, flush=True)
                write_meta(now, bundle, blocked)
                if not blocked:
                    try: add_history(now, pb, bundle, origin)
                    except Exception as e: alog(f"add_history error: {e}")
            # Periodic prune so expired clips disappear without needing a new copy.
            if now - last_prune >= 60:
                last_prune = now
                try: prune_now()
                except Exception: pass
        except Exception as e:
            alog(f"loop error (continuing): {e}")
        time.sleep(0.025)

if __name__ == "__main__":
    alog("startup")
    try:
        main()
    except Exception as e:
        alog(f"FATAL crash: {e}")
        import traceback
        alog(traceback.format_exc())
        raise
