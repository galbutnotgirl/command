#!/usr/bin/env python3
"""Validate local documentation links.

Checks Markdown links, HTML hrefs, and local anchors in README/docs files.
External URLs, mailto links, and script links are ignored.
"""

from __future__ import annotations

import ast
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from urllib.parse import unquote


ROOT = Path(__file__).resolve().parents[1]
TRUST_MARKDOWN_FILES = [
    ROOT / "README.md",
    ROOT / "SUPPORT.md",
    ROOT / "SECURITY.md",
    ROOT / "CONTRIBUTING.md",
    ROOT / ".github" / "pull_request_template.md",
    *sorted((ROOT / ".github" / "ISSUE_TEMPLATE").glob("*.md")),
]
DOC_FILES = TRUST_MARKDOWN_FILES + sorted(p for p in (ROOT / "docs").iterdir() if p.suffix in {".md", ".html"})
REQUIRED_DOC_ASSETS = [
    "404.html",
    "index.html",
    "install.html",
    "uninstall.html",
    "guide.html",
    "settings.html",
    "quick-reference.html",
    "examples.html",
    "faq.html",
    "changelog.html",
    "limitations.html",
    "updates.html",
    "permissions.html",
    "troubleshooting.html",
    "privacy.html",
    "support.html",
    "security.html",
    "icon-treatments.html",
    "background.html",
    "release.html",
    "site.css",
    "robots.txt",
    "sitemap.xml",
    "INSTALL.md",
    "UNINSTALL.md",
    "USER_GUIDE.md",
    "SETTINGS_REFERENCE.md",
    "QUICK_REFERENCE.md",
    "EXAMPLES.md",
    "FAQ.md",
    "CHANGELOG.md",
    "LIMITATIONS.md",
    "UPDATES.md",
    "PERMISSIONS.md",
    "TROUBLESHOOTING.md",
    "PRIVACY.md",
    "RELEASE_CHECKLIST.md",
    "SUPPORT.md",
    "SECURITY.md",
    "ICON_TREATMENTS.md",
    "BACKGROUND_TRIGGER_INTEGRATION.md",
    "icon-treatment-bold-animated.svg",
    "icon-treatment-green-voice.svg",
    "icon-treatment-options-animated.svg",
    "icon-treatment-options.svg",
]
REQUIRED_BUNDLE_PATTERNS = [
    "for doc_asset in 404.html index.html install.html uninstall.html guide.html settings.html quick-reference.html examples.html faq.html changelog.html limitations.html updates.html permissions.html troubleshooting.html privacy.html support.html security.html icon-treatments.html background.html release.html site.css robots.txt sitemap.xml INSTALL.md UNINSTALL.md USER_GUIDE.md SETTINGS_REFERENCE.md QUICK_REFERENCE.md EXAMPLES.md FAQ.md CHANGELOG.md LIMITATIONS.md UPDATES.md PERMISSIONS.md TROUBLESHOOTING.md PRIVACY.md SUPPORT.md SECURITY.md ICON_TREATMENTS.md BACKGROUND_TRIGGER_INTEGRATION.md RELEASE_CHECKLIST.md icon-treatment-bold-animated.svg icon-treatment-green-voice.svg icon-treatment-options-animated.svg icon-treatment-options.svg",
    "[agent] ERROR missing bundled docs asset: docs/${doc_asset}",
    'cp "${DOCS_SRC}/${doc_asset}" "${APP}/Contents/Resources/docs/"',
]
REQUIRED_RELEASE_PATTERNS = [
    "COPYFILE_DISABLE=1 ditto -ck --norsrc",
    "AppleDouble metadata",
    "(cd \"${DIR}/agent\" && swift test)",
    "(cd \"${DIR}/vendor/claude-command-capture\" && node --test)",
    '"${DIR}/test/test-shell.sh"',
    'python3 "${DIR}/test/test-docs.py"',
    "Swift tests failed",
    "Node tests failed",
    "shell tests failed",
    "docs validation failed",
    "shasum -a 256",
    "checksum file malformed",
    "EXPECTED_BUNDLE_ID=\"com.claudecommand\"",
    "EXPECTED_MIN_MACOS=\"14.0\"",
    "CFBundleIdentifier",
    "built Info.plist bundle id",
    "LSMinimumSystemVersion",
    "built Info.plist minimum macOS",
    "packaged zip contains internal docs/STATUS.md",
    "gh release create \"$TAG\" \"$ZIP\" \"$SHA256\"",
    "packaged zip missing bundled docs asset",
    "packaged zip missing bundled README.md",
    "bundled docs asset is stale",
    "bundled README.md is stale",
    "packaged zip missing bundled runtime resource",
    "Command.app/Contents/Resources/README.md",
    "Command.app/Contents/Resources/docs/${required_doc}",
    "Command.app/Contents/Resources/${required_resource}",
    "claude-command-capture/bin/submit-cli.js",
    "404.html index.html install.html uninstall.html guide.html settings.html quick-reference.html examples.html faq.html changelog.html limitations.html updates.html permissions.html troubleshooting.html privacy.html support.html security.html icon-treatments.html background.html release.html site.css robots.txt sitemap.xml INSTALL.md UNINSTALL.md USER_GUIDE.md SETTINGS_REFERENCE.md QUICK_REFERENCE.md EXAMPLES.md FAQ.md CHANGELOG.md LIMITATIONS.md UPDATES.md PERMISSIONS.md TROUBLESHOOTING.md PRIVACY.md SUPPORT.md SECURITY.md ICON_TREATMENTS.md BACKGROUND_TRIGGER_INTEGRATION.md RELEASE_CHECKLIST.md icon-treatment-bold-animated.svg icon-treatment-green-voice.svg icon-treatment-options-animated.svg icon-treatment-options.svg",
]
PAGES_WORKFLOW = ROOT / ".github/workflows/pages.yml"
TEST_WORKFLOW = ROOT / ".github/workflows/test.yml"
REQUIRED_PAGES_WORKFLOW_PATTERNS = [
    "permissions:",
    "contents: read",
    "pages: write",
    "id-token: write",
    "concurrency:",
    "group: pages",
    "environment:",
    "name: github-pages",
    "steps.deployment.outputs.page_url",
    "actions/configure-pages",
    "actions/upload-pages-artifact",
    "actions/deploy-pages",
    'test/test-docs.py',
    "Docs quality checks",
    "python3 ./test/test-docs.py",
    "path: docs",
]
REQUIRED_TEST_WORKFLOW_PATTERNS = [
    "macos-14",
    "maxim-lobanov/setup-xcode",
    "Swift unit tests",
    "swift test",
    "Node tests",
    "node --test",
    "Shell tests (prompt/context matching)",
    "./test/test-shell.sh",
    "Docs quality tests",
    "python3 ./test/test-docs.py",
    "Release asset smoke test",
    "./release.sh --skip-checks",
    "./test/test-release-asset.sh",
]
DEFAULT_SHORTCUT_DOCS = [
    "README.md",
    "docs/guide.html",
    "docs/USER_GUIDE.md",
    "docs/quick-reference.html",
    "docs/QUICK_REFERENCE.md",
    "docs/changelog.html",
    "docs/CHANGELOG.md",
]
BUILT_IN_COMPOSE_DOCS = [
    "docs/guide.html",
    "docs/USER_GUIDE.md",
    "docs/quick-reference.html",
    "docs/QUICK_REFERENCE.md",
]
BUILT_IN_DOC_LABELS = {
    "add": "Selected text -> Existing chat",
    "comment": "Selected text -> New chat",
    "go": "Selected text -> New chat + auto-submit",
    "shotadd": "Screenshot -> Existing chat",
    "shotcomment": "Screenshot -> New chat",
    "shotgo": "Screenshot -> New chat + auto-submit",
}
HTML_MARKDOWN_PARITY = {
    ("docs/INSTALL.md", "docs/install.html"): [
        "Download Alpha",
        "First Run",
        "Verify Install",
        "Help After Install",
        "Install From Source",
        "Next",
    ],
    ("docs/UNINSTALL.md", "docs/uninstall.html"): [
        "Standard Uninstall",
        "Legacy Clipboard Watcher",
        "Optional Data Removal",
        "Verify Removal",
        "Reinstall Later",
    ],
    ("docs/USER_GUIDE.md", "docs/guide.html"): [
        "Quick Start",
        "Menu Bar",
        "Shortcut capture notes",
        "Prompt Model",
        "Built-In Compose",
        "Custom Actions",
        "Background Actions",
        "Context Rules",
        "Clipboard History",
        "Dictation",
        "Command History",
        "Import And Export",
        "Privacy And Local Files",
        "Troubleshooting",
        "Updating",
        "Uninstall",
        "launchctl bootout \"gui/$(id -u)/com.claudecommand\" 2>/dev/null || true",
        "rm -f ~/Library/LaunchAgents/com.claudecommand.plist",
    ],
    ("docs/SETTINGS_REFERENCE.md", "docs/settings.html"): [
        "Set Up",
        "Shortcuts",
        "Context",
        "Command History",
        "Clipboard History",
        "Dictation",
        "About",
    ],
    ("docs/QUICK_REFERENCE.md", "docs/quick-reference.html"): [
        "Default Shortcuts",
        "Shortcut Capture",
        "Menu Bar",
        "Glossary",
        "Prompt Model",
        "Built-In Compose",
        "Prompt Variables",
        "Clipboard Picker",
        "Background Result Contract",
        "Import / Export",
        "Local Data",
        "Common Fixes",
        "Help From The App",
        "Full Docs",
    ],
    ("docs/FAQ.md", "docs/faq.html"): [
        "Why are auto-submit combinations unbound by default?",
        "What if F6/F7/F8 conflict with another app?",
        "What do the built-in Compose combinations do?",
        "What does — mean in a trigger row?",
        "Does Command upload clipboard or dictation history?",
        "Where is data stored?",
        "Why did a background action fail?",
        "Why does dictation miss final words?",
        "How do updates work?",
        "How do I install Command the first time?",
        "Can I move settings to another Mac?",
        "What should I include in a bug report?",
        "How should I request a feature?",
    ],
    ("docs/EXAMPLES.md", "docs/examples.html"): [
        "Review Selected Text In Current Chat",
        "Start A Fresh Rewrite Thread",
        "Screenshot Design Review",
        "Voice Note Into Claude Code",
        "Background Task Capture",
        "Google Docs Context Rule",
        "Import Settings On A New Mac",
        "More Detail",
    ],
    ("docs/UPDATES.md", "docs/updates.html"): [
        "Update From The App",
        "Rename Compatibility",
        "Install Alpha Manually",
        "Before Updating",
        "If Update Fails",
        "Roll Back",
    ],
    ("docs/PERMISSIONS.md", "docs/permissions.html"): [
        "Short Version",
        "Accessibility",
        "Screen Recording",
        "Microphone",
        "Clipboard History",
        "Quick Actions",
        "Reset Permissions",
        "Diagnostics",
    ],
    ("docs/SUPPORT.md", "docs/support.html"): [
        "Fast Path",
        "Feature Requests",
        "What To Include",
        "Workflow Details",
        "Logs",
        "Before Filing",
    ],
    ("docs/PRIVACY.md", "docs/privacy.html"): [
        "Short Version",
        "Local File Locations",
        "Background Actions",
        "Import And Export Safety",
        "Diagnostics",
    ],
    ("docs/TROUBLESHOOTING.md", "docs/troubleshooting.html"): [
        "First Checks",
        "Common Symptoms",
        "Logs",
        "Command Checks",
        "Bug Reports",
    ],
    ("docs/RELEASE_CHECKLIST.md", "docs/release.html"): [
        "Version",
        "Preflight",
        "Publish",
        "After Publish",
        "Rollback",
    ],
    ("docs/ICON_TREATMENTS.md", "docs/icon-treatments.html"): [
        "Current Recording Direction",
        "Animated Previews",
        "Options",
        "Implementation Notes",
    ],
    ("docs/BACKGROUND_TRIGGER_INTEGRATION.md", "docs/background.html"): [
        "Stack decision",
        "Architecture",
        "New pieces",
        "Data layout & contract",
        "Source mapping nuance",
        "Using it",
        "Native UI (agent/Handoff.swift + MenuBar.swift)",
        "Background Custom Actions — building a structured background-prompt flow",
    ],
    ("docs/CHANGELOG.md", "docs/changelog.html"): [
        "1.2.0-alpha.6",
        "Defaults In This Alpha",
        "Alpha Notes",
    ],
    ("docs/LIMITATIONS.md", "docs/limitations.html"): [
        "Alpha Expectations",
        "Permissions",
        "Dictation And Voice",
        "Background Actions",
        "Updates",
        "Reporting",
    ],
}
REQUIRED_TEXT = {
    "test/test-docs.py": [
        "STRUCTURAL_HTML_TAGS",
        "unbalanced <{tag}> tags",
        "missing <!doctype html>",
        "validate_html_nesting",
        "misnested </{tag}>",
        "unclosed <{tag}>",
        "must contain exactly one <h1>",
        "empty <h{level}> heading",
        "duplicate anchor #",
        "title should match shared docs label",
        "h1 should match shared docs label",
        "HTML_SRC",
        "validate_svg_assets",
        "invalid SVG XML",
        "FORBIDDEN_HTML_METADATA_TERMS",
        "stale metadata term",
        "CORE_DOC_NAV_LINKS",
        "validate_no_duplicate_validator_keys",
        "duplicate key in {name}",
        "validate_heading_parity",
        "heading missing from rendered HTML",
        "validate_markdown_h1_label_parity",
        "Markdown H1 should match shared docs label",
        "validate_release_checklist_coverage",
        "release checklist missing docs page",
        "validate_release_checklist_doc_label_parity",
        "release checklist missing docs label",
        "validate_docs_home_coverage",
        "docs/index.html: docs home missing docs page",
        "validate_docs_home_card_label_parity",
        "docs home card label missing or mismatched",
        "validate_rendered_docs_grid_label_parity",
        "rendered docs grid label missing or mismatched",
        "validate_docs_home_repo_trust_routes",
        "docs home missing repo trust route",
        "validate_about_docs_button_coverage",
        "ABOUT_HELP_DOCS",
        "validate_about_docs_reference_parity",
        "About docs label missing from",
        "validate_release_checklist_about_docs_label_parity",
        "release checklist About docs-button label missing",
        "validate_about_surface_label_parity",
        "About surface label missing",
        "validate_settings_sidebar_reference_parity",
        "Settings sidebar label missing from Settings Reference",
        "validate_markdown_source_links",
        "Markdown source doc should link to Markdown source, not rendered HTML",
        "validate_release_download_links",
        "generic GitHub Releases URL should use /releases/latest",
        "OLD_PUBLIC_URLS",
        "validate_public_url_rename",
        "old public URL should use Command repo/pages path",
        "validate_release_script_doc_assets",
        "release.sh required_doc list mismatch",
        "validate_build_agent_doc_assets",
        "build-agent.sh doc_asset list mismatch",
        "validate_required_doc_assets_cover_docs_dir",
        "REQUIRED_DOC_ASSETS missing shareable docs files",
        "validate_readme_docs_table_coverage",
        "README.md docs table missing public Markdown doc",
        "validate_readme_docs_table_label_parity",
        "README.md docs table label missing or mismatched",
        "validate_shell_template_fallbacks",
        "validate_custom_action_trigger_add",
        "addTrigger should append exactly one ActionTrigger",
        "send-to-claude.sh: Go fallback template drifted from Swift default",
        "validate_css_asset",
        "unbalanced CSS braces",
        "missing shared site.css stylesheet",
        "og:title should match title",
        "twitter:description should match meta description",
        "toc-title should match shared docs label",
    ],
    "docs/quick-reference.html": [
        "Screenshot -> New chat + auto-submit",
        "Dictate -> Assistant",
        "Dictation Settings",
        "only shows prompt/action shortcuts that are enabled and bound to a key",
        "do not appear in the menu",
        "Glossary",
        "href=\"#built-in-compose\"",
        "<section id=\"built-in-compose\">",
        "A named prompt setup, with defaults and one or more triggers.",
        "A local <code>claude -p</code> run with no Claude window.",
        "Prompt Model",
        "Built-In Compose",
        "One shared Compose prompt powers six built-in combinations",
        "Auto-submit",
        "Clipboard Picker",
        "Command-Return",
        "rebind dictation shortcuts in Dictation Settings",
        "Background Result Contract",
        "TASK_ID=abc123",
        "final non-empty stdout line",
        "diagnostic summary",
        "Prose containing <code>TASK_ID=abc123</code> does not count",
        "No follow-up action runs from that value yet",
        "Import / Export",
        "Save selected settings sections to JSON.",
        "Preview a saved JSON file, then choose per-section handling.",
        "Merge",
        "Local Data",
        "~/.claude/state/cliphistory/",
        "Full Docs",
        "Help From The App",
        "Settings Reference",
        "Icon Treatments / Background Architecture / Release Checklist",
        "troubleshooting.html",
        "Copy Diagnostic Info",
        "Request Feature",
        "Private Security Report",
        "GitHub private advisory for vulnerabilities, exposed secrets, private logs, or sensitive diagnostics",
        "Bug reports, feature requests, help requests, and diagnostics.",
    ],
    "README.md": [
        "actions/workflows/test.yml/badge.svg",
        "actions/workflows/pages.yml/badge.svg",
        "img.shields.io/github/v/release/galbutnotgirl/command",
        "license-MIT-green.svg",
        "| Install Guide |",
        "docs/INSTALL.md",
        "| Uninstall |",
        "docs/UNINSTALL.md",
        "| User Guide |",
        "| Settings Reference |",
        "docs/SETTINGS_REFERENCE.md",
        "| Permissions |",
        "docs/PERMISSIONS.md",
        "| Privacy |",
        "docs/PRIVACY.md",
        "| Alpha Limitations |",
        "docs/LIMITATIONS.md",
        "| Icon Treatments |",
        "docs/ICON_TREATMENTS.md",
        "| Background Architecture |",
        "docs/BACKGROUND_TRIGGER_INTEGRATION.md",
        "| Release Checklist |",
        "Support, bugs, and feature requests",
        "SUPPORT.md",
        "SECURITY.md",
        "Private security report",
        "security/advisories/new",
        "CONTRIBUTING.md",
        "docs/UPDATES.md",
        "https://github.com/galbutnotgirl/command/releases/latest",
        "latest GitHub Release",
        "checksum verification when kept beside the matching zip",
        ".zip.sha256",
        "Quick start for most users",
        "Move to Applications",
        "verify **Accessibility** is green",
        "Binary installs do not require Terminal scripts",
        "For downloaded app installs, use **Settings -> About -> Copy Diagnostic Info**",
        "From a repo checkout, maintainers can also run",
        "Command requires macOS 14+.",
        "downloads the attached `Command-*.zip`",
        "clears quarantine, and restarts",
        "requires Xcode command-line tools",
        "legacy SendHelper keystroke fallback",
        "Optional, if you want legacy right-click Services",
        "Those source-only Services include **Claude - To-Do**",
        "Safari, Chrome, Brave, Chromium, and Arc send the current tab URL",
        "pick Alpha or Beta",
        "Stable is visible but unavailable until the first stable release exists",
        "./release.sh --skip-checks",
        "./test/test-release-asset.sh",
        "docs/README parity",
        "docs/UNINSTALL.md",
        "./script/build_and_run.sh",
        "pings the app dispatch socket, and checks bundled docs",
    ],
    "SUPPORT.md": [
        "# Command Support",
        "https://galbutnotgirl.github.io/command/support.html",
        "https://galbutnotgirl.github.io/command/troubleshooting.html",
        "https://galbutnotgirl.github.io/command/install.html",
        "[Bundled Markdown docs](docs/SUPPORT.md)",
        "https://github.com/galbutnotgirl/command/releases/latest",
        "Copy Diagnostic Info",
        "https://github.com/galbutnotgirl/command/issues/new?template=bug_report.md",
        "https://github.com/galbutnotgirl/command/issues/new?template=feature_request.md",
        "Settings -> About -> Request Feature",
        "Settings -> About -> Private Security Report",
        "SECURITY.md",
    ],
    "SECURITY.md": [
        "# Command Security Policy",
        "Report A Vulnerability",
        "Do not file public GitHub issues for vulnerabilities",
        "Settings -> About -> Private Security Report",
        "https://github.com/galbutnotgirl/command/security/advisories/new",
        "Latest Alpha release",
        "https://galbutnotgirl.github.io/command/privacy.html",
        "https://galbutnotgirl.github.io/command/settings.html",
        "docs/PRIVACY.md",
        "docs/SETTINGS_REFERENCE.md",
        "clipboard history",
        "dictation",
        "background actions",
        "redacting secrets",
    ],
    "docs/security.html": [
        "<title>Command Security Policy</title>",
        "href=\"#local-data-scope\"",
        "<section id=\"local-data-scope\">",
        "Settings -> About -> Private Security Report",
        "https://github.com/galbutnotgirl/command/security/advisories/new",
        "latest GitHub Release",
        "privacy.html",
        "settings.html",
    ],
    "CONTRIBUTING.md": [
        "macOS 14+.",
        "./script/build_and_run.sh --verify",
        "cd agent && swift test",
        "cd ../vendor/claude-command-capture && node --test",
        "./test/test-shell.sh",
        "python3 ./test/test-docs.py",
        "./release.sh --skip-checks",
        "./test/test-release-asset.sh",
        "docs/USER_GUIDE.md",
        "docs/SETTINGS_REFERENCE.md",
        "docs/QUICK_REFERENCE.md",
        "SUPPORT.md",
        "SECURITY.md",
        "docs/RELEASE_CHECKLIST.md",
        "Claude Command",
        "Handoff History",
        "Templates",
        "local-first privacy behavior",
        "pull request template checklist",
        "--skip-checks is only for local one-off packaging and CI packaging smoke tests",
    ],
    ".github/pull_request_template.md": [
        "## Summary",
        "## User Impact",
        "App behavior changed",
        "User-facing docs changed",
        "Release/update behavior changed",
        "Support/security routing changed",
        "User-facing labels match docs.",
        "Paired Markdown/HTML docs are updated when needed.",
        "sensitive diagnostics away from public issues",
        "Issue templates, issue chooser, and repo trust files are updated when support/reporting routes change.",
        "Release checklist or changelog updated when behavior/defaults changed.",
        "Bundled docs/release asset smoke passes when docs or release packaging changed.",
        "cd agent && swift test",
        "cd ../vendor/claude-command-capture && node --test",
        "./test/test-shell.sh",
        "python3 ./test/test-docs.py",
        "./release.sh --skip-checks",
        "./test/test-release-asset.sh",
    ],
    "docs/index.html": [
        "<title>Command — Send anything to your AI</title>",
        "href=\"#content\">Skip to content</a>",
        "<main id=\"content\">",
        "install.html",
        "settings.html",
        "uninstall.html",
        "404.html",
        "Anything in. Anywhere out.",
        "Compose once. Trigger your way.",
        "Capture anything",
        "Choose flow",
        "Keep moving",
        "https://github.com/galbutnotgirl/command/releases/latest",
        "updates.html",
        "limitations.html",
        "Alpha Limitations",
        "permissions.html",
        "troubleshooting.html",
        "security.html",
        "Security Policy",
        "Private Security Report",
        "icon-treatments.html",
        "Local development:",
        "uninstall.html",
    ],
    "docs/404.html": [
        "<title>Command Docs Not Found</title>",
        "Command docs fallback for moved or mistyped links",
        "Page Not Found",
        "Docs Home",
        "install.html",
        "limitations.html",
        "Alpha Limitations",
        "troubleshooting.html",
        "support.html",
        "security.html",
        "Security Policy",
        "Shortcut conflicts, auto-submit behavior, inheritance, privacy, dictation, background runs, and imports.",
    ],
    "docs/guide.html": [
        "aria-label=\"Documentation sections\"",
        "<main id=\"content\" class=\"doc-main\">",
        "install.html",
        "settings.html",
        "uninstall.html",
        "Home, End, PgUp, PgDn",
        "Press-and-hold dictation",
        "active menu-bar chip may stay visible",
        "rebind dictation shortcuts in Dictation Settings",
        "compare <strong>Dictation History</strong> raw text, processed text, and the sent command",
        "Built-In Compose",
        "one shared prompt with selected-text and screenshot combinations",
        "per-combination auto-submit overrides",
        "Screenshot -> New chat + auto-submit",
        "Context Rules",
        "Clipboard History",
        "Command History",
        "Dictate -> Assistant",
        "Privacy And Local Files",
        "~/.claude/state/cliphistory/",
        "mark-failed, retention, and parsed result",
        "Claude - To-Do",
        "Safari, Chrome, Brave, Chromium, and Arc send the current tab URL",
        "Only the last non-empty stdout line is parsed",
        "prose containing <code>TASK_ID=abc123</code> does not count",
        "Result text appears in the completion notification, Command History row, and diagnostic summary",
        "<td>Stalled</td>",
        "updates.html",
        "troubleshooting.html",
        "Need to file a bug, request a feature, or ask for help?",
        "support.html",
        "For vulnerabilities, exposed secrets, private logs, or sensitive diagnostics",
        "security.html",
        "id=\"uninstall\"",
        "launchctl bootout \"gui/$(id -u)/com.claudecommand\" 2&gt;/dev/null || true",
        "rm -f ~/Library/LaunchAgents/com.claudecommand.plist",
        "com.claudecommand.clipwatch",
    ],
    "docs/settings.html": [
        "<title>Command Settings Reference</title>",
        "Default assistant",
        "Trigger rows",
        "Preview as",
        "Foreground",
        "Background",
        "Clipboard History",
        "Dictation Settings",
        "Creates or toggles the Command launch service",
        "Downloaded app installs do not need Terminal scripts",
        "Show in Menu Bar",
        "Show Dock icon",
        "command-export.json",
        "Import / Export Sections",
        "Shortcuts and prompts",
        "Prompt text and context rules",
        "Dictation vocabulary",
        "Keep current",
        "Overwrite",
        "Help &amp; Documentation",
        "Support &amp; Reporting",
        "View on GitHub",
        "Documentation / User Guide / Install Guide / Uninstall",
        "Settings Reference / Quick Reference / Troubleshooting / Permissions / Support / Security Policy",
        "private-report guidance",
        "Examples / FAQ / Updates / Privacy / Changelog / Alpha Limitations",
        "Icon Treatments / Background Architecture / Release Checklist",
        "Copy Diagnostic Info",
        "Private Security Report",
        "GitHub private advisory for vulnerabilities, exposed secrets, private logs, or sensitive diagnostics",
    ],
    "docs/SETTINGS_REFERENCE.md": [
        "Default assistant",
        "Trigger rows",
        "Preview as",
        "Foreground",
        "Background",
        "Clipboard History",
        "Dictation Settings",
        "Creates or toggles the Command launch service",
        "Downloaded app installs do not need Terminal scripts",
        "Show in Menu Bar",
        "Show Dock icon",
        "command-export.json",
        "Import / Export Sections",
        "Shortcuts and prompts",
        "Prompt text and context rules",
        "Dictation vocabulary",
        "Keep current",
        "Overwrite",
        "Help & Documentation",
        "Support & Reporting",
        "View on GitHub",
        "Documentation / User Guide / Install Guide / Uninstall",
        "Settings Reference / Quick Reference / Troubleshooting / Permissions / Support / Security Policy",
        "private-report guidance",
        "Examples / FAQ / Updates / Privacy / Changelog / Alpha Limitations",
        "Icon Treatments / Background Architecture / Release Checklist",
        "Copy Diagnostic Info",
        "Private Security Report",
        "GitHub private advisory for vulnerabilities, exposed secrets, private logs, or sensitive diagnostics",
    ],
    "docs/STATUS.md": [
        "100 Swift",
        "56 Node",
        "41 shell",
        "python3 ./test/test-docs.py",
        "compact solid-purple voice-lines",
        "compact active width",
        "shared CSS",
        "negative letter spacing",
    ],
    "docs/CHANGELOG.md": [
        "settings reference",
        "troubleshooting",
        "icon treatments",
        "alpha limitations",
        "SETTINGS_REFERENCE.md",
        "Defaults In This Alpha",
        "compact solid-purple voice-lines menu-bar icon",
        "animated white bars",
        "Copy Diagnostic Info includes app path, bundle ID, update channel/check status, shortcut binding summary, Set Up status",
        "About includes View on GitHub, Report a Bug, Request Feature, Security Policy, and Private Security Report routes",
        "App and repository are now named Command",
        "GitHub Pages lives under `/command/`",
        "compatibility IDs/paths stay stable",
        "rebind dictation shortcuts in Dictation Settings",
        "security policy",
        "404 fallback",
        "bundled docs/README source parity",
        "required runtime resources",
        "CI runs a release-asset smoke test",
    ],
    "docs/troubleshooting.html": [
        "Screenshot -> New chat shortcut does nothing",
        "Home or another non-F-key shortcut does not start dictation",
        "rebind dictation shortcuts in <strong>Settings -> Dictation Settings</strong>",
        "press-and-hold/double-tap recorder path",
        "Voice custom action records but does not send",
        "The stop sound means release was accepted",
        "Dictation feels slow after release",
        "Watch the active menu-bar chip, not the sound",
        "support report",
        "Dictation History has full raw text but sent command is missing words",
        "loss happened during dispatch, not recording",
        "Right-click actions show as optional or missing",
        "Right-click To-Do does not capture a browser URL",
        "front app is Safari, Chrome, Brave, Chromium, or Arc",
        "Global shortcuts do not need Services",
        "Background run logs",
        "install.html",
        "Copy Diagnostic Info",
        "For bugs, open",
    ],
    "docs/TROUBLESHOOTING.md": [
        "Screenshot -> New chat shortcut does nothing",
        "Home or another non-F-key shortcut does not start dictation",
        "rebind dictation shortcuts in **Settings -> Dictation Settings**",
        "press-and-hold/double-tap recorder path",
        "Voice custom action records but does not send",
        "The stop sound means release was accepted",
        "Dictation feels slow after release",
        "Watch the active menu-bar chip, not the sound",
        "support report",
        "Dictation History has full raw text but sent command is missing words",
        "loss happened during dispatch, not recording",
        "Right-click actions show as optional or missing",
        "Right-click To-Do does not capture a browser URL",
        "front app is Safari, Chrome, Brave, Chromium, or Arc",
        "Global shortcuts do not need Services",
        "Background run logs",
        "INSTALL.md",
        "Copy Diagnostic Info",
        "For bugs, open",
    ],
    "docs/updates.html": [
        "Install Guide",
        "install.html",
        "Update From The App",
        "Rename Compatibility",
        "href=\"#rename-compatibility\"",
        "<section id=\"rename-compatibility\">",
        "Command was previously named ClaudeCommand",
        "local support paths intentionally remain",
        "Manual Install",
        "Download the latest <code>Command-*.zip</code>",
        "https://github.com/galbutnotgirl/command/releases/latest",
        "latest GitHub Release",
        "earliest builds, most frequent changes",
        "pre-release builds intended for broader testing",
        "stable builds only; visible but unavailable until the first stable release exists",
        "Stable accepts stable tags only once stable is enabled",
        "Stable stays unavailable until a stable release exists",
        ".zip.sha256",
        "same folder as the zip",
        "downloads the attached <code>Command-*.zip</code> asset",
        "ignores checksum sidecar files",
        "replaces <code>~/Applications/Command.app</code>",
        "clears quarantine, and restarts",
        "Launch at login is not required for the updater to reopen Command",
        "opens the release page for manual install",
        "Settings -> About -> Import / Export",
        "click <strong>Export</strong>",
        "click <strong>Import</strong>",
        "Roll Back",
    ],
    "docs/UPDATES.md": [
        "INSTALL.md",
        "Install Guide",
        "Update From The App",
        "Rename Compatibility",
        "Command was previously named ClaudeCommand",
        "local support paths intentionally remain",
        "Install Alpha Manually",
        "Download the latest `Command-*.zip`",
        "https://github.com/galbutnotgirl/command/releases/latest",
        "latest GitHub Release",
        "earliest builds, most frequent changes",
        "pre-release builds intended for broader testing",
        "stable builds only; visible but unavailable until the first stable release exists",
        ".zip.sha256",
        "same folder as the zip",
        "downloads the attached `Command-*.zip` asset",
        "ignores checksum sidecar files",
        "replaces `~/Applications/Command.app`",
        "clears quarantine, and restarts",
        "Launch at login is not required for the updater to reopen Command",
        "opens the release page for manual install",
        "Settings -> About -> Import / Export",
        "Click **Export**",
        "click **Import**",
        "Roll Back",
    ],
    "docs/INSTALL.md": [
        "https://github.com/galbutnotgirl/command/releases/latest",
        "latest GitHub Release",
        "ClaudeCommand-1.2.0-alpha.6.zip",
        "Existing Alpha Installs",
        "Command was previously named ClaudeCommand",
        "local support paths stay compatible",
        "System Settings -> Privacy & Security",
        "Settings -> Set Up",
        "Help & Documentation",
        "Support & Reporting",
        "View on GitHub",
        "Copy Diagnostic Info",
        "Report a Bug",
        "Request Feature",
        "Security Policy",
        "Private reporting path, supported alpha versions, redaction guidance, and privacy links.",
        "Private Security Report",
        "GitHub private advisory for vulnerabilities, exposed secrets, private logs, or sensitive diagnostics",
        "Icon Treatments / Background Architecture / Release Checklist",
        "Examples / FAQ / Updates / Privacy / Changelog / Alpha Limitations",
        "Quick Reference",
        "Install From Source",
        "Permissions",
        "Binary installs do not require Terminal scripts",
        "legacy SendHelper keystroke fallback",
        "Optional, if you want legacy right-click Services",
        "For local development, use",
        "./script/build_and_run.sh --verify",
        "pings the app dispatch socket",
        "For downloaded app installs, use **Settings -> About -> Copy Diagnostic Info**",
        "From a repo checkout, maintainers can also run",
        "required Set Up item still shows red",
        "rebind dictation shortcuts in **Settings -> Dictation Settings**",
        "Command requires macOS 14 or later.",
        "It requires macOS 14 or later plus Xcode command-line tools.",
        "PERMISSIONS.md",
        "./doctor.sh",
    ],
    "docs/UNINSTALL.md": [
        "com.claudecommand.clipwatch",
        "Optional Data Removal",
        "For a downloaded app install",
        "osascript -e 'quit app \"Command\"' 2>/dev/null || true",
        "2>/dev/null || true",
        "source-only Quick Actions",
        "pgrep -fl Command",
        "INSTALL.md",
    ],
    "docs/install.html": [
        "<title>Command Install Guide</title>",
        "https://github.com/galbutnotgirl/command/releases/latest",
        "latest GitHub Release",
        "ClaudeCommand-1.2.0-alpha.6.zip",
        "System Settings -> Privacy &amp; Security",
        "Open Anyway",
        "xattr -dr com.apple.quarantine ~/Applications/ClaudeCommand.app",
        "Existing Alpha Installs",
        "href=\"#existing-alpha\"",
        "<section id=\"existing-alpha\">",
        "Command was previously named ClaudeCommand",
        "local support paths stay compatible",
        "Command requires macOS 14 or later.",
        "It requires macOS 14 or later plus Xcode command-line tools.",
        "Settings -> Set Up",
        "Help &amp; Documentation",
        "Support &amp; Reporting",
        "View on GitHub",
        "Copy Diagnostic Info",
        "Report a Bug",
        "Request Feature",
        "Private Security Report",
        "GitHub private advisory for vulnerabilities, exposed secrets, private logs, or sensitive diagnostics",
        "Icon Treatments / Background Architecture / Release Checklist",
        "Examples / FAQ / Updates / Privacy / Changelog / Alpha Limitations",
        "Quick Reference",
        "Install From Source",
        "For local development, use",
        "./script/build_and_run.sh --verify",
        "pings the app dispatch socket",
        "legacy SendHelper keystroke fallback",
        "Permissions",
        "required Set Up item still shows red",
        "rebind dictation shortcuts in <strong>Settings -> Dictation Settings</strong>",
        "<h2>Next</h2>",
        "permissions.html",
    ],
    "docs/uninstall.html": [
        "<title>Command Uninstall</title>",
        "com.claudecommand.clipwatch",
        "Optional Data Removal",
        "For a downloaded app install",
        "osascript -e 'quit app \"Command\"' 2&gt;/dev/null || true",
        "2&gt;/dev/null || true",
        "source-only Quick Actions",
        "pgrep -fl Command",
        "install.html",
    ],
    "docs/RELEASE_CHECKLIST.md": [
        "404.html",
        "install.html",
        "uninstall.html",
        "AppleDouble",
        "STATUS.md",
        ".zip.sha256",
        "heading parity",
        "About docs-button drift",
        "docs-home coverage drift",
        "README docs-table drift",
        "Settings sidebar drift",
        "local media assets",
        "sidebar navigation links the full docs set",
        "Find Your Path",
        "install/update, configure prompts, write prompt text, use voice, run background actions, and fix/report",
        "Settings -> About** docs button",
        "User Guide",
        "Install Guide",
        "Uninstall",
        "Settings Reference",
        "Quick Reference",
        "Troubleshooting",
        "Support",
        "Security Policy",
        "Examples",
        "FAQ",
        "Updates",
        "Privacy",
        "Changelog",
        "Alpha Limitations",
        "README.md",
        "SUPPORT.md",
        "SECURITY.md",
        "CONTRIBUTING.md",
        ".github/ISSUE_TEMPLATE/config.yml",
        ".github/ISSUE_TEMPLATE/bug_report.md",
        ".github/ISSUE_TEMPLATE/feature_request.md",
        ".github/pull_request_template.md",
        "GitHub repo surface opens",
        "Feature request",
        "Private security report",
        "issue chooser routes install, troubleshooting, support, private security report, latest Alpha release, bug reports, and feature requests",
        "Settings -> About** support action",
        "Copy Diagnostic Info**, **Report a Bug**, **Request Feature**, and **Private Security Report",
        "public issue buttons open the right templates",
        "GitHub private advisory creation",
        "Settings -> About -> View on GitHub",
        "pull request template asks for user impact, docs parity, sensitive-report routing",
        "issue-template/chooser parity",
        "bundled-doc release smoke",
        "updates.html",
        "permissions.html",
        "https://galbutnotgirl.github.io/command/updates.html",
        "https://galbutnotgirl.github.io/command/permissions.html",
        "troubleshooting.html",
        "https://galbutnotgirl.github.io/command/troubleshooting.html",
        "faq.html",
        "permissions.html",
        "PERMISSIONS.md",
        "privacy.html",
        "PRIVACY.md",
        "support.html",
        "icon-treatments.html",
        "background.html",
        "release.html",
        ".zip.sha256",
        "./test/test-release-asset.sh",
        "byte-for-byte current with source",
        "including `PRIVACY.md` and `SECURITY.md`",
        "minimum macOS metadata is `14.0`",
        "minimum macOS `14.0`",
        "packaged executable exists and is executable",
        "codesign metadata identifies `com.claudecommand`",
        "stale bundled docs",
        "required runtime resources",
        "VERSION=\"$(cat ../VERSION)\"",
        "shasum -a 256 -c \"Command-<version>.zip.sha256\"",
        "unzip -l \"Command-<version>.zip\"",
        "no matches and exit 1",
        "sitemap.xml",
        "robots.txt",
        "canonical GitHub Pages base",
        "old `/claude-command/` Pages path",
        "redirect-only to `/command/`",
        "Download Alpha",
        "latest GitHub Release",
        "https://github.com/galbutnotgirl/command/releases/latest",
        "not the generic releases list",
    ],
    "docs/release.html": [
        "every shareable bundled docs asset",
        "required runtime resources",
        "AppleDouble",
        "STATUS.md",
        ".sha256",
        "swift test",
        "node --test",
        "./test/test-shell.sh",
        "python3 ./test/test-docs.py",
        "./release.sh --publish --notes=\"Short release notes here.\"",
        "rendered HTML structure",
        "heading parity",
        "About docs-button drift",
        "docs-home coverage drift",
        "README docs-table drift",
        "Settings sidebar drift",
        "local media assets",
        "sidebar navigation links the full docs set",
        "Find Your Path",
        "install/update, configure prompts, write prompt text, use voice, run background actions, and fix/report",
        "Download Alpha",
        "latest GitHub Release",
        "canonical GitHub Pages base",
        "old <code>/claude-command/</code> Pages path",
        "redirect-only to <code>/command/</code>",
        "https://github.com/galbutnotgirl/command/releases/latest",
        "not the generic releases list",
        "--skip-checks",
        "./test/test-release-asset.sh",
        "byte-for-byte current with source",
        "including <code>PRIVACY.md</code> and <code>SECURITY.md</code>",
        "minimum macOS metadata <code>14.0</code>",
        "minimum macOS <code>14.0</code>",
        "packaged executable exists and is executable",
        "codesign metadata identifies <code>com.claudecommand</code>",
        "stale bundled docs",
        "https://github.com/galbutnotgirl/command/blob/main/SUPPORT.md",
        "https://github.com/galbutnotgirl/command/blob/main/CONTRIBUTING.md",
        "https://github.com/galbutnotgirl/command/issues/new?template=bug_report.md",
        "https://github.com/galbutnotgirl/command/issues/new?template=feature_request.md",
        "Manual spot checks",
        "VERSION=\"$(cat ../VERSION)\"",
        "shasum -a 256 -c \"Command-&lt;version&gt;.zip.sha256\"",
        "unzip -l \"Command-&lt;version&gt;.zip\"",
        "no matches and exit 1",
        "install.html",
        "uninstall.html",
        "Settings -> About</strong> support action",
        "Copy Diagnostic Info</strong>, <strong>Report a Bug</strong>, <strong>Request Feature</strong>, and <strong>Private Security Report",
        "<strong>Security Policy</strong>",
        "public issue buttons open the right templates",
        "GitHub private advisory creation",
        "Settings -> About</strong> docs button",
        "User Guide",
        "Install Guide",
        "Uninstall",
        "Quick Reference",
        "Examples",
        "FAQ",
        "Updates",
        "Privacy",
        "Changelog",
        "README.md",
        "SUPPORT.md",
        "SECURITY.md",
        "CONTRIBUTING.md",
        "issue chooser config",
        "bug report template",
        "Feature request",
        "pull request template",
        "GitHub repo surface opens",
        "Private security report",
        "issue chooser routes install, troubleshooting, support, private security report, latest Alpha release, bug reports, and feature requests",
        "pull request template asks for user impact, docs parity, sensitive-report routing",
        "issue-template/chooser parity",
        "bundled-doc release smoke",
        "404 fallback",
        "sitemap.xml",
        "robots.txt",
        "faq.html",
        "privacy.html",
        "PRIVACY.md",
        "support.html",
        "icon-treatments.html",
        "background.html",
        "release.html",
        "background architecture",
        "release checklist",
    ],
    "docs/ICON_TREATMENTS.md": [
        "Current Recording Direction",
        "System mic/camera beacon",
        "compact solid-purple voice-lines icon",
        "agent/MenuBar.swift",
    ],
    "docs/icon-treatments.html": [
        "<title>Command Icon Treatments</title>",
        'href="#current-recording-direction"',
        '<section id="current-recording-direction">',
        'href="#animated-previews"',
        '<section id="animated-previews">',
        'href="#options"',
        '<section id="options">',
        'href="#implementation-notes"',
        '<section id="implementation-notes">',
        "icon-treatment-bold-animated.svg",
        "System mic/camera beacon",
        "compact solid-purple voice-lines icon",
        "White mic-style badge",
        "agent/MenuBar.swift",
    ],
    "docs/PERMISSIONS.md": [
        "Accessibility",
        "Screen Recording",
        "Microphone",
        "Quick Actions are optional legacy right-click Services",
        "tccutil reset Accessibility com.claudecommand",
        "The identifier remains `com.claudecommand`",
        "Copy Diagnostic Info",
    ],
    "docs/permissions.html": [
        "<title>Command Permissions</title>",
        "Accessibility",
        "Screen Recording",
        "Microphone",
        "Quick Actions are optional legacy right-click Services",
        "tccutil reset Accessibility com.claudecommand",
        "The identifier remains <code>com.claudecommand</code>",
        "Copy Diagnostic Info",
    ],
    "docs/PRIVACY.md": [
        "Local File Locations",
        "~/Library/Preferences/com.claudecommand.plist",
        "~/Library/LaunchAgents/com.claudecommand.plist",
        "Starts Command at login when Launch at login is enabled",
        "Copy Diagnostic Info",
        "Use [Security Policy](SECURITY.md)",
        "vulnerability, exposed secret, private log, or sensitive data path",
    ],
    "docs/privacy.html": [
        "PRIVACY.md",
        "~/Library/Preferences/com.claudecommand.plist",
        "~/Library/LaunchAgents/com.claudecommand.plist",
        "Starts Command at login when Launch at login is enabled",
        "Copy Diagnostic Info",
        "private vulnerability reporting",
        "vulnerability, exposed secret, private log, or sensitive data path",
    ],
    "docs/USER_GUIDE.md": [
        "| Stable | Stable builds only; visible but unavailable until the first stable release exists. |",
        "UPDATES.md",
        "Bound prompt/action shortcuts",
        "Stop Dictation / Cancel Dictation",
        "Quit Command",
        "Unbound combinations, disabled triggers, and auto-submit combinations",
        "Home, End, PgUp, PgDn",
        "Press-and-hold dictation",
        "active menu-bar chip may stay visible",
        "rebind dictation shortcuts in Dictation Settings",
        "Background run logs",
        "mark-failed, retention, and parsed result",
        "Only the last non-empty stdout line is parsed",
        "prose containing `TASK_ID=abc123` does not count",
        "Result text appears in the completion notification, Command History row, and diagnostic summary",
        "| Stalled | Record stayed running after process likely died.",
        "For vulnerabilities, exposed secrets, private logs, or sensitive diagnostics",
        "Security Policy",
    ],
    "docs/FAQ.md": [
        "How do I install Command the first time?",
        "INSTALL.md",
        "latest GitHub Release",
        "https://github.com/galbutnotgirl/command/releases/latest",
        "How do updates work?",
        "UPDATES.md",
        ".zip.sha256",
        "same folder",
        "How should I request a feature?",
        "https://github.com/galbutnotgirl/command/issues/new?template=feature_request.md",
        "workflow, trigger type, delivery mode, destination, auto-submit preference",
        "Fresh defaults use F8/Option-F8",
        "Built-in Dictate shortcuts live in **Dictation Settings**",
        "voice prompt triggers live in **Shortcut Settings**",
        "Also check **Background Settings**",
        "Why did Claude - To-Do send text instead of the URL?",
        "Right-click Services prefer highlighted text",
        "Why do some local paths still say `claude-command`?",
        "bundle identifier stay stable on purpose",
        "The stop sound means release was accepted",
    ],
    "docs/faq.html": [
        "FAQ covering install",
        "auto-submit behavior",
        "Answers for install",
        "How do I install Command the first time?",
        "install.html",
        "latest GitHub Release",
        "https://github.com/galbutnotgirl/command/releases/latest",
        "same folder",
        "id=\"updates\"",
        "updates.html",
        ".zip.sha256",
        "Also check <strong>Background Settings</strong>",
        "Why did Claude - To-Do send text instead of the URL?",
        "Right-click Services prefer highlighted text",
        "Why do some local paths still say <code>claude-command</code>?",
        "bundle identifier stay stable on purpose",
        "Fresh defaults use F8/Option-F8",
        "Built-in Dictate shortcuts live in <strong>Dictation Settings</strong>",
        "voice prompt triggers live in <strong>Shortcut Settings</strong>",
        "stop timing is tuned inside the app",
        "The stop sound means release was accepted",
    ],
    "docs/examples.html": [
        "Google Docs Context Rule",
        "Import Settings On A New Mac",
        "docs.google.com",
        "Source-only right-click variant",
        "Claude - To-Do",
        "Sends current tab URL from Safari, Chrome, Brave, Chromium, or Arc",
    ],
    "docs/changelog.html": [
        "Dictate -> Assistant",
        "install, uninstall",
        "settings reference",
        "troubleshooting",
        "icon treatments",
        "alpha limitations",
        "compact solid-purple voice-lines menu-bar icon",
        "animated white bars",
        "Copy Diagnostic Info includes app path",
        "About includes View on GitHub, Report a Bug, Request Feature, Security Policy, and Private Security Report routes",
        "required runtime resources",
        "CI runs a release-asset smoke test",
        "stalled-run recovery",
        "offline HTML/CSS/SVG/Markdown docs",
        "Defaults In This Alpha",
        "Compose groups selected-text and screenshot combinations",
        "Alpha Notes",
        "rebind dictation shortcuts in Dictation Settings",
        "Background actions use local",
    ],
    "docs/background.html": [
        "Command is a native macOS menu-bar app, not Electron",
        "CLAUDE_CAPTURE_HOME",
        "~/.claude/state/command-hotkeys.json",
        "source: \"selection\"",
        "Settings -> Command History -> Background Settings",
        "Settings -> Shortcuts -> Custom Actions",
        "CustomActionTextEntryPanel",
        "TASK_ID=&lt;id&gt;",
        "ERROR=&lt;reason&gt;",
        "last non-empty line is parsed",
        "does not run follow-up actions",
        "vendor/claude-command-capture/docs/HANDOFF.md",
    ],
    "docs/QUICK_REFERENCE.md": [
        "Screenshot -> New chat + auto-submit",
        "Dictate -> Assistant",
        "Dictation Settings",
        "Glossary",
        "A named prompt setup, with defaults and one or more triggers.",
        "A local `claude -p` run with no Claude window.",
        "Home, End, PgUp, PgDn",
        "Press-and-hold voice",
        "Double-tap voice",
        "active menu-bar chip can stay visible",
        "rebind dictation shortcuts in Dictation Settings",
        "Bound prompt/action shortcut",
        "Stop Dictation / Cancel Dictation",
        "Quit Command",
        "Unbound combinations, disabled triggers, and auto-submit combinations",
        "One shared Compose prompt powers six built-in combinations",
        "Save selected settings sections to JSON.",
        "Preview a saved JSON file, then choose per-section handling.",
        "To-Do URL not captured",
        "Safari, Chrome, Brave, Chromium, or Arc",
        "Help From The App",
        "Help & Documentation",
        "Support & Reporting",
        "View on GitHub",
        "final non-empty stdout line",
        "diagnostic summary",
        "Prose containing `TASK_ID=abc123` does not count",
        "No follow-up action runs from that value yet",
        "Icon Treatments / Background Architecture / Release Checklist",
        "Security Policy",
        "Private reporting path, supported alpha versions, redaction guidance, and privacy links.",
        "Private Security Report",
        "GitHub private advisory for vulnerabilities, exposed secrets, private logs, or sensitive diagnostics",
        "Settings Reference",
        "Default shortcuts, prompt variables, common fixes, and local data paths.",
        "Install Guide",
        "Uninstall",
        "Updates",
        "Privacy",
        "FAQ",
        "Changelog",
        "Alpha Limitations",
        "Icon Treatments",
        "Release Checklist",
        "Permissions",
        "SUPPORT.md",
        "LIMITATIONS.md",
    ],
    "docs/LIMITATIONS.md": [
        "Use this before trying or sharing an alpha build.",
        "New chat + auto-submit combinations are unbound by default",
        "F6/F7/F8 may control macOS features",
        "Quick Actions are optional source-install Services",
        "Compare raw text, processed text, and the sent command.",
        "Structured `KEY=value` output is displayed",
        "does not run follow-up actions yet",
        "Stable stays unavailable until a stable release exists",
        "Use [Security Policy](SECURITY.md)",
    ],
    "docs/limitations.html": [
        "<title>Command Alpha Limitations</title>",
        "Alpha Expectations",
        "New chat + auto-submit combinations are unbound by default",
        "F6/F7/F8 may control macOS features",
        "Quick Actions are optional source-install Services",
        "Compare raw text, processed text, and the sent command.",
        "Structured <code>KEY=value</code> output is displayed",
        "does not run follow-up actions yet",
        "Stable stays unavailable until a stable release exists",
        "private vulnerability reporting",
    ],
    "agent/SettingsWindow.swift": [
        "URLComponents(url: local, resolvingAgainstBaseURL: false)",
        "URLComponents(string: urlString)",
        "components?.fragment = fragment",
        "components?.url",
        "builtInComposeSettings",
        "Prompt text and context rules",
        "Background settings",
        "Delete this background run?",
        "Removes the run record",
        "Stable is visible but unavailable until the first stable release exists",
        "openHelpDoc(named: \"install\", fragment: \"source\")",
        "GridItem(.adaptive(minimum: 150)",
        "Text(\"Help & Documentation\")",
        "Text(\"Support & Reporting\")",
        "panel.nameFieldStringValue = \"command-export.json\"",
        "Label(\"Documentation\"",
        "openHelpDoc(named: \"guide\")",
        "Label(\"User Guide\"",
        "openHelpDoc(named: \"install\")",
        "Label(\"Install Guide\"",
        "openHelpDoc(named: \"uninstall\")",
        "openHelpDoc(named: \"settings\")",
        "openHelpDoc(named: \"quick-reference\")",
        "openHelpDoc(named: \"troubleshooting\")",
        "openHelpDoc(named: \"permissions\")",
        "openHelpDoc(named: \"support\")",
        "openHelpDoc(named: \"security\")",
        "openHelpDoc(named: \"examples\")",
        "openHelpDoc(named: \"faq\")",
        "openHelpDoc(named: \"updates\")",
        "openHelpDoc(named: \"privacy\")",
        "openHelpDoc(named: \"changelog\")",
        "openHelpDoc(named: \"limitations\")",
        "openHelpDoc(named: \"icon-treatments\")",
        "openHelpDoc(named: \"background\")",
        "openHelpDoc(named: \"release\")",
        "--- Shortcut bindings ---",
        "Custom actions:",
        "--- Set Up status ---",
        "Dictation model:",
        "Label(\"Request Feature\"",
        "Label(\"Private Security Report\"",
        "securityAdvisoryURL()",
        "Copy Diagnostic Info first, review it for sensitive content, then use Report a Bug for problems, Request Feature for non-bug workflow",
        "Private Security Report for vulnerabilities, exposed secrets, private logs, or sensitive diagnostics",
        "Recent command history (last 5 each, summaries only)",
        "loadForegroundCommandHistory(limit: 5)",
        "loadHandoffSubmissions(limit: 5)",
        "log=\\(logFile)",
        "Recent dictation entries (last 3, truncated)",
        "\(HOME)/.claude/logs/clipwatch.err",
        "App path:",
        "Bundle ID:",
        "Minimum macOS:",
        "Update channel:",
        "Update check:",
        "Update download asset:",
        "Default assistant:",
        "Quick Actions optional",
        "Restart Command",
        "Restart Command. If it still fails, reinstall from the Install Guide",
        "If macOS asks again after a rebuild, re-grant permissions for Command.",
        "Function-key shortcuts don't fire? Enable standard function keys in macOS Keyboard settings, or rebind prompt and dictation shortcuts.",
        "Clipboard History is off. Enable it in Clipboard History settings if you want the picker.",
        "Red means a checked requirement is not met for that workflow",
        "claude-command.log (shortcut actions)",
        "command-agent.err (app dispatch)",
        "clipwatch.err (Clipboard History)",
    ],
    "agent/Recorder.swift": [
        "Open Settings -> Dictation Settings and click Download",
    ],
    "agent/main.swift": [
        "Command — the one persistent app process",
        "Enable Command, then restart Command to apply it.",
        "Reinstall from the Install Guide",
        "reopenAfterExit",
        "ensureLaunchAgentInstalled",
        "detached open covers manual launches",
    ],
    "agent/Permissions.swift": [
        "Background service",
        "ensureLaunchAgentInstalled",
        "Bundle.main.executablePath",
        "Library/LaunchAgents/\\(AGENT_LABEL).plist",
        "Local app dispatch socket",
        "Clipboard History running",
        "Optional source-install Services are not installed",
        "Global shortcuts do not need them",
        "state: fileExists(home(\"Library/Services/Claude - Add.workflow\")) ? .ok : .unknown",
    ],
    "agent/Sources/ClaudeCommandCore/UpdateLogic.swift": [
        "case stable = \"prod\"",
        "case .stable: return \"Stable\"",
    ],
    "agent/Sources/ClaudeCommandCore/Templates.swift": [
        "BUILT_IN_COMPOSE_TEMPLATE_ACTIONS",
        "\"shotadd\"",
        "\"shotcomment\"",
        "\"shotgo\"",
    ],
    "agent/Updater.swift": [
        "URLQueryItem(name: \"template\", value: \"bug_report.md\")",
        "func requestFeatureURL() -> URL?",
        "URLQueryItem(name: \"template\", value: \"feature_request.md\")",
        "func securityAdvisoryURL() -> URL?",
        "security/advisories/new",
        "**Bundle ID:**",
        "**App path:**",
        "**Update channel:**",
        "**Trigger / workflow:**",
        "Selected text / Screenshot / Popup / Voice / Dictation / Clipboard History / Background / Import / Export / Update",
        "Review copied diagnostics for sensitive log or recent-text content",
        "Dictation History raw text or processed text",
        "~/.claude/logs/clipwatch.err (Clipboard History)",
        "Do not use this public issue for vulnerabilities",
        "private vulnerability reporting instead",
        "shortcut actions",
        "app dispatch",
    ],
    "agent/MenuBar.swift": [
        "activeIconWidth: CGFloat { max(30",
        "compact solid-purple voice indicator",
        "White animated bars carry the motion",
        "wide banner",
        "loadBindings().filter { $0.enabled && $0.keycode != 0 }",
        "NSMenuItemPlainView",
        "NSMenuItemPlainView(title: \"Settings\", shortcut: \"⌘,\")",
        "selectedMenuItemTextColor",
        "setAccessibilityRole(.menuItem)",
        "setAccessibilityLabel(title)",
        "accessibilityPerformPress",
        "intrinsicContentSize",
    ],
    "agent/Handoff.swift": [
        "Shared CLI settings for Background delivery",
        "legacy settings below support older background capture flows",
        "Legacy default skill",
        "Legacy text prompt",
        "Legacy image prompt",
    ],
    "doctor.sh": [
        "Command.app",
        "background service",
        "Command LaunchAgent loaded",
        "app dispatch socket up",
        "Clipboard History running",
        "LaunchAgent Program points at installed Command.app",
        "expected ${EXPECTED_AGENT_PROGRAM}",
        "${label} executable present",
        "Quick Actions not installed — optional source-only Services; global shortcuts do not need them",
        "no Background actions configured — CLI checks are optional",
        "Background actions configured:",
        "required for configured Background actions",
        "only needed for Background delivery",
        "Speech Recognition permission is not required for current Parakeet dictation",
        "Open Settings → Set Up / Dictation Settings for live microphone and model status",
        "EXPECTED_BUNDLE_ID=\"com.claudecommand\"",
        "EXPECTED_MIN_MACOS=\"14.0\"",
        "${label} minimum macOS",
        "${label} bundled docs present",
        "LSMinimumSystemVersion",
    ],
    "capture-handoff.sh": [
        "Background core missing — reinstall from the Install Guide.",
        "Background delivery needs Node.js 20+ on PATH.",
        "Command",
    ],
    "send-to-claude.sh": [
        "Background runner missing — reinstall from the Install Guide.",
        "set by Command when a hotkey fires",
        "prefer the always-running Command app",
        "Command passes the app that was frontmost",
        "ask Command to show its built-in picker",
        "GO_RAW=\"$(read_template go)\"",
        "COMMENT_RAW=\"$(read_template comment)\"",
        "ADD_RAW=\"$(read_template add)\"",
        "(Right-click \"Go\": {context} Then do what",
        "ACTION=\"${ACTION#shot}\"",
    ],
    "install-quick-action.sh": [
        "Actions installed as optional right-click Services",
        "Global hotkeys are owned by Command",
        "set-hotkeys.sh only binds Add/New",
        "Claude - New|comment",
        "Claude - Screenshot New|shotcomment",
    ],
    "uninstall-quick-action.sh": [
        '"Claude - New"',
        '"Claude - Screenshot New"',
        '"Claude - Comment"           # legacy names',
        '"Claude - Screenshot Comment"',
    ],
    "set-hotkeys.sh": [
        "Command global hotkeys",
        "Command owns hotkeys",
        "Command restarted with new config",
        "Command not running",
        "comment|Command - New|F8",
        "shotcomment|Command - Screenshot New|F7",
    ],
    "script/build_and_run.sh": [
        'APP_NAME="Command"',
        '"$ROOT_DIR/build-agent.sh"',
        "/usr/bin/open -n",
        "pgrep -x \"$APP_NAME\"",
        "APP_SOCKET=\"${HOME}/.claude/state/command-agent.sock\"",
        "ping_socket",
        "unexpected socket reply",
        "socket ping failed",
        "verify_bundle_docs",
        "limitations.html",
        "$APP_NAME runtime ok",
        "subsystem == \\\"$BUNDLE_ID\\\"",
    ],
    ".codex/environments/environment.toml": [
        'name = "claude-command"',
        'command = "./script/build_and_run.sh"',
    ],
    ".github/ISSUE_TEMPLATE/bug_report.md": [
        "Bundle ID:",
        "App path:",
        "Update channel:",
        "Before filing, check [Support](https://galbutnotgirl.github.io/command/support.html)",
        "[Troubleshooting](https://galbutnotgirl.github.io/command/troubleshooting.html)",
        "[Install Guide](https://galbutnotgirl.github.io/command/install.html)",
        "Dictation History",
        "~/.claude/logs/clipwatch.err",
        "Shortcut actions",
        "App dispatch, hotkey, and startup errors",
        "Clipboard History errors",
        "Clipboard source attribution",
        "Background run logs",
        "Default assistant:",
        "Shortcut row enabled and bound in Settings:",
        "Another app or macOS already uses that shortcut:",
        "Action or built-in command name:",
        "Action/trigger delivery, destination, and auto-submit overrides, if relevant:",
        "failed run status, parsed result if shown",
        "Copy Diagnostic Info includes current built-in and custom trigger binding summary",
        "Copy Diagnostic Info includes recent run status/result/error/log path",
        "full background log text still comes from **Command History**",
        "Target update version, if relevant:",
        "Review copied diagnostics for sensitive log or recent-text content",
        "Do not use this public issue for vulnerabilities",
        "Use [Security Policy](https://galbutnotgirl.github.io/command/security.html)",
        "private vulnerability reporting",
        "https://github.com/galbutnotgirl/command/security/advisories/new",
    ],
    ".github/ISSUE_TEMPLATE/feature_request.md": [
        "name: Feature request",
        "labels: enhancement",
        "Before filing, check [Support](https://galbutnotgirl.github.io/command/support.html)",
        "[Examples](https://galbutnotgirl.github.io/command/examples.html)",
        "[Settings Reference](https://galbutnotgirl.github.io/command/settings.html)",
        "Selected text",
        "Screenshot",
        "Voice / dictation",
        "Command History / background action",
        "Delivery: Existing chat / New chat / Background",
        "Destination: Default / Claude Chat / Claude Cowork / Claude Code / ChatGPT / Codex",
        "Auto-submit:",
        "Current setting or workaround:",
        "Needs Settings UI",
        "Needs menu-bar behavior",
        "Needs docs / examples",
        "Needs import/export support",
        "Needs release-note coverage",
        "Do not include private text, secrets, customer data, private logs, or sensitive diagnostics here",
        "Use [Security Policy](https://galbutnotgirl.github.io/command/security.html)",
        "https://github.com/galbutnotgirl/command/security/advisories/new",
    ],
    ".github/ISSUE_TEMPLATE/config.yml": [
        "blank_issues_enabled: false",
        "name: Install Guide",
        "https://galbutnotgirl.github.io/command/install.html",
        "name: Troubleshooting",
        "https://galbutnotgirl.github.io/command/troubleshooting.html",
        "name: Support",
        "https://galbutnotgirl.github.io/command/support.html",
        "name: Security Policy",
        "https://galbutnotgirl.github.io/command/security.html",
        "Read supported versions, redaction guidance, and private reporting path.",
        "name: Private Security Report",
        "https://github.com/galbutnotgirl/command/security/advisories/new",
        "https://github.com/galbutnotgirl/command/releases/latest",
    ],
    "docs/SUPPORT.md": [
        "INSTALL.md",
        "Dictation History",
        "shortcut binding summary",
        "Set Up permission/component status",
        "app path",
        "update channel/check status",
        "recent command summaries",
        "Clipboard History errors",
        "Background run logs",
        "last three dictation raw/processed previews",
        "Feature Requests",
        "Settings -> About -> Request Feature",
        "https://github.com/galbutnotgirl/command/issues/new?template=feature_request.md",
        "workflow, trigger type, delivery mode, destination, auto-submit preference",
        "Settings UI, menu-bar behavior, docs/examples, import/export support",
        "dictation tail-cutoff bugs",
        "raw text**, absent only from **processed text**",
        "present in both but missing from the sent command",
        "dictation state files",
        "~/.claude/logs/clipwatch.err",
        "Workflow Details",
        "Shortcut / trigger",
        "whether macOS or another app already uses the shortcut",
        "Version, bundle ID, minimum macOS, and app path",
        "`Minimum macOS`",
        "`App path`",
        "Review copied diagnostics for sensitive log or recent-text content",
        "Use **Settings -> About -> Private Security Report** or [Security Policy](SECURITY.md) instead",
        "Settings -> About -> Private Security Report",
        "private advisory",
        "vulnerability, exposed secret, private log, or sensitive diagnostic output",
        "background run summaries include status/result/error/log path",
        "Binary install checks",
        "From a repo checkout, maintainers can also run",
        "minimum macOS `14.0`",
        "bundled docs, executable presence, LaunchAgent Program path/socket",
        "required items are OK",
        "Optional items only need to be OK",
    ],
    "docs/support.html": [
        "install.html",
        "href=\"#feature-requests\"",
        "Dictation History",
        "shortcut binding summary",
        "Set Up permission/component status",
        "recent command summaries",
        "Clipboard History errors",
        "Background run logs",
        "last three dictation raw/processed previews",
        "Feature Requests",
        "https://github.com/galbutnotgirl/command/issues/new?template=feature_request.md",
        "workflow, trigger type, delivery mode, destination, auto-submit preference",
        "Settings UI, menu-bar behavior, docs/examples, import/export support",
        "dictation tail-cutoff bugs",
        "raw text</strong>, absent only from <strong>processed text</strong>",
        "present in both but missing from the sent command",
        "~/.claude/logs/clipwatch.err",
        "Workflow Details",
        "Shortcut / trigger",
        "whether macOS or another app already uses the shortcut",
        "Version, bundle ID, minimum macOS, and app path",
        "<code>Minimum macOS</code>",
        "<code>App path</code>",
        "Review copied diagnostics for sensitive log or recent-text content",
        "private vulnerability reporting",
        "Settings -> About -> Private Security Report",
        "private advisory",
        "vulnerability, exposed secret, private log, or sensitive diagnostic output",
        "background run summaries include status/result/error/log path",
        "Binary install checks",
        "From a repo checkout, maintainers can also run",
        "minimum macOS <code>14.0</code>",
        "bundled docs, executable presence, LaunchAgent Program path/socket",
        "required items are OK",
        "Optional items only need to be OK",
    ],
    "agent/OnboardingWindow.swift": [
        "selected text, screenshots, clipboard history, and dictation",
        "When enabled, copies stay local. Press F6 for a searchable picker",
        "voice custom actions",
    ],
    "build-agent.sh": [
        "About's docs buttons work",
        "<key>LSMinimumSystemVersion</key><string>14.0</string>",
    ],
    "release.sh": [
        "About's docs buttons",
        "Check every shareable docs asset",
    ],
    "test/test-release-asset.sh": [
        "release asset ok",
        "Command.app/Contents/Resources/docs/${required_doc}",
        "BACKGROUND_TRIGGER_INTEGRATION.md",
        "security.html",
        "SECURITY.md",
        "Command.app/Contents/Resources/README.md",
        "Command.app/Contents/Resources/${required_resource}",
        "CFBundleShortVersionString",
        "CFBundleIdentifier",
        "LSMinimumSystemVersion",
        "Info.plist minimum macOS",
        "packaged app executable missing or not executable",
        "codesign -dv",
        "Identifier=com.claudecommand",
        "Format=app bundle with Mach-O",
        "missing bundled runtime resource",
        "bundled docs asset is stale",
        "bundled README.md is stale",
        "bundled docs HTML metadata contains stale preview term",
        "Add/New/Go behavior",
        "Handoff History",
        "Clipboard daemon",
        "bundled docs/uninstall.html title label drifted",
        "bundled docs/privacy.html h1 label drifted",
        "bundled docs/quick-reference.html missing Background Architecture card label",
        "bundled docs/examples.html h1 label drifted",
        "claude-command-capture/bin/submit-cli.js",
        "Open each .*Settings -> About.* docs button",
        "Open each .*Settings -> About.*Alpha Limitations",
        "Icon Treatments",
        "Background Architecture",
        "Release Checklist",
        "Feature request template",
        "Request Feature",
        "bundled docs/faq.html missing auto-submit preview wording",
        "bundled docs/faq.html still has stale Add/New/Go preview wording",
        'id="existing-alpha"',
        "bundled docs/install.html missing neutral local-development wording",
        "bundled docs/install.html still has Codex-specific local-development wording",
        "The identifier remains <code>com.claudecommand</code>",
        "Why do some local paths still say <code>claude-command</code>",
        "command-export.json",
        "missing Feature request repo-surface check",
        "bundled docs/index.html missing auto-submit FAQ wording",
        "bundled docs/index.html still has stale Go behavior wording",
        "bundled docs/index.html missing neutral local-development wording",
        "bundled docs/index.html still has tool-specific local-development wording",
        "bundled docs/404.html missing polished fallback preview wording",
        "bundled docs/404.html missing current FAQ card wording",
        "bundled docs/404.html still has rough missing-links preview wording",
        "bundled docs/updates.html missing rename compatibility sidebar anchor",
        "bundled docs/release.html missing old Pages redirect guidance",
        "bundled docs/security.html missing local data scope sidebar anchor",
        "bundled docs/support.html missing feature requests sidebar anchor",
        "bundled docs/${linked_doc} missing sibling Security Policy link",
        "bundled docs/${linked_doc} still links outside bundled docs",
        "zip contains internal docs/STATUS.md",
        "checksum file malformed",
        "bundled README.md missing neutral local-development wording",
        "bundled README.md still has Codex-specific local-development wording",
        "bundled README.md missing Test workflow badge",
        "bundled README.md missing Pages workflow badge",
        "bundled README.md missing latest release badge",
        "bundled README.md missing MIT license badge",
    ],
    "docs/site.css": [
        ".skip-link",
        ".media-frame",
        "focus-visible",
        "overflow-x: hidden",
        "max-height: calc(100vh - 36px)",
        "scrollbar-gutter: stable",
        "max-width: 342px",
        "table-layout: fixed",
        "@media (max-width: 820px)",
    ],
    "docs/robots.txt": [
        "User-agent: *",
        "Sitemap: https://galbutnotgirl.github.io/command/sitemap.xml",
    ],
    "docs/sitemap.xml": [
        "<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">",
        "https://galbutnotgirl.github.io/command/",
        "https://galbutnotgirl.github.io/command/guide.html",
        "https://galbutnotgirl.github.io/command/settings.html",
        "https://galbutnotgirl.github.io/command/permissions.html",
        "https://galbutnotgirl.github.io/command/troubleshooting.html",
    ],
}
FORBIDDEN_TEXT = {
    "README.md": [
        "./build-agent.sh\n./build-helper.sh\n./install-agent.sh",
        "background handoff",
        "Codex app Run button uses",
    ],
    "CONTRIBUTING.md": [
        "macOS 13+",
        "./release.sh\n./release.sh --publish",
    ],
    "SECURITY.md": [
        "Privacy And Local Data",
    ],
    "docs/index.html": [
        "../README.md",
        "./build-agent.sh\n./build-helper.sh\n./install-agent.sh",
        "Codex local development:",
        "bug report details",
        "Bug reports, diagnostic info",
        "what to include in an issue",
        "Go behavior",
    ],
    "docs/404.html": [
        "docs page for missing links",
    ],
    "docs/USER_GUIDE.md": [
        "Settings -> Troubleshooting",
        "~/.claude/dictation/",
        "Menu bar -> Command History -> Background Settings",
        "background handoff",
        "Text(\"Prompt template\")",
        "bug report details",
        "restart agent",
        "Background command logs",
        "Worker activity",
        "Agent errors and dispatch logs",
        "Clipboard watcher errors",
        "[Uninstall Guide]",
    ],
    "docs/guide.html": [
        ">Uninstall Guide<",
        "background handoff",
    ],
    "docs/LIMITATIONS.md": [
        "../SECURITY.md",
    ],
    "docs/FAQ.md": [
        "background handoff",
        "increase stop/silence timing",
    ],
    "docs/faq.html": [
        "background handoff",
        "increase stop/silence timing",
        "Add/New/Go behavior",
    ],
    "docs/SUPPORT.md": [
        "../SECURITY.md",
        "clipwatch errors",
        "Clipboard History watcher errors",
        "Worker actions",
        "Agent, dispatch",
        "1.2.0-alpha.6",
    ],
    "docs/support.html": [
        "clipwatch errors",
        "Clipboard History watcher errors",
        "Worker actions",
        "Agent, dispatch",
        "1.2.0-alpha.6",
    ],
    "docs/QUICK_REFERENCE.md": [
        "~/.claude/dictation/",
        "clipwatch errors",
        "restart agent",
    ],
    "docs/quick-reference.html": [
        "clipwatch errors",
        "restart agent",
    ],
    "docs/INSTALL.md": [
        "Download latest",
        "clipwatch errors",
        "matching `.sha256`",
        "./build-agent.sh\n./build-helper.sh\n./install-agent.sh",
        "For local Codex development",
    ],
    "docs/install.html": [
        "Download latest",
        "clipwatch errors",
        "matching <code>.sha256</code>",
        "./build-agent.sh\n./build-helper.sh\n./install-agent.sh",
        "For local Codex development",
    ],
    "docs/BACKGROUND_TRIGGER_INTEGRATION.md": [
        "Background Trigger integration",
        "Menu bar -> Command History -> Background Settings",
        "Command History **menu bar** submenu",
        "Text / Screenshot / Popup",
        "**prompt template**",
        "prompt templates",
        "Prompt template",
        "skill/prompt template",
        "every handoff (Custom or Text)",
    ],
    "docs/background.html": [
        "Background Trigger integration",
        "prompt templates",
        "every handoff (Custom or Text)",
    ],
    "docs/RELEASE_CHECKLIST.md": [
        "[Uninstall Guide]",
    ],
    "docs/release.html": [
        ">Uninstall Guide<",
    ],
    "agent/MenuBar.swift": [
        "Command History",
        "Handoffs",
        "Go",
    ],
    "agent/Recorder.swift": [
        "Settings > Dictation and click Download",
        "Claude Command > Settings",
    ],
    "agent/main.swift": [
        "Claude Command",
        "CommandAgent",
        "Restart Agent",
    ],
    "build-agent.sh": [
        "<string>Claude Command</string>",
        "About -> Open User Guide",
        'cp "${DOCS_SRC}"/*.md "${APP}/Contents/Resources/docs/"',
        'cp "${DOCS_SRC}"/*.html "${APP}/Contents/Resources/docs/"',
        'cp "${DOCS_SRC}"/*.css "${APP}/Contents/Resources/docs/"',
    ],
    "install-quick-action.sh": [
        "Claude - Comment",
        "Claude - Screenshot Comment",
    ],
    "set-hotkeys.sh": [
        "Claude Command",
        "CommandAgent",
        "agent restarted",
        "agent not running",
        "agent owns hotkeys",
        "Claude - Comment",
        "Claude - Screenshot Comment",
    ],
    "release.sh": [
        "About → Open User Guide",
    ],
    "agent/Permissions.swift": [
        "CommandAgent",
        "Clipboard daemon",
        "Agent running",
        "Clipboard watcher running",
    ],
    "doctor.sh": [
        "CommandAgent.app",
        "agent LaunchAgent",
        "agent socket",
        "clipboard watcher running",
        "fail \"no Quick Actions\"",
        "run ./install-quick-action.sh\"; }",
        "required for the handoff pipeline",
        "background core needs 20+",
        "whisper",
    ],
    "agent/SettingsWindow.swift": [
        "Text(\"Prompt template\")",
        "Stable releases only.",
        "One shared prompt with text and screenshot combinations.",
        "Create action first, then add more triggers from its edit window.",
        "Handoff settings",
        "Delete this handoff record?",
        "Removes the submission record",
        "Move shortcuts, prompts, templates",
        "Clipboard daemon",
        "Clipboard history daemon",
        "Restart agent",
        "restart agent",
        "After a rebuild, re-grant permissions",
        "If F5–F8 don't fire",
        "Agent socket missing",
        "Agent running",
        "Clipboard History watcher not running",
        "clipwatch.err (daemon)",
        "claude-command.log (worker)",
        "command-agent.err (agent)",
    ],
    "agent/Updater.swift": [
        "claude-command.log (worker)",
        "command-agent.err (agent)",
    ],
    "agent/OnboardingWindow.swift": [
        "Every copy is saved",
        "drop the image straight into Claude",
        "pasting your selected text, pressing Return",
    ],
    "agent/Handoff.swift": [
        "\"Handoff failed\"",
        "Handoff core missing",
        "Text prompt template",
        "Image prompt template",
        "Background commands render captures into prompts",
        "Compatibility text prompt template",
        "Compatibility image prompt template",
        "capture-handoff callers",
        "Fallback for legacy capture callers",
    ],
    "send-to-claude.sh": [
        "CommandAgent",
        "com.microsoft.edgemac",
        "Claude Command",
        "Settings ▸ Templates ▸ Context",
        "Handoff worker missing",
    ],
    "capture-handoff.sh": [
        "Claude Command",
        "Handoff core missing",
        "Handoff needs Node.js",
    ],
    "docs/TROUBLESHOOTING.md": [
        "increase stop/silence timing",
        "manual install from GitHub Releases",
        "restart agent",
        "Background command logs",
        "diagnostic lines in a bug report",
    ],
    "docs/troubleshooting.html": [
        "increase stop/silence timing",
        "manual install from GitHub Releases",
        "restart agent",
        "Background command logs",
        "diagnostic lines in a bug report",
    ],
    "docs/UPDATES.md": [
        "Download latest",
        "manual install from GitHub Releases",
        "restart agent",
        "Settings -> About -> Export",
        "Settings -> About -> Import**",
        "production releases only",
    ],
    "docs/updates.html": [
        "Download latest",
        "manual install from GitHub Releases",
        "restart agent",
        "Settings -> About -> Export",
        "Settings -> About -> Import</strong>",
        "production releases only",
    ],
    "docs/PRIVACY.md": [
        "../SECURITY.md",
        "Worker, agent",
        "Starts Command at login when installed",
    ],
    "docs/privacy.html": [
        "Worker, agent",
        "Starts Command at login when installed",
    ],
    "docs/UNINSTALL.md": [
        "Worker logs",
    ],
    "docs/uninstall.html": [
        "Worker logs",
    ],
    "docs/CHANGELOG.md": [
        "Known Gaps",
        "Legacy background compatibility scripts",
        "Built-in Compose still uses existing hotkey files internally",
        "Clipboard History gray-circles visual issue",
    ],
    "docs/changelog.html": [
        "Known Gaps",
        "Legacy background compatibility scripts",
        "Built-in Compose still uses existing hotkey files internally",
        "Clipboard History gray-circles visual issue",
    ],
}

