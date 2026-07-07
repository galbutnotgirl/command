import XCTest
@testable import ClaudeCommandCore

// Mirrors test/test-shell.sh's expand_template cases one-for-one — the shell
// and Swift implementations must stay behaviorally identical (send-to-claude.sh
// vs Settings ▸ Templates preview). If you change one, change both.
final class TemplatesTests: XCTestCase {
    func testBareTemplateAppendsSelection() {
        let out = expandTemplate("do the thing", selection: "SEL", source: "", url: "", contextLine: "ctx")
        XCTAssertEqual(out, "do the thing\n\nSEL")
    }

    func testEmptyTemplateIsJustSelection() {
        let out = expandTemplate("", selection: "SEL", source: "", url: "", contextLine: "")
        XCTAssertEqual(out, "SEL")
    }

    func testSelectionPlaceholderInline() {
        let out = expandTemplate("before {selection} after", selection: "X", source: "", url: "", contextLine: "")
        XCTAssertEqual(out, "before X after")
    }

    func testPromptAndTextAreSelectionAliases() {
        let out = expandTemplate("{prompt}/{text}", selection: "X", source: "", url: "", contextLine: "")
        XCTAssertEqual(out, "X/X")
    }

    func testContextSubstitution() {
        let out = expandTemplate("go: {context}", selection: "SEL", source: "", url: "", contextLine: "research this")
        XCTAssertEqual(out, "go: research this\n\nSEL")
    }

    func testURLSubstitution() {
        let out = expandTemplate("see {url}", selection: "SEL", source: "", url: "https://example.com", contextLine: "")
        XCTAssertEqual(out, "see https://example.com\n\nSEL")
    }

    func testSourceAutoPrependedWhenOmitted() {
        let out = expandTemplate("{selection}", selection: "SEL", source: "[from: Slack]", url: "", contextLine: "")
        XCTAssertEqual(out, "[from: Slack]\n\nSEL")
    }

    func testSourceExplicitPlacementNotDoublePrepended() {
        let out = expandTemplate("header\n{source}\n{selection}", selection: "SEL", source: "[from: Slack]", url: "", contextLine: "")
        XCTAssertEqual(out, "header\n[from: Slack]\nSEL")
    }

    func testNoSourceNoTokenPrependsNothing() {
        let out = expandTemplate("{selection}", selection: "SEL", source: "", url: "", contextLine: "")
        XCTAssertEqual(out, "SEL")
    }

    // ---- previewSources: Docs/Sheets/Slides pathPrefix disambiguation --------
    // Regression test for the bug this feature fixed: before pathPrefix, all
    // four docs.google.com rules deduped to one picker entry.

    func testPreviewSourcesKeepsDocsSheetsSlidesDistinct() {
        let previews = previewSources(from: DEFAULT_ENRICH_RULES)
        let labels = previews.map(\.label)
        // Every rule shows its friendly displayName in the picker (not the
        // raw host) — Docs/Sheets/Slides via pathPrefix, Gmail/Jira/etc. with
        // no pathPrefix at all. Two rules sharing a displayName ("Google
        // Drive": the docs.google.com fallback and drive.google.com) still
        // both show up, disambiguated by pattern, rather than one silently
        // dropping out of the picker.
        XCTAssertTrue(labels.contains("Google Docs"))
        XCTAssertTrue(labels.contains("Google Sheets"))
        XCTAssertTrue(labels.contains("Google Slides"))
        XCTAssertTrue(labels.contains("Gmail"))
        XCTAssertTrue(labels.contains("Google Drive"))
        XCTAssertTrue(labels.contains("Google Drive (drive.google.com)"))
        // Same collision-disambiguation for the two Salesforce host rules.
        XCTAssertTrue(labels.contains("Salesforce"))
        XCTAssertTrue(labels.contains("Salesforce (salesforce.com)"))
        XCTAssertEqual(Set(labels).count, labels.count)
    }

    func testPreviewSourceSampleURLIncludesPathPrefix() {
        let previews = previewSources(from: DEFAULT_ENRICH_RULES)
        guard let docs = previews.first(where: { $0.label == "Google Docs" }) else {
            return XCTFail("expected a Google Docs preview entry")
        }
        XCTAssertTrue(docs.url.contains("/document/"), "expected /document/ in \(docs.url)")
    }

    func testComposePreviewWithoutSourceContext() {
        let source = PreviewSource(label: "Generic", appName: "Chrome", url: "", enrich: "", displayName: "")
        let out = composePreview(action: "add", template: "{selection}", source: source, selection: "hi", includeContext: false)
        XCTAssertEqual(out, "hi")
    }

    func testComposePreviewWithSourceContext() {
        let source = PreviewSource(label: "Slack", appName: "Slack", url: "", enrich: "Slack enrich hint", displayName: "Slack")
        let out = composePreview(action: "add", template: "{selection}", source: source, selection: "hi", includeContext: true)
        XCTAssertTrue(out.hasPrefix("[from: Slack]"))
        XCTAssertTrue(out.contains("Slack enrich hint"))
        XCTAssertTrue(out.hasSuffix("hi"))
    }
}
