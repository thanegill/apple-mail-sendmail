# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build, test, and dev loop

Tests are wired into the package's `checkPhase`, so a standard build runs them:

```sh
nix build               # builds binary + runs all unit tests
nix flake check         # same, plus evaluates other flake outputs
```

For iterative work, enter the dev shell and use Swift directly:

```sh
nix develop
swift build                                   # builds the default product
swift run sendmail-test                       # runs the test executable
swift build --product apple-mail-sendmail     # build only the main binary
```

There is no single-test selector built in. To focus on one suite during
debugging, comment out the others in `Sources/sendmail-test/main.swift`.

End-to-end smoke test without touching Mail.app:

```sh
SENDMAIL_DRY_RUN=1 ./result/bin/apple-mail-sendmail -t < msg.eml
```

`SENDMAIL_DRY_RUN=1` makes the binary print the generated AppleScript to
stdout instead of executing it. Useful when iterating on `MailDriver`.

## Architecture

Three SwiftPM targets, all under `Sources/`:

- `SendmailCore` (library) — all parsing and AppleScript logic; public API.
- `apple-mail-sendmail` (executable) — thin orchestrator (`main.swift`).
- `sendmail-test` (executable) — custom test runner. **Not** an XCTest target (see constraints below).

The split exists because the test runner needs to `import SendmailCore`. The thin executable just wires stdin and argv into the core pipeline and chooses a `ScriptRunner`.

### Message pipeline

```
stdin bytes -> RFC822Parser -> MIMEParser -> ParsedMessage -> MailDriver -> ScriptRunner
```

- `RFC822Parser.parse(Data)` produces `RawMessage` (ordered headers + raw body bytes; no MIME interpretation).
- `MIMEParser.parse(RawMessage)` interprets `Content-Type`, walks `multipart/*` parts, decodes `base64` / `quoted-printable` transfer encodings, and decodes RFC 2047 encoded-words in `Subject` and display names. Populates `htmlBody` from any `text/html` part alongside the stripped plain-text `body`.
- `MailDriver.deliver(...)` chooses between two AppleScript emitters and hands the result to a `ScriptRunner`. The rich path (`buildRichRTFScript`) renders the source HTML to RTF in Swift (HTML → `NSAttributedString.initWithHTML:` → per-run font substitution via `MailFontPrefs.current()` → RTF data), writes it to a temp `body.rtf`, and emits an AppleScript that does `set content of newMessage to (read POSIX file ... as «class RTF »)`. Around that, the script snapshots/flips Mail's app-level `default message format` to `rich format` (RTF coercion only survives in that mode) and restores it via try/error. Recipients and attachments use the dictionary; `send` is dictionary too. The classic plain-text path runs for messages without HTML, and as the runtime fallback if the rich script throws.

### The ScriptRunner injection seam

`MailDriver.deliver` takes `runner: ScriptRunner? = nil`. Default is `AppleScript.run` (NSAppleScript execution). Tests inject a `Recorder` closure that captures the script source into an array. **Anything new that drives Mail.app should go through this seam** — never call `NSAppleScript` directly from new code, or the tests can't exercise it without actually launching Mail.app.

### Tests skip when HTML rendering isn't available

`MailDriver.renderHTMLToRTF` depends on `NSAttributedString.init(html:...)` (WebKit) and/or pandoc. The Nix build sandbox lacks WebKit and may lack pandoc, so HTML-touching tests must gate on `try requireHTMLRendering()` at the top of the case — otherwise they fail in `nix build`'s `checkPhase`. The harness exposes `skip(_:)` + `TestSkipped`; `runSuites` reports a separate skipped count.

Corollary: **verify HTML-related changes with `nix build .#default`, not just `swift run sendmail-test`**. The dev shell has WebKit; the build sandbox doesn't. Failures only appear in the sandbox.

## Project-specific constraints (read before changing)

### Tests do not use XCTest

The Nix Swift toolchain on macOS does not ship the `xctest` helper binary, so `swift test` fails at the test-bundle link step with `FileSystemError ... path: "/private"`. We sidestep this by building an executable test target with a hand-written assertion harness (`Sources/sendmail-test/TestHarness.swift`). Do not migrate this to XCTest or a `.testTarget` — the build will break under Nix on darwin.

