# akariyu.dev — Spec & Architecture

A premium mobile app that turns your Linux server into a remote development environment. Manage Claude Code sessions, edit files, monitor server health, and run terminals — all from your phone with a minimalistic, premium UI.

---

## 1. Product overview

**What it is:** Mobile-first remote dev environment over SSH. Connects to your always-on Linux server, gives you full access to filesystem, terminals, Claude Code sessions, git, and live server stats.

**Core principle:** The server is the brain. The phone is a premium window into it. Nothing executes locally on the device.

**Target user:** Developers who run a persistent dev server (Oracle Cloud ARM, VPS, home server) and want to work from their phone without compromising on UX.

---

## 2. Tech stack

| Layer | Choice | Why |
|---|---|---|
| App | Flutter | Cross-platform, native feel, fits stack |
| Connection | SSH (dartssh2 or libssh wrapper) | Already battle-tested, no custom daemon |
| File transfer | SFTP over SSH | Built-in to SSH |
| Auth | SSH keypair + biometric lock | Server-side security handled by SSH |
| State | Riverpod | Reactive, scales well |
| Local storage | flutter_secure_storage (keys) + Isar (cache) | Secure enclave for keys, fast cache for chats |
| Notifications | Firebase Cloud Messaging | Push when Claude finishes/needs input |
| Realtime | SSH long-running commands + tail -f | Stream output from server |

**Platforms:** iOS + Android from day one.

---

## 3. Architecture

```
┌─────────────────────────────────────────┐
│        akariyu.dev (Flutter app)        │
│  ┌──────────────────────────────────┐   │
│  │  UI Layer (screens, widgets)     │   │
│  ├──────────────────────────────────┤   │
│  │  State (Riverpod providers)      │   │
│  ├──────────────────────────────────┤   │
│  │  Services                        │   │
│  │  - SSHService                    │   │
│  │  - SFTPService                   │   │
│  │  - ClaudeSessionService          │   │
│  │  - TmuxService                   │   │
│  │  - ServerMonitorService          │   │
│  │  - GitService                    │   │
│  │  - NotificationService           │   │
│  ├──────────────────────────────────┤   │
│  │  Storage (Isar cache, secure)    │   │
│  └──────────────────────────────────┘   │
└────────────────┬────────────────────────┘
                 │
                 │ SSH (port 22 / custom)
                 │ TLS encrypted by SSH protocol
                 │
┌────────────────▼────────────────────────┐
│         Linux Server (your VPS)         │
│  ┌──────────────────────────────────┐   │
│  │  sshd (existing)                 │   │
│  ├──────────────────────────────────┤   │
│  │  tmux (session persistence)      │   │
│  │  └─ claude CLI sessions          │   │
│  ├──────────────────────────────────┤   │
│  │  ~/.claude/projects/             │   │
│  │  (chat history, JSONL files)     │   │
│  ├──────────────────────────────────┤   │
│  │  filesystem, git, docker, nginx  │   │
│  └──────────────────────────────────┘   │
└─────────────────────────────────────────┘
```

**Key design decisions:**

1. **No custom daemon.** Everything is done via SSH commands. The server stays untouched. Setup = upload your SSH key, done.
2. **Tmux for session persistence.** Every Claude session runs inside a named tmux session. Closing the app, killing the connection, swapping networks — nothing kills the session. Reconnect anytime by re-attaching to the tmux session.
3. **Read history from disk.** Chat history lives in `~/.claude/projects/<encoded-project-path>/<session-id>.jsonl`. App reads these JSONL files directly via SFTP for the history view.
4. **Stream output via tmux capture-pane or pipe-pane.** Real-time streaming of Claude output to the app.
5. **Notifications via a small helper on the server.** A lightweight watcher script (or systemd service) tails active tmux sessions for completion markers and pings FCM. Optional, not required for core function.

---

## 4. Authentication & Onboarding

### First launch flow

1. **Welcome screen** — minimalist, one-line tagline.
2. **Add server** — two options:
   - **Manual:** Host, port, username, paste private key OR upload key file.
   - **QR pair:** User runs a small command on server (`curl -s https://akariyu.dev/pair | bash` or a local script), terminal displays a QR with connection details. App scans it.