MD_LINK = re.compile(r"(?<!!)\[[^\]]+\]\(([^)]+)\)")
HTML_HREF = re.compile(r"""href=["']([^"']+)["']""")
HTML_SRC = re.compile(r"""src=["']([^"']+)["']""")
HTML_ANCHOR = re.compile(r"""(?:id|name)=["']([^"']+)["']""")
MD_HEADING = re.compile(r"^(#{1,6})\s+(.+?)\s*$", re.MULTILINE)
MD_LINK_TEXT = re.compile(r"\[([^\]]+)\]\([^)]+\)")
HTML_TITLE = re.compile(r"<title>[^<]+</title>")
HTML_DESCRIPTION = re.compile(r"""<meta\s+name=["']description["']\s+content=["']([^"']{50,180})["']>""")
HTML_CANONICAL = re.compile(r"""<link\s+rel=["']canonical["']\s+href=["']([^"']+)["']>""")
HTML_TITLE_VALUE = re.compile(r"<title>([^<]+)</title>")
HTML_OG_TITLE = re.compile(r"""<meta\s+property=["']og:title["']\s+content=["']([^"']+)["']>""")
HTML_OG_DESCRIPTION = re.compile(r"""<meta\s+property=["']og:description["']\s+content=["']([^"']+)["']>""")
HTML_TWITTER_TITLE = re.compile(r"""<meta\s+name=["']twitter:title["']\s+content=["']([^"']+)["']>""")
HTML_TWITTER_DESCRIPTION = re.compile(r"""<meta\s+name=["']twitter:description["']\s+content=["']([^"']+)["']>""")
HTML_MD_LINK = re.compile(r"""<a\s+href=["']([^"']+\.md(?:#[^"']*)?)["'][^>]*>(.*?)</a>""", re.IGNORECASE | re.DOTALL)
GENERIC_RELEASE_URL = re.compile(r"https://github\.com/galbutnotgirl/command/releases(?!/(?:latest|download/))")
RAW_URL = re.compile(r"https?://[^\s)>\\]]+")
SITEMAP_LOC = re.compile(r"<loc>([^<]+)</loc>")
PAGES_BASE_URL = "https://galbutnotgirl.github.io/command/"
OLD_PUBLIC_URLS = [
    "https://galbutnotgirl.github.io/claude-command",
    "https://github.com/galbutnotgirl/claude-command",
]
FORBIDDEN_HTML_METADATA_TERMS = [
    "Add/New/Go behavior",
    "Go behavior",
    "docs page for missing links",
    "Handoff History",
    "Claude Command",
    "Templates",
    "Clipboard daemon",
]
STRUCTURAL_HTML_TAGS = [
    "html",
    "head",
    "body",
    "main",
    "nav",
    "section",
    "table",
    "thead",
    "tbody",
    "tr",
    "th",
    "td",
    "ol",
    "ul",
]
HTML_STACK_TAGS = set(STRUCTURAL_HTML_TAGS)
HTML_TAG_TOKEN = re.compile(r"</?([a-zA-Z][a-zA-Z0-9-]*)(?:\s[^>]*)?>")
CORE_DOC_NAV_LINKS = [
    "index.html",
    "install.html",
    "uninstall.html",
    "guide.html",
    "settings.html",
    "quick-reference.html",
    "examples.html",
    "faq.html",
    "changelog.html",
    "limitations.html",
    "updates.html",
    "permissions.html",
    "privacy.html",
    "troubleshooting.html",
    "support.html",
    "security.html",
    "icon-treatments.html",
    "background.html",
    "release.html",
]
CORE_DOC_NAV_LABELS = {
    "index.html": "Overview",
    "install.html": "Install Guide",
    "uninstall.html": "Uninstall",
    "guide.html": "User Guide",
    "settings.html": "Settings Reference",
    "quick-reference.html": "Quick Reference",
    "examples.html": "Examples",
    "faq.html": "FAQ",
    "changelog.html": "Changelog",
    "limitations.html": "Alpha Limitations",
    "updates.html": "Updates",
    "permissions.html": "Permissions",
    "privacy.html": "Privacy",
    "troubleshooting.html": "Troubleshooting",
    "support.html": "Support",
    "security.html": "Security Policy",
    "icon-treatments.html": "Icon Treatments",
    "background.html": "Background Architecture",
    "release.html": "Release Checklist",
}
CORE_DOC_MARKDOWN_SOURCES = {
    "install.html": "docs/INSTALL.md",
    "uninstall.html": "docs/UNINSTALL.md",
    "guide.html": "docs/USER_GUIDE.md",
    "settings.html": "docs/SETTINGS_REFERENCE.md",
    "quick-reference.html": "docs/QUICK_REFERENCE.md",
    "examples.html": "docs/EXAMPLES.md",
    "faq.html": "docs/FAQ.md",
    "changelog.html": "docs/CHANGELOG.md",
    "limitations.html": "docs/LIMITATIONS.md",
    "updates.html": "docs/UPDATES.md",
    "permissions.html": "docs/PERMISSIONS.md",
    "privacy.html": "docs/PRIVACY.md",
    "troubleshooting.html": "docs/TROUBLESHOOTING.md",
    "support.html": "docs/SUPPORT.md",
    "security.html": "docs/SECURITY.md",
    "icon-treatments.html": "docs/ICON_TREATMENTS.md",
    "background.html": "docs/BACKGROUND_TRIGGER_INTEGRATION.md",
    "release.html": "docs/RELEASE_CHECKLIST.md",
}
ABOUT_HELP_DOCS = [
    "index",
    "guide",
    "install",
    "uninstall",
    "settings",
    "quick-reference",
    "troubleshooting",
    "permissions",
    "support",
    "security",
    "examples",
    "faq",
    "updates",
    "privacy",
    "changelog",
    "limitations",
    "icon-treatments",
    "background",
    "release",
]
ABOUT_HELP_DOC_LABELS = {
    "index": "Documentation",
    "guide": "User Guide",
    "install": "Install Guide",
    "uninstall": "Uninstall",
    "settings": "Settings Reference",
    "quick-reference": "Quick Reference",
    "troubleshooting": "Troubleshooting",
    "permissions": "Permissions",
    "support": "Support",
    "security": "Security Policy",
    "examples": "Examples",
    "faq": "FAQ",
    "updates": "Updates",
    "privacy": "Privacy",
    "changelog": "Changelog",
    "limitations": "Alpha Limitations",
    "icon-treatments": "Icon Treatments",
    "background": "Background Architecture",
    "release": "Release Checklist",
}
ABOUT_SUPPORT_LABELS = [
    "View on GitHub",
    "Copy Diagnostic Info",
    "Report a Bug",
    "Request Feature",
    "Private Security Report",
]
ABOUT_SECTION_LABELS = [
    "Help & Documentation",
    "Support & Reporting",
]
ABOUT_RELEASE_CHECK_LABELS = [
    "Check for Updates",
    "View on GitHub",
    "Copy Diagnostic Info",
    "Report a Bug",
    "Request Feature",
    "Private Security Report",
]