### CLI parser is hand-rolled, not swift-argument-parser

Sendmail compatibility requires bundled short flags (`-ti`, `-oi`, `-bm`, `-OFoo=bar`) and silently swallowing many legacy flags. `swift-argument-parser` does not handle that syntax. Don't add it — the cost is a few cases in `CLI.swift`, the payoff is zero SPM dependencies and a hermetic flake (no `swiftpm2nix`).

### CRLF normalization in the header parser

Swift treats `"\r\n"` as a single `Character` (grapheme cluster). `RFC822Parser.unfold` normalizes `\r\n` to `\n` on the header string before splitting on `\n`. Removing that normalization silently merges adjacent headers into the previous one. There is a regression test (`RFC822Parser.crlf_separator`).

### Package.swift macOS floor is `.v13` deliberately

Nixpkgs Swift 5.10 stdlib dylibs are built for macOS 14.0. Lower floors produce linker warnings that escalate to errors during test-bundle handling. `.v13` is the lowest value that links cleanly.

### Draft is the product invariant

`MailDriver` emits `visible:true` and omits the `send` verb unless `options.send` is true. The default behavior is **draft, not send**. The `--send` flag and `SENDMAIL_SEND=1` environment variable both flip it; the env-var path exists for callers (cron, scripts) that cannot easily change their argv.

### Rich HTML rendering uses an RTF read, not NSSharingService

Mail's compose body is a WKWebView that AppleScript and System Events cannot reliably focus or paste into — `click webArea` calls `AXPress` (not a real mouse event), Tab keystrokes don't descend into the WKWebView, and `set content` to an `NSAttributedString` fails with a `«class ocid»` coercion error. The viable path is Mail's AppleScript `read POSIX file ... as «class RTF »` returning an RTF value that Mail accepts in `set content of msg to ...` — but **only** while `default message format` is `rich format`. The emitter snapshots/flips/restores that preference around the compose via try/error. The README's "Alternatives considered" section enumerates every failed approach with empirical findings — do not re-investigate without reading that first.

Two strict ordering rules in the emitter:

1. `read` must be **outside** any `tell application "Mail"` block, since `read` is a Standard Additions verb and Mail.app doesn't expose it.
2. The script must NOT carry a `use AppleScript version "2.4"` preamble. That preamble makes the parser strict enough to reject the `«class RTF »` four-char-code coercion syntax. `use scripting additions` alone is fine.

The rich-RTF path is selected whenever `msg.htmlBody` is non-empty (no restrictions on attachments or `--send`). If the runtime script throws (HTML parse error, format-restore error, RTF read error), `deliver` falls back to the classic plain-text script. Adding new HTML capability should go through this seam; the classic emitter is intentionally minimal.

### Mail font preferences are read from `com.apple.mail`

`MailDriver.MailFontPrefs.current()` reads `NSFont`, `NSFontSize`, `NSFixedPitchFont`, `NSFixedPitchFontSize` from the `com.apple.mail` UserDefaults, with `MailFontPrefs.appleDefaults` (Helvetica 12 / Menlo-Regular 11) as the fallback. `renderHTMLToRTF(html:fontPrefs:)` takes the prefs as an injectable parameter for deterministic testing — tests construct their own `MailFontPrefs` with real installed font names (`NSFont(name:size:)` returns nil for unknown fonts and the substitution silently keeps the source font in that case). Do not hard-code Helvetica/Menlo anywhere else.

## Packaging

`flake.nix` uses flake-parts. The package factory is wrapped in `pkgs.lib.makeOverridable` and takes `withSendmailSymlink ? true`. Two named packages:

- `packages.default` — installs `apple-mail-sendmail` plus a `sendmail` symlink.
- `packages.without-sendmail-symlink` — canonical binary only.

Consumers from other flakes can also call `self.packages.${system}.default.override { withSendmailSymlink = false; }`.

`meta.mainProgram = "apple-mail-sendmail"`, so `nix run` always invokes the canonical name even though both names are on `PATH` in the `default` package.

Tests run in the package's `checkPhase`, not as a separate `checks.tests` derivation; this means `nix build .#default` is what fails when tests fail.