3. **Test connection** — app SSHs in, runs `whoami`, confirms. Stores key in `flutter_secure_storage` (uses iOS Keychain / Android Keystore).
4. **Set biometric lock** — Face ID / fingerprint / device PIN required to unlock app.
5. **Choose default project** — list directories under a configured base path (e.g. `~/projects`), user picks one as the homescreen default.

### Returning user flow

1. Open app → biometric prompt → unlocked.
2. App reconnects SSH session in background.
3. Dashboard loads with last-used project.

### Multiple servers

Support adding multiple servers (e.g. `dev-server` Oracle ARM + `braxtonserver`). Switch between them from the home screen.

### Security model

- SSH private key never leaves device, stored in secure enclave.
- Biometric required on every cold app open.
- Auto-lock after configurable inactivity (default 5 min).
- Optional: passphrase-protected keys supported, prompt for passphrase on connect.
- All traffic encrypted via SSH protocol (no plaintext anywhere).
- No backend server we operate. Direct app ↔ user's server only.

---

## 5. Feature breakdown

### 5.1 Home screen (per server)

- Server name + status indicator (connected / reconnecting / disconnected)
- Quick stats strip: CPU %, RAM %, Disk %, uptime
- Active Claude sessions count
- Recent projects list (last 5)
- Quick actions: New session, Open terminal, File browser, Server dashboard
- Bottom nav: Home, Claude, Files, Terminal, Server

### 5.2 File explorer

- Tree view of filesystem, starts from configurable root (default home dir)
- Tap folder → drill in. Long-press → context menu (rename, delete, copy path, new file, new folder)
- Tap file → opens in editor view
- Hidden files toggle
- Search within current directory
- Breadcrumb navigation at top
- Pull to refresh
- File icons by extension (premium icon set, not stock)

**Editor view:**
- Syntax highlighting (highlight.js or flutter_highlight) for common languages
- Read/write mode toggle (read-only by default to prevent fat-finger edits)
- Save indicator
- Diff view if file was modified
- Search & replace
- Line numbers
- Word wrap toggle
- Font size adjustable
- Premium monospace font (JetBrains Mono or Berkeley Mono)

### 5.3 Claude session management

The heart of the app.

**Sessions list (per project):**
- Reads `~/.claude/projects/<encoded-project-path>/*.jsonl` via SFTP
- Each session shown as a card:
  - Auto-generated title (from first user message, like claude.ai)
  - Last message preview
  - Last activity timestamp
  - Status: idle / running / waiting for input
  - Message count
  - Pin icon (pinned sessions float to top)
- Search across all sessions in project
- Filter: active only, pinned, archived
- New session button (FAB)

**Chat view:**
- Premium chat UI matching Claude app aesthetic
- Markdown rendering for Claude responses (with code block syntax highlighting)
- Streaming responses (tokens appear in real time)
- Tool use rendered as collapsible cards (file edits, bash commands, etc.)
- Tap code block → copy or expand to full screen
- Diff blocks for file changes — tap to see full diff
- Permission popups (Claude asking "approve this edit?") rendered as inline action cards
- Input bar at bottom:
  - Text field (multi-line, expanding)
  - Attach button → image picker, file picker (SFTP browser)
  - Voice input button (optional)
  - Send button
- Swipe left on a message → copy, edit, regenerate
- Long press → message-level actions
- Scroll to bottom button when scrolled up
- Haptic feedback on response complete

**Multi-session:**
- Top tab bar shows all active sessions across all projects
- Tap a tab → switch session
- Sessions persist in background (tmux keeps them alive)
- Close app entirely → sessions still running, resume next time
- Notification when a backgrounded session completes a long task

**Session lifecycle:**
- Each session = named tmux session: `tmux new-session -d -s "claude-<project>-<id>" "cd /path/to/project && claude --resume <session-id>"`
- App attaches to tmux via `tmux pipe-pane` or `tmux capture-pane -p` for streaming
- Send input via `tmux send-keys -t <session-name> "<message>" Enter`
- Detach on app close, reattach on open
- Explicit "End session" button to kill the tmux session

### 5.4 Terminal

- Multiple terminal tabs (each = a tmux session)
- Full xterm emulation (use `xterm.dart` or similar)
- Tap to type, gestures for arrow keys, custom toolbar with common keys (Tab, Ctrl, Esc, arrows, pipe, etc.)
- Command history accessible via swipe up
- Save commonly used commands as quick chips
- Copy/paste with clipboard integration
- Resize handles terminal columns/rows correctly

### 5.5 Git integration

