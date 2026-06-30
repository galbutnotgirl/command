#!/bin/zsh
# uninstall.sh — remove DictationLab app and optionally its model cache.
emulate -L zsh
set -uo pipefail

DIR="${0:A:h}"
APP="${DIR}/DictationLab.app"
MODEL_CACHE="${HOME}/Library/Application Support/FluidAudio"

print -- "[uninstall] Stopping DictationLab…"
pkill -f "DictationLab" 2>/dev/null && sleep 0.5 || true

if [[ -d "$APP" ]]; then
    rm -rf "$APP"
    print -- "[uninstall] Removed: $APP"
else
    print -- "[uninstall] App not found (already removed?)"
fi

if [[ -d "$MODEL_CACHE" ]]; then
    SIZE=$(du -sh "$MODEL_CACHE" 2>/dev/null | cut -f1)
    print -- ""
    print -- "Model cache found at: $MODEL_CACHE ($SIZE)"
    print -- "Delete it? You will need to re-download (~650 MB) on next install. [y/N]"
    read -r REPLY
    if [[ "${REPLY:l}" == "y" ]]; then
        rm -rf "$MODEL_CACHE"
        print -- "[uninstall] Removed model cache."
    else
        print -- "[uninstall] Kept model cache — next install will skip download."
    fi
else
    print -- "[uninstall] No model cache found."
fi

print -- ""
print -- "[uninstall] Done. To reinstall: run ./build.sh"
print -- "Note: Microphone and Accessibility permissions remain in System Settings."
print -- "      Remove manually under Privacy & Security if desired."