def is_external(target: str) -> bool:
    lower = target.lower()
    return (
        "://" in lower
        or lower.startswith("mailto:")
        or lower.startswith("tel:")
        or lower.startswith("javascript:")
        or lower.startswith("data:")
    )


def normalize(raw: str) -> tuple[str, str | None]:
    target = raw.strip()
    if " " in target and not target.startswith("<"):
        target = target.split()[0]
    target = target.strip("<>")
    path_part, fragment = target, None
    if "#" in target:
        path_part, fragment = target.split("#", 1)
    path_part = path_part.split("?", 1)[0]
    return unquote(path_part), unquote(fragment) if fragment else None


def targets_in(path: Path) -> list[str]:
    text = path.read_text(encoding="utf-8")
    if path.suffix == ".html":
        return HTML_HREF.findall(text) + HTML_SRC.findall(text)
    return MD_LINK.findall(text)


def markdown_slug(text: str) -> str:
    text = MD_LINK_TEXT.sub(r"\1", text)
    text = re.sub(r"`([^`]*)`", r"\1", text)
    text = re.sub(r"<[^>]+>", "", text)
    text = re.sub(r"[*_~]", "", text)
    text = re.sub(r"\s+#+$", "", text.strip())
    text = text.lower()
    text = re.sub(r"[^\w\s-]", "", text)
    text = re.sub(r"\s+", "-", text.strip())
    return re.sub(r"-+", "-", text)