Per project:
- Current branch indicator on project header
- Tap → branch switcher (list local + remote branches)
- Pull / Push / Fetch buttons
- Status view: staged / unstaged / untracked files
- Tap file → diff view
- Stage / unstage with tap
- Commit screen: message input, author auto-filled, commit button
- Recent commits list (scrollable, tap to see diff)
- Stash / unstash actions
- All operations are SSH commands under the hood (`git status --porcelain`, `git diff`, etc.) parsed and rendered as UI

### 5.6 Server dashboard

Live polling (interval configurable, default 5s):

- **CPU:** Overall %, per-core breakdown, load averages (1/5/15 min)
- **RAM:** Used / available / total, swap usage, graph over last 60s
- **Disk:** Per mount point, used/free/total with color-coded bars
- **Network:** Upload/download speed, total transferred, per-interface
- **Uptime:** Days/hours since boot
- **Temperature:** If available (`sensors` command)
- **Top processes:** Sorted by CPU or RAM, swipeable, long-press to kill
- **Docker containers:** List with status, CPU, RAM per container, tap for logs, stop/start/restart actions
- **Nginx status:** Active connections, requests/sec, status (running/stopped), config syntax check
- **Listening ports:** Port, service, PID
- **Disk I/O:** Read/write per device

Underlying commands: `top -bn1`, `free -m`, `df -h`, `ip -s link`, `uptime`, `sensors`, `ps auxf`, `docker ps --format`, `ss -tlnp`, `iostat`.

Charts: `fl_chart` package, premium-styled.

### 5.7 Notifications

Optional, requires setup on server side.

**Setup:**
- App generates an FCM token, prompts to install a small helper script on the server (1-line curl install).
- Helper is a tiny Go binary or Python script that:
  - Watches tmux sessions named `claude-*`
  - Detects when Claude pauses for user input or completes a long task (parses pipe-pane output for specific markers)
  - Pings FCM with project + session info

**Notification types:**
- Session needs your input (permission popup, choice prompt)
- Long-running task completed
- Session error / crashed
- Optional: server alerts (disk > 90%, RAM > 90%)

**Tap behavior:**
- Tapping a notification deep-links to that exact session in the app.

### 5.8 Settings

- Servers (add / remove / edit)
- Default project per server
- Theme (always dark, but accent color customizable — default akariyu purple/red)
- Font (system / JetBrains Mono / Berkeley Mono / Inter)
- Font size
- Auto-lock interval
- Polling interval for server stats
- Hidden files in explorer
- Notification preferences
- About / version / open source licenses

---

## 6. UI / Design system

### Aesthetic

- **Style:** Premium minimalist. Reference: Claude app, Linear, Raycast, Things 3.
- **Dark mode only** (matches your preference and the product feel).
- **No skeuomorphism, no gradients beyond subtle background washes.**
- **Generous whitespace.** Mobile screens are small, but breathing room beats density.

### Color palette

```
Background base       #0A0A0A   (near-black, not pure black)
Surface elevated      #141414
Surface card          #1C1C1C
Border subtle         #262626
Text primary          #F5F5F5
Text secondary        #A3A3A3
Text tertiary         #6B6B6B

Accent (akariyu)      #DC2626   (deep red, your cybersigilism palette)
Accent muted          #7F1D1D
Success               #22C55E
Warning               #F59E0B
Error                 #EF4444
Info                  #3B82F6

Status: idle          #6B6B6B
Status: running       #F59E0B (with pulse animation)
Status: waiting input #3B82F6
Status: done          #22C55E
Status: error         #EF4444
```

### Typography

- **UI font:** Inter (or SF Pro on iOS, Roboto on Android system-default fallback)
- **Monospace:** JetBrains Mono for code, terminal, file content
- **Display:** Inter Display for headers / large text
- Sizes: 32 / 24 / 20 / 16 / 14 / 12

### Components

- **Cards:** rounded-2xl (16px), subtle 1px border `#262626`, no shadow on dark
- **Buttons:** primary (accent fill), secondary (border only), ghost (no border, just text). Always rounded-xl (12px).
- **Inputs:** filled `#1C1C1C` background, focused state has accent border
- **Tabs:** underline indicator, animated slide between
- **Modals:** bottom sheets with drag handle, full sheets for major actions
- **Lists:** divider-less, use spacing + subtle border
- **Animations:** spring physics, never linear. 200-300ms standard duration.
- **Haptics:** light tap on interactions, medium on completions, heavy on errors

