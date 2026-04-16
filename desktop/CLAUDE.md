# Claude Project Context

## Project Overview
**VibeAi** Desktop App for macOS (Swift + Rust) — forked from Omi with major local-first integrations.

## Session Recovery After Compaction

When context compacts, restore state by reading these files in order:

1. **`/Users/dzineer/.claude/projects/-Users-dzineer-Clients-Dzineer-Projects-chrome-extensions-omi-builds-omi/memory/MEMORY.md`** — memory index
2. **`memory/session_summary.md`** (in that dir) — full session summary with architecture, bugs fixed, file paths
3. **`memory/user_preferences.md`** — user's hard preferences (local-first, Gibber, Kokoro not say, graph not lists)
4. **`../snapshots/_save_snapshot.md`** (monorepo root) — latest /save snapshot
5. **`../tasks/TASKS.md`** + `../tasks/*.gibber` — current task list and feature specs

### Current State
- **Branch**: `feat/viba-ai-integrations` on `dzineer/omi` fork
- **PR**: https://github.com/dzineer/omi/pull/1
- **App name**: VibeAi (display name)
- **Sidebar**: Dashboard, Command, Knowledge, Tasks, Settings
- **Removed**: Rewind, Apps, Refer a Friend, Help from Founder, Get Omi widget, Update widget, Sparkle updates

### Already Built — DO NOT rebuild
- Claude Code engine (`Desktop/Sources/Chat/ClaudeCodeBridge.swift`) — toggle via `useClaudeCodeEngine`
- Local STT MLX Whisper (`Desktop/Sources/Voice/LocalSTTService.swift`) — Python server port 8787
- Local TTS Kokoro (`Desktop/Sources/Voice/LocalTTSService.swift`) — Python server port 8788
- Voice loop with mic + speaker buttons (`VoiceConversationManager.swift`)
- SpeechTextFilter strips markdown before TTS
- Eidetic Memory (`Backend-Rust/src/services/memory.rs`) — local graph at `~/.omi/memory/graph.json`
- Knowledge page wired to Eidetic (but needs force-directed graph, see priorities)
- VibeAI logo (`Desktop/Sources/Resources/VibeAI-logo.{svg,png}`)
- Playwright disabled (Swift + ACP bridge JS)
- Gibber executor skill + hooks in `~/.claude/settings.json`

### Top Priorities for Next Session
1. **KNOWLEDGE003** — Force-directed graph (`../tasks/knowledge-graph-v2.gibber`). Current static circles are wrong. Need physics, drag/zoom, double-click drill-down. **Remove flat record list** (user hates it).
2. Kokoro TTS not audible from app (server works via curl, app plays 0 bytes)