def anchors_in(path: Path) -> set[str]:
    if path.suffix not in {".html", ".md"} or not path.exists():
        return set()
    text = path.read_text(encoding="utf-8")
    if path.suffix == ".html":
        return {unquote(anchor) for anchor in HTML_ANCHOR.findall(text)}

    anchors: set[str] = set()
    counts: dict[str, int] = {}
    for match in MD_HEADING.finditer(text):
        base = markdown_slug(match.group(2))
        if not base:
            continue
        count = counts.get(base, 0)
        counts[base] = count + 1
        anchors.add(base if count == 0 else f"{base}-{count}")
    return anchors


def validate_html_nesting(path: Path, text: str, failures: list[str]) -> None:
    rel = path.relative_to(ROOT)
    stack: list[str] = []
    for match in HTML_TAG_TOKEN.finditer(text):
        raw = match.group(0)
        tag = match.group(1).lower()
        if tag not in HTML_STACK_TAGS:
            continue
        if raw.startswith("</"):
            if not stack:
                failures.append(f"{rel}: misnested </{tag}> with no open tag")
                continue
            expected = stack.pop()
            if expected != tag:
                failures.append(f"{rel}: misnested </{tag}>; expected </{expected}>")
                continue
        elif not raw.endswith("/>"):
            stack.append(tag)
    for tag in reversed(stack):
        failures.append(f"{rel}: unclosed <{tag}>")