### Screens (high level)

```
┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐
│   Onboarding    │  │  Home / Server  │  │  Claude session │
│                 │  │                 │  │     list        │
│  [logo]         │  │  dev-server •   │  │                 │
│  akariyu.dev    │  │                 │  │  Project: PXLS  │
│                 │  │  CPU 12%        │  │                 │
│  Connect your   │  │  RAM 48%        │  │  ▸ Auth flow    │
│  server         │  │  Disk 67%       │  │  ▸ DB schema    │
│                 │  │                 │  │  ▸ UI polish    │
│                 │  │  Recent:        │  │                 │
│  [Add server]   │  │  • TIVA         │  │  + New session  │
│  [Pair via QR]  │  │  • PretSPACE    │  │                 │
└─────────────────┘  └─────────────────┘  └─────────────────┘

┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐
│   Chat view     │  │  File explorer  │  │  Server stats   │
│                 │  │                 │  │                 │
│  ▸ Auth flow    │  │  ~/projects/    │  │  ╭─ CPU ──────╮ │
│                 │  │                 │  │  │   ▁▃▅▇▅▃▁  │ │
│  You: refactor  │  │  📁 tiva        │  │  │   12% / 4c │ │
│  the JWT logic  │  │  📁 pretspace   │  │  ╰────────────╯ │
│                 │  │  📁 axiom       │  │                 │
│  Claude: I'll   │  │  📁 folia       │  │  ╭─ RAM ──────╮ │
│  start by...    │  │                 │  │  │   2.1/4 GB │ │
│  [code block]   │  │                 │  │  ╰────────────╯ │
│                 │  │                 │  │                 │
│  [input bar]    │  │                 │  │                 │
└─────────────────┘  └─────────────────┘  └─────────────────┘
```

---

## 7. Implementation plan / phases

### Phase 0 — Foundation (week 1)
- Flutter project setup, design system, theme, base components
- SSH connection (dartssh2)
- Server add / pair / store keys securely
- Biometric lock
- Connect / disconnect / reconnect logic

### Phase 1 — File explorer + terminal (week 2)
- SFTP browser
- File editor with syntax highlighting
- Terminal emulator with tmux backing
- Multi-tab terminals

### Phase 2 — Claude sessions (week 3-4)
- Read `~/.claude/projects/` JSONL files, parse into chat objects
- Sessions list per project
- Resume session via tmux
- Stream output to chat UI
- Send input
- Permission popups handled as inline actions
- Multi-session tab bar

### Phase 3 — Git + server dashboard (week 5)
- Git status / commit / branch / pull / push UI
- Server dashboard with polled metrics + charts
- Docker container list & actions

### Phase 4 — Polish + notifications (week 6)
- FCM setup
- Server-side notification helper script
- Deep linking
- Settings screen
- Onboarding polish
- Bug fixes, perf tuning

### Phase 5 — Beta + ship
- TestFlight + Play Store internal testing
- Iterate
- Public launch

---

## 8. Project structure (Flutter)

```
akariyu/
├── lib/
│   ├── main.dart
│   ├── app.dart                      # MaterialApp + theme + routes
│   ├── theme/
│   │   ├── colors.dart
│   │   ├── typography.dart
│   │   └── theme.dart
│   ├── core/
│   │   ├── ssh/
│   │   │   ├── ssh_service.dart
│   │   │   ├── sftp_service.dart
│   │   │   └── ssh_models.dart
│   │   ├── tmux/
│   │   │   └── tmux_service.dart
│   │   ├── claude/
│   │   │   ├── claude_session_service.dart
│   │   │   ├── claude_parser.dart       # JSONL parser
│   │   │   └── claude_models.dart
│   │   ├── git/
│   │   │   └── git_service.dart
│   │   ├── monitor/
│   │   │   └── monitor_service.dart
│   │   ├── storage/
│   │   │   ├── secure_storage.dart
│   │   │   └── cache.dart
│   │   └── notifications/
│   │       └── fcm_service.dart
│   ├── features/
│   │   ├── onboarding/
│   │   ├── home/
│   │   ├── files/
│   │   ├── terminal/
│   │   ├── claude/
│   │   ├── git/
│   │   ├── monitor/
│   │   └── settings/
│   ├── shared/
│   │   ├── widgets/                  # buttons, cards, inputs
│   │   ├── extensions/
│   │   └── utils/
│   └── routing/
│       └── router.dart
├── assets/
│   ├── fonts/
│   ├── icons/
│   └── images/
├── ios/
├── android/
├── pubspec.yaml
└── README.md
```

