#!/usr/bin/env python3
# match-enrich-rule.py — find the first user-defined Context rule (Settings ▸
# Templates ▸ Context, ~/.claude/state/enrichment-rules.json) that matches the
# current capture's source. Extracted out of send-to-claude.sh's inline heredoc
# so it's independently testable (see test/test-shell.sh) instead of only
# exercisable by driving the whole capture pipeline.
#
# Usage: match-enrich-rule.py <rules.json> <bundleID> <host> <appName> <url>
# Output: "<enrich text>\x1e<displayName>" for the first hit, else nothing.
# Mirrors CommandTemplates.swift's EnrichRule matching (host/bundle/app +
# optional pathPrefix) and previewSources() — keep both in sync by hand.

import json
import sys
import fnmatch
from urllib.parse import urlparse


def main() -> None:
    path_arg, bundle, host, app, url = sys.argv[1:6]
    url_path = urlparse(url).path
    try:
        rules = json.load(open(path_arg))
    except Exception:
        rules = []
    for r in rules:
        m, pat, text = r.get("match"), r.get("pattern", ""), r.get("text", "")
        prefix = r.get("pathPrefix", "")
        hit = (
            (m == "bundle" and pat == bundle)
            or (m == "app" and pat == app)
            or (
                m == "host"
                and host
                and fnmatch.fnmatch(host, pat)
                and (not prefix or url_path.startswith(prefix))
            )
        )
        if hit:
            sys.stdout.write(text.replace("{url}", url) + "\x1e" + r.get("displayName", ""))
            return


if __name__ == "__main__":
    main()