def validate_html_structure(path: Path, text: str, failures: list[str]) -> None:
    rel = path.relative_to(ROOT)
    expected_canonical = PAGES_BASE_URL if path.name == "index.html" else f"{PAGES_BASE_URL}{path.name}"
    if not text.lstrip().startswith("<!doctype html>"):
        failures.append(f"{rel}: missing <!doctype html>")
    if '<link rel="stylesheet" href="site.css">' not in text:
        failures.append(f"{rel}: missing shared site.css stylesheet")
    for tag in STRUCTURAL_HTML_TAGS:
        opens = len(re.findall(rf"<{tag}(?:\s|>)", text, flags=re.IGNORECASE))
        closes = len(re.findall(rf"</{tag}>", text, flags=re.IGNORECASE))
        if opens != closes:
            failures.append(f"{rel}: unbalanced <{tag}> tags ({opens} open, {closes} close)")
    validate_html_nesting(path, text, failures)
    titles = HTML_TITLE_VALUE.findall(text)
    if len(titles) != 1:
        failures.append(f"{rel}: missing non-empty <title>")
    h1_count = len(re.findall(r"<h1(?:\s|>)", text, flags=re.IGNORECASE))
    if h1_count != 1:
        failures.append(f"{rel}: must contain exactly one <h1> ({h1_count} found)")
    for level, body in re.findall(r"<h([1-6])[^>]*>(.*?)</h\1>", text, flags=re.IGNORECASE | re.DOTALL):
        heading_text = re.sub(r"<[^>]+>", "", body).strip()
        if not heading_text:
            failures.append(f"{rel}: empty <h{level}> heading")
    descriptions = HTML_DESCRIPTION.findall(text)
    if len(descriptions) != 1:
        failures.append(f"{rel}: missing one 50-180 character meta description")
    elif not descriptions[0].startswith("Command"):
        failures.append(f"{rel}: meta description should start with Command")
    canonicals = HTML_CANONICAL.findall(text)
    if canonicals != [expected_canonical]:
        failures.append(f"{rel}: canonical should be {expected_canonical}")
    if len(titles) == 1:
        if HTML_OG_TITLE.findall(text) != titles:
            failures.append(f"{rel}: og:title should match title")
        if HTML_TWITTER_TITLE.findall(text) != titles:
            failures.append(f"{rel}: twitter:title should match title")
        if path.name in CORE_DOC_NAV_LABELS and path.name != "index.html":
            expected_title = f"Command {CORE_DOC_NAV_LABELS[path.name]}"
            if titles[0] != expected_title:
                failures.append(f"{rel}: title should match shared docs label {expected_title}")
    if path.name in CORE_DOC_NAV_LABELS and path.name != "index.html":
        h1_values = [
            re.sub(r"<[^>]+>", "", body).strip()
            for body in re.findall(r"<h1[^>]*>(.*?)</h1>", text, flags=re.IGNORECASE | re.DOTALL)
        ]
        expected_h1 = CORE_DOC_NAV_LABELS[path.name]
        if h1_values != [expected_h1]:
            failures.append(f"{rel}: h1 should match shared docs label {expected_h1}")
    if len(descriptions) == 1:
        if HTML_OG_DESCRIPTION.findall(text) != descriptions:
            failures.append(f"{rel}: og:description should match meta description")
        if HTML_TWITTER_DESCRIPTION.findall(text) != descriptions:
            failures.append(f"{rel}: twitter:description should match meta description")
    for tag in [
        '<meta property="og:site_name" content="Command">',
        '<meta property="og:type" content="website">',
        '<meta name="twitter:card" content="summary">',
    ]:
        if text.count(tag) != 1:
            failures.append(f"{rel}: missing one social metadata tag: {tag}")
    metadata_values = titles + descriptions + HTML_OG_DESCRIPTION.findall(text) + HTML_TWITTER_DESCRIPTION.findall(text)
    for term in FORBIDDEN_HTML_METADATA_TERMS:
        if any(term in value for value in metadata_values):
            failures.append(f"{rel}: stale metadata term present: {term}")
    if text.count('href="#content">Skip to content</a>') != 1:
        failures.append(f"{rel}: missing one skip-to-content link")
    if text.count('id="content"') != 1:
        failures.append(f"{rel}: missing one #content landmark")
    ids = re.findall(r'id="([^"]+)"', text)
    duplicate_ids = sorted({id_value for id_value in ids if ids.count(id_value) > 1})
    for id_value in duplicate_ids:
        failures.append(f"{rel}: duplicate id #{id_value}")
    anchors = HTML_ANCHOR.findall(text)
    duplicate_anchors = sorted({anchor for anchor in anchors if anchors.count(anchor) > 1})
    for anchor in duplicate_anchors:
        failures.append(f"{rel}: duplicate anchor #{anchor}")
    for hash_target in re.findall(r'href="#([^"]+)"', text):
        if hash_target not in ids:
            failures.append(f"{rel}: hash link missing local target #{hash_target}")
    for img_tag in re.findall(r"<img\b[^>]*>", text, flags=re.IGNORECASE):
        alt = re.search(r'alt="([^"]*)"', img_tag, flags=re.IGNORECASE)
        if not alt or not alt.group(1).strip():
            failures.append(f"{rel}: image missing non-empty alt text: {img_tag}")
    if path.name not in {"index.html", "404.html"}:
        if '<div class="doc-wrap">' not in text:
            failures.append(f"{rel}: docs page should use shared doc-wrap layout")
        if '<nav class="toc"' not in text:
            failures.append(f"{rel}: docs page should use shared toc nav")
    if 'class="doc-toc"' in text or 'class="doc-layout"' in text or 'Documentation navigation' in text:
        failures.append(f"{rel}: legacy docs navigation class/label should not be used")
    if '<nav class="toc"' in text:
        if 'aria-label="Documentation sections"' not in text:
            failures.append(f"{rel}: toc nav missing aria-label")
        if 'class="toc-title"' not in text:
            failures.append(f"{rel}: toc nav missing toc-title")
        elif path.name in CORE_DOC_NAV_LABELS:
            toc_title = re.findall(r'<div class="toc-title">([^<]+)</div>', text)
            if toc_title != [CORE_DOC_NAV_LABELS[path.name]]:
                failures.append(f"{rel}: toc-title should match shared docs label {CORE_DOC_NAV_LABELS[path.name]}")
        nav = text.split('<nav class="toc"', 1)[1].split("</nav>", 1)[0]
        nav_links = re.findall(r'<a href="([^"]+)">(.*?)</a>', nav, flags=re.IGNORECASE | re.DOTALL)
        nav_hrefs = [href for href, _ in nav_links]
        nav_docs = [href for href in nav_hrefs if href in CORE_DOC_NAV_LINKS]
        if nav_docs != CORE_DOC_NAV_LINKS:
            failures.append(f"{rel}: toc docs links should match shared order")
        nav_doc_labels = {
            href: re.sub(r"<[^>]+>", "", label).strip()
            for href, label in nav_links
            if href in CORE_DOC_NAV_LINKS
        }
        for target, expected_label in CORE_DOC_NAV_LABELS.items():
            if nav_doc_labels.get(target) != expected_label:
                failures.append(f"{rel}: toc label for {target} should be {expected_label}")
        for target in CORE_DOC_NAV_LINKS:
            if f'href="{target}"' not in text:
                failures.append(f"{rel}: toc nav should link to {target}")
        section_headings = re.findall(
            r'<section(?:\s+id="([^"]+)")?[^>]*>\s*<h2>(.*?)</h2>',
            text,
            flags=re.IGNORECASE | re.DOTALL,
        )
        nav_hashes = set(re.findall(r'href="#([^"]+)"', nav))
        for section_id, heading_html in section_headings:
            heading_text = re.sub(r"<[^>]+>", "", heading_html).strip()
            if not section_id:
                failures.append(f"{rel}: h2 section missing id: {heading_text}")
            elif section_id not in nav_hashes:
                failures.append(f"{rel}: toc nav missing section link #{section_id} ({heading_text})")
    for href, label in HTML_MD_LINK.findall(text):
        clean_label = re.sub(r"<[^>]+>", "", label).strip()
        if href.startswith("https://github.com/galbutnotgirl/command/issues/new?template="):
            continue
        if href in {
            "https://github.com/galbutnotgirl/command/blob/main/SUPPORT.md",
            "https://github.com/galbutnotgirl/command/blob/main/CONTRIBUTING.md",
        }:
            continue
        if clean_label != "Markdown source":
            failures.append(f"{rel}: Markdown link outside source nav should point to rendered HTML: {clean_label}")