### Signing — ad-hoc required
App is ad-hoc signed. `run.sh` tries Developer ID first but that needs notarization (Gatekeeper rejects). Apple Development needs a matching provisioning profile (team `432CJTTJ46` / bundle `com.vibeaiglobal.vibeai-dev` — doesn't exist). **After `run.sh`, run `codesign --force --deep --sign - "/Applications/Vibe AI Dev.app"` to override with ad-hoc** or app fails to launch (RBS Code=5 / errno 153). Tradeoff: Screen Recording permission re-prompts each build.

### User Preferences (CRITICAL)
- **Zero cloud dependencies** — local-first always
- **Use Gibber** for task tracking — NOT English .md files (hooks enforce this)
- **Kokoro for TTS** — NOT macOS `say` (user was explicit)
- **Test yourself** — don't ask user to test. Use `say` command to announce results when user is away.
- **Knowledge page = graph only** — no flat record lists
- **Push to `fork` remote** (dzineer/omi), not upstream

### Run Commands
```bash
bash run.sh   # build + install (tunnel error is harmless)
codesign --force --deep --sign - "/Applications/Vibe AI Dev.app"  # required ad-hoc override (see Signing section)
sed -i '' 's|OMI_API_URL=.*|OMI_API_URL=http://localhost:8080|' "/Applications/Vibe AI Dev.app/Contents/Resources/.env"
open "/Applications/Vibe AI Dev.app"

# Manual server starts if app didn't auto-start them:
python3 ~/Library/Application\ Support/VoiceAI/mlx_whisper_server.py &   # STT 8787
python3 ~/Library/Application\ Support/VoiceAI/kokoro_tts_server.py &    # TTS 8788
```

## Logs & Debugging

### Local App Logs
- **App log file**: `/private/tmp/omi.log` (production) or `/private/tmp/omi-dev.log` (dev builds)

### Release Health (Sentry)
Check errors in the latest (or specific) release using the **sentry-release skill**:
```bash
./scripts/sentry-release.sh              # new issues in latest version (default)
./scripts/sentry-release.sh --version X  # specific version
./scripts/sentry-release.sh --all        # include carryover issues
./scripts/sentry-release.sh --quota      # billing/quota status
```
See `.claude/skills/sentry-release/SKILL.md` for full documentation.

### User Issue Investigation
When debugging issues for a specific user (crashes, errors, behavior), use the **user-logs skill**:
```bash
# Sentry (crashes, errors, breadcrumbs)
./scripts/sentry-logs.sh <email>

# PostHog (events, feature usage, app version)
./scripts/posthog_query.py <email>
```
See `.claude/skills/user-logs/SKILL.md` for full documentation and API queries.

## Repository
- This is the `desktop/` subfolder of the **Vibe AI monorepo** (`BasedHardware/omi`)
- macOS Swift app + Rust backend live here

## Release Pipeline

Merging `desktop/**` changes to `main` triggers a fully automated release:

1. **GitHub Actions** (`desktop_auto_release.yml`) — auto-increments version, pushes a `v*-macos` tag
2. **Codemagic** (`codemagic.yaml`, workflow `omi-desktop-swift-release`) — triggered by the tag, runs on Mac mini M2:
   - Builds universal binary (arm64 + x86_64)
   - Signs with Developer ID, notarizes with Apple
   - Creates DMG + Sparkle ZIP
   - Publishes GitHub release, uploads to GCS, registers in Firestore
   - Deploys Rust backend to Cloud Run
3. **Sparkle auto-update** delivers the new version to users

**Codemagic CLI & API:**
- Token: `$CODEMAGIC_API_TOKEN` (set in `~/.zshrc`)
- App ID: `66c95e6ec76853c447b8bcbb`
- List builds: `curl -s -H "x-auth-token: $CODEMAGIC_API_TOKEN" "https://api.codemagic.io/builds?appId=66c95e6ec76853c447b8bcbb" | python3 -c "import json,sys; [print(f\"{b.get('status','?'):12} tag={b.get('tag','-'):30} start={(b.get('startedAt') or '-')[:19]}\") for b in json.load(sys.stdin).get('builds',[])[:5]]"`

To promote: `./scripts/promote_release.sh <tag>` (staging → beta → stable).

## Firebase Connection
Use `/firebase` command or see `.claude/skills/firebase/SKILL.md`

Quick connect:
```bash
cd ../backend && source venv/bin/activate && python3 -c "
import firebase_admin
from firebase_admin import credentials, firestore, auth
cred = credentials.Certificate('google-credentials.json')
try: firebase_admin.initialize_app(cred)
except ValueError: pass
db = firestore.client()
print('Connected to Firebase: based-hardware')
"
```

## Key Architecture Notes

### Authentication
- Firebase Auth with Apple/Google Sign-In
- Desktop apps should use backend OAuth flow: `/v1/auth/authorize`
- Apple Services ID: `me.omi.web` (shared across all apps)
- iOS apps use native Sign-In, Desktop uses backend OAuth + custom token

### Database Structure
- **Firestore** (`based-hardware`): User data, conversations, action items
- **Redis**: Caching
- **Typesense**: Search

### User Subcollections (Firestore)
- `users/{uid}/conversations` - Has `source` field (omi, desktop, phone, etc.)
- `users/{uid}/action_items` - Tasks (no platform tracking)
- `users/{uid}/fcm_tokens` - Token ID prefix = platform (ios_, android_, macos_)
- `users/{uid}/memories` - Extracted memories

### Platform Detection
- **FCM tokens**: Document ID prefix (e.g., `macos_abc123`)
- **Conversations**: `source` field
- **Action items**: No platform tracking

### Known Limitations
- Firestore has no collection group indexes for `source` field
- Counting users by platform requires iterating all users (slow)
- Apple Sign-In: Only one Services ID per Firebase project

## API Endpoints
- Production: `https://api.omi.me`
- Local: `http://localhost:8080`

## Credentials
See `.claude/settings.json` for connection details.

## Development Workflow

### Building & Running
- **No Xcode project** — this is a Swift Package Manager project
- **Build command**: `xcrun swift build -c debug --package-path Desktop` (the `xcrun` prefix is required to match the SDK version)
- **Full dev run**: `./run.sh` — builds Swift app, starts Rust backend, starts Cloudflare tunnel, launches app
- **Build only**: `./build.sh` — release build without running
- **DO NOT** use bare `swift build` — it will fail with SDK version mismatch
- **DO NOT** use `xcodebuild` — there is no `.xcodeproj`
- **DO NOT** launch the app directly from `build/` — always use `./run.sh` or `./reset-and-run.sh`. These scripts install to `/Applications/Vibe AI Dev.app` and launch from there, which is required for macOS "Quit & Reopen" (after granting permissions) to find the correct binary. Launching from `build/` causes stale binaries to run after permission restarts.
- **DO NOT** manually copy binaries into app bundles and launch them — this bypasses signing, `/Applications/` installation, and LaunchServices registration

### App Names & Build Artifacts
- `./run.sh` builds **"Vibe AI Dev"** → installs to `/Applications/Vibe AI Dev.app` (bundle ID: `com.vibeaiglobal.vibeai-dev`)
- `./build.sh` builds **"Vibe AI"** → `build/Vibe AI.app` (bundle ID: `com.vibeaiglobal.vibeai`)
- Different bundle IDs, different app names, but same source code
- When updating resources (icons, assets, etc.) in built app bundles, update BOTH
- To check which app is currently running: `ps aux | grep "Vibe AI"`

### After Implementing Changes
- **By default**, do NOT build or run the app — let the user test manually with `./run.sh`
- **When the user says "test it"** (or similar), use the `test-local` skill to build, run, and verify changes using macOS automation
- See `.claude/skills/test-local/SKILL.md` for the full build → run → test → iterate workflow

### Changelog Entries

After completing a desktop task with user-visible impact, append a one-liner to `unreleased` in `desktop/CHANGELOG.json`:

```python
python3 -c "
import json
with open('CHANGELOG.json', 'r') as f:
    data = json.load(f)
data.setdefault('unreleased', []).append('Your user-facing change description')
with open('CHANGELOG.json', 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
"
```

Guidelines:
- Write from the user's perspective: "Fixed X", "Added Y", "Improved Z"
- One sentence, no period at the end
- Skip internal-only changes (refactors, CI config, code cleanup)
- HTML is allowed for links: `<a href='...'>text</a>`
- Commit CHANGELOG.json with your other changes (same commit is fine)

## User Task Completion Reporting

When completing a task that was triggered by an app user request (bug report, feature request, support inquiry, etc.) and you have the user's email address, **send them an email about the results** using the `omi-email` skill:

```bash
node ../omi-analytics/scripts/send-email.js \
  --to "<user-email>" \
  --subject "<brief result summary>" \
  --body "<what was done, what they should expect, any next steps>"
```

- Write as Matt (first person "I", not "we") — the user already has an ongoing email thread with us, so treat this as a casual continuation of that conversation, not a fresh introduction
- Be concise and direct — they know the context, just share what was done and any next steps (e.g. "update the app")
- Only send when there are meaningful results to share (don't email for internal-only changes)