---

## 9. Key technical details

### SSH key handling
- Use `flutter_secure_storage` with `iosOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock)` and Android equivalent.
- Support both RSA and Ed25519 keys (Ed25519 preferred).
- Passphrase prompt on connect if key is encrypted.

### Tmux session naming convention
```
claude-<sanitized-project>-<short-uuid>
terminal-<short-uuid>
```

### Reading Claude history
```dart
// Path: ~/.claude/projects/<encoded-path>/<session-id>.jsonl
// Each line is a JSON object: { "type": "user"|"assistant"|"tool_use"|"tool_result", "content": ..., "timestamp": ... }
// Parse with jsonl streaming, render in chat view
```

### Streaming Claude output
```bash
# On connect, pipe tmux output:
tmux pipe-pane -t <session> "cat >> /tmp/claude-stream-<id>.log"
# App tails this file via SSH:
tail -f /tmp/claude-stream-<id>.log
```

Alternative: use `tmux capture-pane -p -t <session>` polled at 100ms intervals (simpler, less efficient).

### Sending input
```bash
tmux send-keys -t <session> "<escaped-message>" Enter
```

### Detecting permission popups
- Watch tmux output for specific Claude markers like `Do you want to proceed?` or tool-call confirmation patterns.
- Parse the options list, render as buttons in chat.
- Send back numerical choice via `tmux send-keys`.

### Server monitor commands (cached patterns)
```bash
# Run as a batched script for efficiency:
ssh <server> "bash -c '
  echo \"---CPU---\"
  top -bn1 | head -3
  echo \"---RAM---\"
  free -m
  echo \"---DISK---\"
  df -h
  echo \"---NET---\"
  cat /proc/net/dev
  echo \"---DOCKER---\"
  docker ps --format \"{{json .}}\"
  echo \"---UPTIME---\"
  uptime
'"
```

Parse sections, update UI.

---

## 10. Dependencies (pubspec.yaml essentials)

```yaml
dependencies:
  flutter:
    sdk: flutter
  flutter_riverpod: ^2.5.0
  dartssh2: ^2.10.0
  flutter_secure_storage: ^9.2.0
  local_auth: ^2.3.0          # biometric
  isar: ^3.1.0                # local cache
  isar_flutter_libs: ^3.1.0
  fl_chart: ^0.68.0           # server dashboard charts
  flutter_highlight: ^0.7.0   # code syntax
  xterm: ^4.0.0               # terminal emulator
  go_router: ^14.0.0
  firebase_core: ^3.0.0
  firebase_messaging: ^15.0.0
  qr_code_scanner: ^1.0.1
  image_picker: ^1.1.0
  file_picker: ^8.0.0
  google_fonts: ^6.2.0
  flutter_markdown: ^0.7.0
  intl: ^0.19.0
```

---

## 11. Open questions / future ideas

- **Multi-user / team:** Could share a session read-only via a generated link (Phase 6).
- **Voice mode:** Dictate to Claude, hear responses (Phase 6).
- **Watch app:** Glance at running sessions from Apple Watch (Phase 7).
- **Widgets:** Home screen widget showing server health + active session count.
- **Claude Code on web fallback:** If SSH unavailable, fall back to Anthropic's cloud Claude Code (lose local env access, gain reliability).

---

## 12. Success criteria

The app is "done" when you can:

1. Lock your laptop and walk away.
2. Open akariyu.dev on your phone, biometric unlock.
3. See your dev server is healthy.
4. Resume yesterday's Claude session and send a new prompt.
5. Get pinged on your phone when Claude needs a decision.
6. Approve it with one tap.
7. Lock your phone, get pinged when the task completes.
8. Never feel like you compromised on UX vs the desktop experience.

---

## 13. Brand

- **Name:** akariyu.dev
- **Tagline (working):** "Your dev server, in your pocket."
- **Aesthetic:** Cybersigilism-adjacent minimalism. Deep red accent. Sharp typography. Dark.
- **Icon:** Single bold mark on black. Custom mono glyph (suggested: stylized terminal cursor or `>` rendered in akariyu red).

---

End of spec.