def plain_topic(text: str) -> str:
    text = text.replace("`", "")
    text = re.sub(r"<[^>]+>", "", text)
    return text.replace("&gt;", ">").replace("&lt;", "<").replace("&amp;", "&")


def markdown_headings(text: str) -> list[str]:
    headings: list[str] = []
    for match in MD_HEADING.finditer(text):
        # H1 usually becomes the page hero; parity here guards shareable body sections.
        if len(match.group(1)) < 2:
            continue
        heading = plain_topic(match.group(2))
        heading = re.sub(r"\s+#+$", "", heading.strip())
        if heading:
            headings.append(heading)
    return headings


def validate_doc_parity(failures: list[str]) -> None:
    for (md_rel, html_rel), topics in HTML_MARKDOWN_PARITY.items():
        md_path = ROOT / md_rel
        html_path = ROOT / html_rel
        if not md_path.exists() or not html_path.exists():
            failures.append(f"{md_rel} -> {html_rel}: paired doc missing")
            continue
        md_name = md_path.name
        raw_html = html_path.read_text(encoding="utf-8")
        if f'href="{md_name}">Markdown source</a>' not in raw_html:
            failures.append(f"{html_rel}: missing Markdown source link to {md_name}")
        md_text = plain_topic(md_path.read_text(encoding="utf-8"))
        html_text = plain_topic(raw_html)
        for topic in topics:
            if topic not in md_text:
                failures.append(f"{md_rel}: parity topic missing from Markdown source: {topic}")
            if topic not in html_text:
                failures.append(f"{html_rel}: parity topic missing from rendered HTML: {topic}")


def validate_markdown_h1_label_parity(failures: list[str]) -> None:
    for html, md_rel in CORE_DOC_MARKDOWN_SOURCES.items():
        md_path = ROOT / md_rel
        if not md_path.exists():
            failures.append(f"{md_rel}: paired Markdown source missing")
            continue
        text = md_path.read_text(encoding="utf-8")
        h1s = [
            re.sub(r"\s+#+$", "", plain_topic(match.group(2)).strip())
            for match in MD_HEADING.finditer(text)
            if len(match.group(1)) == 1
        ]
        expected = f"Command {CORE_DOC_NAV_LABELS[html]}"
        if h1s != [expected]:
            failures.append(f"{md_rel}: Markdown H1 should match shared docs label {expected}")


def validate_heading_parity(failures: list[str]) -> None:
    for (md_rel, html_rel) in HTML_MARKDOWN_PARITY.keys():
        md_path = ROOT / md_rel
        html_path = ROOT / html_rel
        if not md_path.exists() or not html_path.exists():
            continue
        html_text = plain_topic(html_path.read_text(encoding="utf-8"))
        for heading in markdown_headings(md_path.read_text(encoding="utf-8")):
            if heading not in html_text:
                failures.append(f"{html_rel}: Markdown heading missing from rendered HTML: {heading}")


def validate_sitemap(failures: list[str]) -> None:
    sitemap = ROOT / "docs/sitemap.xml"
    if not sitemap.exists():
        failures.append("docs/sitemap.xml: missing")
        return
    urls = set(SITEMAP_LOC.findall(sitemap.read_text(encoding="utf-8")))
    expected = {PAGES_BASE_URL}
    for html in (ROOT / "docs").glob("*.html"):
        if html.name in {"404.html", "index.html"}:
            continue
        expected.add(f"{PAGES_BASE_URL}{html.name}")
    missing = sorted(expected - urls)
    extra = sorted(urls - expected)
    for url in missing:
        failures.append(f"docs/sitemap.xml: missing URL {url}")
    for url in extra:
        failures.append(f"docs/sitemap.xml: unexpected URL {url}")


def validate_release_checklist_coverage(failures: list[str]) -> None:
    release_md = (ROOT / "docs/RELEASE_CHECKLIST.md").read_text(encoding="utf-8")
    release_html = (ROOT / "docs/release.html").read_text(encoding="utf-8")
    for html in sorted((ROOT / "docs").glob("*.html")):
        if html.name in {"index.html", "404.html"}:
            continue
        if html.name not in release_md:
            failures.append(f"docs/RELEASE_CHECKLIST.md: release checklist missing docs page: {html.name}")
        if html.name not in release_html:
            failures.append(f"docs/release.html: release checklist missing docs page: {html.name}")


def validate_release_checklist_doc_label_parity(failures: list[str]) -> None:
    labels = list(CORE_DOC_NAV_LABELS.values()) + ["404 fallback"]
    for rel in ["docs/RELEASE_CHECKLIST.md", "docs/release.html"]:
        text = plain_topic((ROOT / rel).read_text(encoding="utf-8"))
        for label in labels:
            if label not in text:
                failures.append(f"{rel}: release checklist missing docs label: {label}")


def validate_docs_home_coverage(failures: list[str]) -> None:
    home = (ROOT / "docs/index.html").read_text(encoding="utf-8")
    for html in sorted((ROOT / "docs").glob("*.html")):
        if html.name == "index.html":
            continue
        if f'href="{html.name}"' not in home:
            failures.append(f"docs/index.html: docs home missing docs page: {html.name}")


def validate_docs_home_card_label_parity(failures: list[str]) -> None:
    home = (ROOT / "docs/index.html").read_text(encoding="utf-8")
    for href, label in CORE_DOC_NAV_LABELS.items():
        if href == "index.html":
            continue
        pattern = rf'<a[^>]*href="{re.escape(href)}"[^>]*>\s*(?:<strong>)?{re.escape(label)}'
        if not re.search(pattern, home):
            failures.append(f"docs/index.html: docs home card label missing or mismatched: {href} -> {label}")


def validate_rendered_docs_grid_label_parity(failures: list[str]) -> None:
    section_ids = ["docs", "full-docs", "more-detail"]
    card_pattern = re.compile(r'<a class="card" href="([^"]+)">\s*<strong>(.*?)</strong>', re.DOTALL)
    for html in sorted((ROOT / "docs").glob("*.html")):
        text = html.read_text(encoding="utf-8")
        for section_id in section_ids:
            match = re.search(rf'<section id="{section_id}"[^>]*>(.*?)</section>', text, flags=re.DOTALL)
            if not match:
                continue
            section = match.group(1)
            for href, actual in card_pattern.findall(section):
                label = CORE_DOC_NAV_LABELS.get(href)
                if label is None:
                    continue
                actual = re.sub(r"<[^>]+>", "", actual).strip()
                if actual != label:
                    failures.append(f"{html.relative_to(ROOT)}: rendered docs grid label missing or mismatched: {href} -> {label}")


def validate_docs_home_repo_trust_routes(failures: list[str]) -> None:
    home = (ROOT / "docs/index.html").read_text(encoding="utf-8")
    required_routes = {
        "README": "https://github.com/galbutnotgirl/command#readme",
        "Contributing": "https://github.com/galbutnotgirl/command/blob/main/CONTRIBUTING.md",
        "Private Security Report": "https://github.com/galbutnotgirl/command/security/advisories/new",
    }
    for label, href in required_routes.items():
        if label not in home or f'href="{href}"' not in home:
            failures.append(f"docs/index.html: docs home missing repo trust route: {label}")


def validate_about_docs_button_coverage(failures: list[str]) -> None:
    settings = (ROOT / "agent/SettingsWindow.swift").read_text(encoding="utf-8")
    found = set(re.findall(r'openHelpDoc\(named:\s*"([^"]+)"', settings))
    missing = [name for name in ABOUT_HELP_DOCS if name not in found]
    extra = sorted(found - set(ABOUT_HELP_DOCS))
    for name in missing:
        failures.append(f"agent/SettingsWindow.swift: About docs buttons missing openHelpDoc(named: \"{name}\")")
    for name in extra:
        if name == "install":
            continue
        failures.append(f"agent/SettingsWindow.swift: unexpected About docs target: {name}")
    button_blocks = re.findall(
        r'Button\s*\{\s*openHelpDoc\(named:\s*"([^"]+)"\)\s*\}\s*label:\s*\{\s*Label\("([^"]+)"',
        settings,
        flags=re.DOTALL,
    )
    labels_by_target = {target: label for target, label in button_blocks}
    for target, expected_label in ABOUT_HELP_DOC_LABELS.items():
        actual_label = labels_by_target.get(target)
        if actual_label != expected_label:
            failures.append(
                f'agent/SettingsWindow.swift: About docs button {target} label {actual_label!r}, expected {expected_label!r}'
            )


def validate_about_docs_reference_parity(failures: list[str]) -> None:
    labels = list(ABOUT_HELP_DOC_LABELS.values())
    for rel in [
        "docs/SETTINGS_REFERENCE.md",
        "docs/settings.html",
        "docs/QUICK_REFERENCE.md",
        "docs/quick-reference.html",
    ]:
        text = (ROOT / rel).read_text(encoding="utf-8")
        for label in labels:
            if label not in text:
                failures.append(f"{rel}: About docs label missing from Help & Documentation reference: {label}")


def validate_release_checklist_about_docs_label_parity(failures: list[str]) -> None:
    labels = list(ABOUT_HELP_DOC_LABELS.values())
    for rel in ["docs/RELEASE_CHECKLIST.md", "docs/release.html"]:
        text = (ROOT / rel).read_text(encoding="utf-8")
        for label in labels:
            if label not in text:
                failures.append(f"{rel}: release checklist About docs-button label missing: {label}")


def validate_about_surface_label_parity(failures: list[str]) -> None:
    settings = (ROOT / "agent/SettingsWindow.swift").read_text(encoding="utf-8")
    for label in ABOUT_SUPPORT_LABELS + ABOUT_SECTION_LABELS + ["Check for Updates", "Import / Export"]:
        if label not in settings:
            failures.append(f"agent/SettingsWindow.swift: About surface label missing: {label}")

    for rel in [
        "docs/SETTINGS_REFERENCE.md",
        "docs/settings.html",
        "docs/QUICK_REFERENCE.md",
        "docs/quick-reference.html",
        "docs/INSTALL.md",
        "docs/install.html",
    ]:
        text = plain_topic((ROOT / rel).read_text(encoding="utf-8"))
        for label in ABOUT_SUPPORT_LABELS + ABOUT_SECTION_LABELS:
            if label not in text:
                failures.append(f"{rel}: About surface label missing: {label}")

    for rel in ["docs/RELEASE_CHECKLIST.md", "docs/release.html"]:
        text = plain_topic((ROOT / rel).read_text(encoding="utf-8"))
        for label in ABOUT_RELEASE_CHECK_LABELS:
            if label not in text:
                failures.append(f"{rel}: About surface label missing: {label}")


def validate_settings_sidebar_reference_parity(failures: list[str]) -> None:
    settings_swift = (ROOT / "agent/SettingsWindow.swift").read_text(encoding="utf-8")
    labels = re.findall(r'tabButton\([^,]+,\s*"([^"]+)"\s*,', settings_swift)
    if not labels:
        failures.append("agent/SettingsWindow.swift: no Settings sidebar tabButton labels found")
        return
    for rel in ["docs/SETTINGS_REFERENCE.md", "docs/settings.html"]:
        text = (ROOT / rel).read_text(encoding="utf-8")
        for label in labels:
            if label not in text:
                failures.append(f"{rel}: Settings sidebar label missing from Settings Reference: {label}")


def validate_svg_assets(failures: list[str]) -> None:
    for path in sorted((ROOT / "docs").glob("*.svg")):
        rel = path.relative_to(ROOT)
        try:
            root = ET.parse(path).getroot()
        except ET.ParseError as exc:
            failures.append(f"{rel}: invalid SVG XML: {exc}")
            continue
        if not root.tag.endswith("svg"):
            failures.append(f"{rel}: root element is not svg")


def validate_css_asset(failures: list[str]) -> None:
    css_path = ROOT / "docs/site.css"
    if not css_path.exists():
        failures.append("docs/site.css: missing")
        return
    text = css_path.read_text(encoding="utf-8")
    if text.count("{") != text.count("}"):
        failures.append("docs/site.css: unbalanced CSS braces")
    if "letter-spacing: -" in text:
        failures.append("docs/site.css: negative letter spacing hurts readability")
    required_selectors = [
        ":root",
        "@media (prefers-color-scheme: dark)",
        ".skip-link",
        ".doc-wrap",
        ".toc",
        "max-height: calc(100vh - 36px)",
        "scrollbar-gutter: stable",
        ".media-frame",
        "@media (max-width: 820px)",
    ]
    for selector in required_selectors:
        if selector not in text:
            failures.append(f"docs/site.css: required CSS selector/rule missing: {selector}")
    for html in sorted((ROOT / "docs").glob("*.html")):
        html_text = html.read_text(encoding="utf-8")
        if '<link rel="stylesheet" href="site.css">' not in html_text:
            failures.append(f"{html.relative_to(ROOT)}: missing shared site.css stylesheet")


def validate_markdown_source_links(failures: list[str]) -> None:
    allowed_html_link_sources = {
        ROOT / "docs/RELEASE_CHECKLIST.md",
    }
    for md in sorted((ROOT / "docs").glob("*.md")):
        if md in allowed_html_link_sources:
            continue
        rel = md.relative_to(ROOT)
        for raw in MD_LINK.findall(md.read_text(encoding="utf-8")):
            if is_external(raw):
                continue
            target, _ = normalize(raw)
            if target.endswith(".html"):
                failures.append(f"{rel}: Markdown source doc should link to Markdown source, not rendered HTML: {raw}")


def validate_release_download_links(failures: list[str]) -> None:
    for path in [ROOT / "README.md", *sorted((ROOT / "docs").glob("*.md")), *sorted((ROOT / "docs").glob("*.html"))]:
        rel = path.relative_to(ROOT)
        text = path.read_text(encoding="utf-8")
        for match in GENERIC_RELEASE_URL.finditer(text):
            failures.append(f"{rel}: generic GitHub Releases URL should use /releases/latest: {match.group(0)}")


def validate_public_url_rename(failures: list[str]) -> None:
    checked_paths = [
        ROOT / "README.md",
        ROOT / "CONTRIBUTING.md",
        ROOT / "SUPPORT.md",
        ROOT / "SECURITY.md",
        *sorted((ROOT / ".github").glob("**/*.md")),
        *sorted((ROOT / ".github").glob("**/*.yml")),
        *sorted((ROOT / "docs").glob("*.md")),
        *sorted((ROOT / "docs").glob("*.html")),
        ROOT / "docs/robots.txt",
        ROOT / "docs/sitemap.xml",
    ]
    for path in checked_paths:
        if not path.exists():
            continue
        rel = path.relative_to(ROOT)
        text = path.read_text(encoding="utf-8")
        for old_url in OLD_PUBLIC_URLS:
            if old_url in text:
                failures.append(f"{rel}: old public URL should use Command repo/pages path: {old_url}")


def strip_markdown_code_blocks(text: str) -> str:
    out: list[str] = []
    in_code = False
    for line in text.splitlines():
        if line.strip().startswith("```"):
            in_code = not in_code
            out.append("")
            continue
        out.append("" if in_code else line)
    return "\n".join(out)


def validate_markdown_raw_urls(failures: list[str]) -> None:
    for path in [*TRUST_MARKDOWN_FILES, *sorted((ROOT / "docs").glob("*.md"))]:
        rel = path.relative_to(ROOT)
        text = strip_markdown_code_blocks(path.read_text(encoding="utf-8"))
        text = re.sub(r"!?\[[^\]]+\]\([^)]+\)", "", text)
        for match in RAW_URL.finditer(text):
            failures.append(f"{rel}: raw URL should be markdown link: {match.group(0)}")


def validate_release_script_doc_assets(failures: list[str]) -> None:
    release_script = (ROOT / "release.sh").read_text(encoding="utf-8")
    match = re.search(r"for required_doc in (.*?); do", release_script, flags=re.DOTALL)
    if not match:
        failures.append("release.sh: missing required_doc docs asset loop")
        return
    listed = match.group(1).split()
    expected = REQUIRED_DOC_ASSETS
    if set(listed) != set(expected):
        missing = sorted(set(expected) - set(listed))
        extra = sorted(set(listed) - set(expected))
        failures.append(f"release.sh required_doc list mismatch: missing={missing} extra={extra}")


def validate_release_asset_script_doc_assets(failures: list[str]) -> None:
    release_asset_script = (ROOT / "test/test-release-asset.sh").read_text(encoding="utf-8")
    match = re.search(r"for required_doc in (.*?); do", release_asset_script, flags=re.DOTALL)
    if not match:
        failures.append("test/test-release-asset.sh: missing required_doc docs asset loop")
        return
    listed = match.group(1).split()
    expected = REQUIRED_DOC_ASSETS
    if set(listed) != set(expected):
        missing = sorted(set(expected) - set(listed))
        extra = sorted(set(listed) - set(expected))
        failures.append(f"test/test-release-asset.sh required_doc list mismatch: missing={missing} extra={extra}")


def validate_build_agent_doc_assets(failures: list[str]) -> None:
    build_agent = (ROOT / "build-agent.sh").read_text(encoding="utf-8")
    match = re.search(r"for doc_asset in (.*?); do", build_agent, flags=re.DOTALL)
    if not match:
        failures.append("build-agent.sh: missing doc_asset docs asset loop")
        return
    listed = match.group(1).split()
    expected = REQUIRED_DOC_ASSETS
    if set(listed) != set(expected):
        missing = sorted(set(expected) - set(listed))
        extra = sorted(set(listed) - set(expected))
        failures.append(f"build-agent.sh doc_asset list mismatch: missing={missing} extra={extra}")


def validate_required_doc_assets_cover_docs_dir(failures: list[str]) -> None:
    ignored = {"STATUS.md"}
    shareable_suffixes = {".html", ".md", ".css", ".txt", ".xml", ".svg"}
    actual = {
        path.name
        for path in (ROOT / "docs").iterdir()
        if path.is_file() and path.suffix in shareable_suffixes and path.name not in ignored
    }
    expected = set(REQUIRED_DOC_ASSETS)
    missing = sorted(actual - expected)
    stale = sorted(expected - actual)
    if missing:
        failures.append(f"REQUIRED_DOC_ASSETS missing shareable docs files: {missing}")
    if stale:
        failures.append(f"REQUIRED_DOC_ASSETS lists missing docs files: {stale}")


def validate_readme_docs_table_coverage(failures: list[str]) -> None:
    readme = (ROOT / "README.md").read_text(encoding="utf-8")
    expected = [
        path.relative_to(ROOT).as_posix()
        for path in sorted((ROOT / "docs").glob("*.md"))
        if path.name not in {"STATUS.md", "SUPPORT.md", "SECURITY.md"}
    ]
    expected += ["SUPPORT.md", "SECURITY.md", "CONTRIBUTING.md"]
    for rel in expected:
        if f"]({rel})" not in readme:
            failures.append(f"README.md docs table missing public Markdown doc: {rel}")


def validate_readme_docs_table_label_parity(failures: list[str]) -> None:
    readme = (ROOT / "README.md").read_text(encoding="utf-8")
    for html, rel in CORE_DOC_MARKDOWN_SOURCES.items():
        if html in {"support.html", "security.html"}:
            continue
        label = CORE_DOC_NAV_LABELS[html]
        row = f"| {label} | [{rel}]({rel}) |"
        if row not in readme:
            failures.append(f"README.md docs table label missing or mismatched: {label} -> {rel}")
    for label, rel in {"Support, bugs, and feature requests": "SUPPORT.md", "Security reports": "SECURITY.md"}.items():
        row = f"| {label} | [{rel}]({rel}) |"
        if row not in readme:
            failures.append(f"README.md docs table label missing or mismatched: {label} -> {rel}")


def validate_no_duplicate_validator_keys(failures: list[str]) -> None:
    source = Path(__file__).read_text(encoding="utf-8")
    tree = ast.parse(source)
    checked = {"REQUIRED_TEXT", "FORBIDDEN_TEXT", "HTML_MARKDOWN_PARITY"}
    for node in ast.walk(tree):
        if not isinstance(node, ast.Assign):
            continue
        names = {target.id for target in node.targets if isinstance(target, ast.Name)}
        matched = checked & names
        if not matched or not isinstance(node.value, ast.Dict):
            continue
        keys = [
            ast.literal_eval(key)
            for key in node.value.keys
            if key is not None and isinstance(key, (ast.Constant, ast.Tuple))
        ]
        for duplicate in sorted({key for key in keys if keys.count(key) > 1}, key=str):
            for name in matched:
                failures.append(f"test/test-docs.py: duplicate key in {name}: {duplicate}")


def swift_default_shortcuts() -> list[tuple[str, str]]:
    actions_text = (ROOT / "agent/Sources/ClaudeCommandCore/ActionModels.swift").read_text(encoding="utf-8")
    keycodes_text = (ROOT / "agent/Sources/ClaudeCommandCore/KeyCodes.swift").read_text(encoding="utf-8")
    names = {
        action_id: name.replace("→", "->")
        for action_id, name in re.findall(
            r'CommandAction\(id:\s*"([^"]+)",\s*name:\s*"([^"]+)"',
            actions_text,
        )
    }
    key_names = {
        int(code): label
        for code, label in re.findall(r'(\d+):"([^"]+)"', keycodes_text)
    }
    block_match = re.search(r"public let DEFAULT_BINDINGS:.*?=\s*\[(.*?)\n\]", actions_text, re.S)
    if not block_match:
        raise ValueError("DEFAULT_BINDINGS block not found")
    shortcuts: list[tuple[str, str]] = []
    for action_id, keycode_raw, mods_raw in re.findall(r'\("([^"]+)",\s*(\d+),\s*(\d+)\)', block_match.group(1)):
        if action_id not in names:
            raise ValueError(f"DEFAULT_BINDINGS action has no CommandAction: {action_id}")
        keycode = int(keycode_raw)
        mods = int(mods_raw)
        if keycode == 0:
            shortcut = "Unbound"
        else:
            pieces = []
            for mask, label in ((4096, "Control-"), (2048, "Option-"), (512, "Shift-"), (256, "Command-")):
                if mods & mask:
                    pieces.append(label)
            if keycode not in key_names:
                raise ValueError(f"DEFAULT_BINDINGS keycode has no KEYCODE_NAMES entry: {keycode}")
            shortcut = "".join(pieces) + key_names[keycode]
        shortcuts.append((BUILT_IN_DOC_LABELS.get(action_id, names[action_id]), shortcut))
    return shortcuts


def html_to_plain(text: str) -> str:
    text = re.sub(r"<[^>]+>", " ", text)
    return unquote(text).replace("&gt;", ">").replace("&lt;", "<").replace("&amp;", "&")


def validate_default_shortcut_docs(failures: list[str]) -> None:
    try:
        shortcuts = swift_default_shortcuts()
    except ValueError as exc:
        failures.append(f"default shortcut source parse failed: {exc}")
        return
    for rel in DEFAULT_SHORTCUT_DOCS:
        path = ROOT / rel
        if not path.exists():
            failures.append(f"default shortcut doc missing: {rel}")
            continue
        lines = path.read_text(encoding="utf-8").splitlines()
        for action_name, shortcut in shortcuts:
            candidates = [html_to_plain(line) for line in lines if action_name in html_to_plain(line)]
            if not candidates:
                failures.append(f"{rel}: default shortcut row missing action {action_name}")
                continue
            if not any(shortcut in candidate for candidate in candidates):
                failures.append(f"{rel}: default shortcut for {action_name} should be {shortcut}")


def swift_built_in_compose_rows() -> list[tuple[str, str, str, str]]:
    built_in_text = (ROOT / "agent/BuiltInComposeSettings.swift").read_text(encoding="utf-8")
    actions_text = (ROOT / "agent/Sources/ClaudeCommandCore/ActionModels.swift").read_text(encoding="utf-8")
    action_names = {
        action_id: name.replace("→", "->")
        for action_id, name in re.findall(
            r'CommandAction\(id:\s*"([^"]+)",\s*name:\s*"([^"]+)"',
            actions_text,
        )
    }
    default_match = re.search(r"autoSubmitDefault:\s*(true|false)", built_in_text)
    if not default_match:
        raise ValueError("autoSubmitDefault not found")
    default_submit = default_match.group(1) == "true"
    overrides_match = re.search(r"let DEFAULT_BUILTIN_COMPOSE_SETTINGS[\s\S]*?autoSubmitOverrides:\s*\[(.*?)\]\s*\)", built_in_text)
    overrides: dict[str, bool] = {}
    if overrides_match:
        for action, value in re.findall(r'"([^"]+)":\s*(true|false)', overrides_match.group(1)):
            overrides[action] = value == "true"
    rows: list[tuple[str, str, str, str]] = []
    for action, input_label, behavior_label in re.findall(
        r'BuiltInComposeRowDefinition\(action:\s*"([^"]+)",\s*inputLabel:\s*"([^"]+)",\s*behaviorLabel:\s*"([^"]+)"',
        built_in_text,
    ):
        if action not in action_names:
            raise ValueError(f"BUILTIN_COMPOSE_ROWS action has no CommandAction: {action}")
        auto_submit = overrides.get(action, default_submit)
        delivery = "Existing chat" if action in {"add", "shotadd"} else "New chat"
        rows.append((BUILT_IN_DOC_LABELS.get(action, action_names[action]), input_label, delivery, "Yes" if auto_submit else "No"))
    if not rows:
        raise ValueError("BUILTIN_COMPOSE_ROWS not found")
    return rows


def validate_built_in_compose_docs(failures: list[str]) -> None:
    try:
        rows = swift_built_in_compose_rows()
    except ValueError as exc:
        failures.append(f"built-in compose source parse failed: {exc}")
        return
    for rel in BUILT_IN_COMPOSE_DOCS:
        path = ROOT / rel
        if not path.exists():
            failures.append(f"built-in compose doc missing: {rel}")
            continue
        lines = path.read_text(encoding="utf-8").splitlines()
        for combination, input_label, delivery, auto_submit in rows:
            candidates = [
                html_to_plain(line)
                for line in lines
                if combination in html_to_plain(line)
                and input_label in html_to_plain(line)
            ]
            if not candidates:
                failures.append(f"{rel}: built-in compose row missing {combination} / {input_label}")
                continue
            if not any(delivery in candidate and auto_submit in candidate for candidate in candidates):
                failures.append(f"{rel}: built-in compose row for {combination} / {input_label} should show delivery={delivery}, auto-submit={auto_submit}")


def swift_command_template(action: str) -> str:
    text = (ROOT / "agent/Sources/ClaudeCommandCore/Templates.swift").read_text(encoding="utf-8")
    match = re.search(
        rf'CommandTemplate\(action:\s*"{re.escape(action)}",\s*template:\s*"((?:[^"\\]|\\.)*)"',
        text,
        re.S,
    )
    if not match:
        raise ValueError(f"Swift default template missing: {action}")
    return ast.literal_eval(f'"{match.group(1)}"')


def validate_shell_template_fallbacks(failures: list[str]) -> None:
    shell = (ROOT / "send-to-claude.sh").read_text(encoding="utf-8")
    try:
        go_template = swift_command_template("go")
    except ValueError as exc:
        failures.append(f"Swift template parse failed: {exc}")
        return
    for fragment in ("{selection}", 'Right-click "Go": {context} Then do what', "most useful and report.)"):
        if fragment not in go_template:
            failures.append(f"Swift Go default template missing expected fragment: {fragment}")
        if fragment not in shell:
            failures.append("send-to-claude.sh: Go fallback template drifted from Swift default")
    comment_pos = shell.find('COMMENT_RAW="$(read_template comment)"')
    add_pos = shell.find('ADD_RAW="$(read_template add)"')
    if comment_pos < 0 or add_pos < 0:
        failures.append("send-to-claude.sh: missing Add/New read_template fallback wiring")
        return
    window = shell[comment_pos:add_pos + 80]
    if '[ -z "$COMMENT_RAW" ]' in window or '[ -z "$ADD_RAW" ]' in window:
        failures.append("send-to-claude.sh: Add/New fallback should stay empty so expand_template sends selection only")


def validate_custom_action_trigger_add(failures: list[str]) -> None:
    text = (ROOT / "agent/SettingsWindow.swift").read_text(encoding="utf-8")
    match = re.search(r"func addTrigger\(actionID: String, kind: ActionKind\) \{([\s\S]*?)\n    \}", text)
    if not match:
        failures.append("SettingsModel.addTrigger missing")
        return
    append_count = match.group(1).count("triggers.append(ActionTrigger(kind: kind))")
    if append_count != 1:
        failures.append("addTrigger should append exactly one ActionTrigger")


def main() -> int:
    failures: list[str] = []
    docs_dir = ROOT / "docs"

    for path in DOC_FILES:
        if not path.exists():
            failures.append(f"missing doc file: {path.relative_to(ROOT)}")
            continue
        rel = str(path.relative_to(ROOT))
        text = path.read_text(encoding="utf-8")
        if path.suffix == ".html":
            validate_html_structure(path, text, failures)
        if path.suffix == ".md" and path.parent == docs_dir and path.name not in {"SETTINGS_REFERENCE.md", "STATUS.md"}:
            if "SETTINGS_REFERENCE.md" not in text and "Settings Reference" not in text:
                failures.append(f"{rel}: Markdown doc should link to Settings Reference")
        for required in REQUIRED_TEXT.get(rel, []):
            if required not in text:
                failures.append(f"{rel}: required text missing: {required}")
        for forbidden in FORBIDDEN_TEXT.get(rel, []):
            if forbidden in text:
                failures.append(f"{rel}: outdated text present: {forbidden}")
        for raw in targets_in(path):
            if is_external(raw):
                continue
            target, fragment = normalize(raw)
            if target:
                resolved = (path.parent / target).resolve()
            else:
                resolved = path.resolve()
            try:
                resolved.relative_to(ROOT)
            except ValueError:
                failures.append(f"{path.relative_to(ROOT)} -> {raw}: escapes repo")
                continue
            if target and not resolved.exists():
                failures.append(f"{path.relative_to(ROOT)} -> {raw}: missing")
                continue
            if fragment and fragment not in anchors_in(resolved):
                failures.append(f"{path.relative_to(ROOT)} -> {raw}: missing anchor")

    for rel, forbidden_items in FORBIDDEN_TEXT.items():
        path = ROOT / rel
        if path in DOC_FILES:
            continue
        if not path.exists():
            failures.append(f"missing checked file: {rel}")
            continue
        text = path.read_text(encoding="utf-8")
        for forbidden in forbidden_items:
            if forbidden in text:
                failures.append(f"{rel}: outdated text present: {forbidden}")

    for rel, required_items in REQUIRED_TEXT.items():
        path = ROOT / rel
        if path in DOC_FILES:
            continue
        if not path.exists():
            failures.append(f"missing checked file: {rel}")
            continue
        text = path.read_text(encoding="utf-8")
        for required in required_items:
            if required not in text:
                failures.append(f"{rel}: required text missing: {required}")

    for name in REQUIRED_DOC_ASSETS:
        if not (docs_dir / name).exists():
            failures.append(f"required docs asset missing: docs/{name}")

    build_agent = (ROOT / "build-agent.sh").read_text(encoding="utf-8")
    for pattern in REQUIRED_BUNDLE_PATTERNS:
        if pattern not in build_agent:
            failures.append(f"build-agent.sh no longer bundles docs pattern: {pattern}")
    validate_build_agent_doc_assets(failures)

    release_script = (ROOT / "release.sh").read_text(encoding="utf-8")
    for pattern in REQUIRED_RELEASE_PATTERNS:
        if pattern not in release_script:
            failures.append(f"release.sh no longer verifies docs asset pattern: {pattern}")
    validate_release_script_doc_assets(failures)
    validate_release_asset_script_doc_assets(failures)

    if not PAGES_WORKFLOW.exists():
        failures.append("GitHub Pages workflow missing: .github/workflows/pages.yml")
    else:
        pages_workflow = PAGES_WORKFLOW.read_text(encoding="utf-8")
        for pattern in REQUIRED_PAGES_WORKFLOW_PATTERNS:
            if pattern not in pages_workflow:
                failures.append(f"Pages workflow missing pattern: {pattern}")

    if not TEST_WORKFLOW.exists():
        failures.append("GitHub test workflow missing: .github/workflows/test.yml")
    else:
        test_workflow = TEST_WORKFLOW.read_text(encoding="utf-8")
        for pattern in REQUIRED_TEST_WORKFLOW_PATTERNS:
            if pattern not in test_workflow:
                failures.append(f"Test workflow missing pattern: {pattern}")

    validate_doc_parity(failures)
    validate_markdown_h1_label_parity(failures)
    validate_heading_parity(failures)
    validate_sitemap(failures)
    validate_release_checklist_coverage(failures)
    validate_release_checklist_doc_label_parity(failures)
    validate_docs_home_coverage(failures)
    validate_docs_home_card_label_parity(failures)
    validate_rendered_docs_grid_label_parity(failures)
    validate_docs_home_repo_trust_routes(failures)
    validate_about_docs_button_coverage(failures)
    validate_about_docs_reference_parity(failures)
    validate_release_checklist_about_docs_label_parity(failures)
    validate_about_surface_label_parity(failures)
    validate_settings_sidebar_reference_parity(failures)
    validate_svg_assets(failures)
    validate_css_asset(failures)
    validate_markdown_source_links(failures)
    validate_release_download_links(failures)
    validate_public_url_rename(failures)
    validate_markdown_raw_urls(failures)
    validate_required_doc_assets_cover_docs_dir(failures)
    validate_readme_docs_table_coverage(failures)
    validate_readme_docs_table_label_parity(failures)
    validate_default_shortcut_docs(failures)
    validate_built_in_compose_docs(failures)
    validate_shell_template_fallbacks(failures)
    validate_custom_action_trigger_add(failures)
    validate_no_duplicate_validator_keys(failures)

    if failures:
        for failure in failures:
            print(f"FAIL: {failure}")
        return 1

    print(f"docs links: {len(DOC_FILES)} files checked")
    return 0


if __name__ == "__main__":
    sys.exit(main())
