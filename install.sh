#!/bin/bash
# AUTO-GENERATED: Published to GitHub Pages by CI on each tagged release.
# Do not edit directly here — edit install.sh in the figma-mcp-server repo instead.
#
# Installs the latest Figma MCP Server extension (.mcpb) into Claude Desktop.
#   curl -fsSL https://wpp-jamie-mills.github.io/figma-mcp-server-site/install.sh | bash
#   curl -fsSL <same url> | bash -s -- --dir "$HOME/Tools/figma"
# For an AI agent (no terminal: it never quits or restarts an app, and doesn't wait for the install dialog):
#   curl -fsSL <same url> | FIGMA_INSTALL_TTY=/dev/null bash -s -- --no-wait
#   (it never opens the token prompt, which waits for a person: with no terminal or --no-wait the token is
#   saved later by figma_set_token, or by running the installer with --token)
#   (add --allow-figma-restart only after the user agreed to quit and reopen Figma)
#
# Environment overrides (mainly for tests):
#   FIGMA_MCP_HOME         data folder (--dir wins)
#   FIGMA_INSTALL_BASE     base URL for the download files (default: the GitHub Pages site)
#   FIGMA_CLAUDE_APP       path to Claude.app (default /Applications/Claude.app)
#   FIGMA_INSTALL_NO_OPEN  1 = don't open the .mcpb, the token page or notifications, and never quit or
#                          reopen an app; just say what would happen
#   FIGMA_INSTALL_TTY      where prompts are read from (default /dev/tty)
#   FIGMA_INSTALL_WAIT_SECS  how long to wait for Claude to list the new version (default 600; 0 with
#                          FIGMA_INSTALL_NO_OPEN or --no-wait)
#   FIGMA_KEYCHAIN_SERVICE / FIGMA_KEYCHAIN_ACCOUNT  Keychain item for the token (default figma-mcp-server / figma;
#                          letters, digits, . _ - only)
#   FIGMA_APP              path to Figma.app (default /Applications/Figma.app)
#   FIGMA_SETTINGS_FILE    Figma's settings.json (default ~/Library/Application Support/Figma/settings.json)
#   FIGMA_INSTALL_SKIP_TOKEN  1 = skip the token step (automation and tests)
#   FIGMA_INSTALL_NOTIFY   1 = show the final notification even with FIGMA_INSTALL_NO_OPEN=1 (tests)
#   FIGMA_INSTALLER_TEST   1 = enable the test seams below; without it they are ignored, so a real run
#                          always asks in the dialog and talks to https://api.figma.com. Never set it in a
#                          real environment: FIGMA_API_BASE_URL would then send the token to any URL.
#                          The stub token file is also ignored for the default Keychain item.
#   FIGMA_TOKEN_STUB_FILE / FIGMA_API_BASE_URL / FIGMA_TEST_PASTEBOARD   test seams for the token prompt: a file
#                          holding the token, another API address, a private pasteboard to clear (need
#                          FIGMA_INSTALLER_TEST=1)
set -euo pipefail

# Default download base (the prerelease copy is rewritten to point at /rc).
FIGMA_SITE_BASE_DEFAULT="https://wpp-jamie-mills.github.io/figma-mcp-server-site"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# printf, not echo -e, so backslashes in paths are shown as typed.
print_error() { printf '%b✗ %s%b\n' "$RED" "$1" "$NC" >&2; }
print_success() { printf '%b✓ %s%b\n' "$GREEN" "$1" "$NC"; }
print_warning() { printf '%b⚠ %s%b\n' "$YELLOW" "$1" "$NC"; }
print_step() { printf '%b→ %s%b\n' "$BLUE" "$1" "$NC"; }
die() {
  print_error "$1"
  exit 1
}

# Physical path of $1 with symlinks resolved in the part that already exists, so restricted-folder
# and same-folder checks can't be dodged with symlinks, double slashes or a different spelling.
canonical_path() {
  local path="$1" rest="" dir
  while [[ ! -d "$path" ]]; do
    rest="/${path##*/}$rest"
    path="${path%/*}"
    [[ -n "$path" ]] || path="/"
  done
  dir="$(cd -P "$path" 2>/dev/null && pwd -P)" || return 1
  [[ "$dir" != "/" ]] || dir=""
  printf '%s%s\n' "$dir" "$rest"
}

lowercase() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

FIGMA_TEMP_DIR=""
FIGMA_KEEP_TEMP=false
cleanup_temp() {
  [[ "$FIGMA_KEEP_TEMP" != true ]] || return 0
  if [[ -n "$FIGMA_TEMP_DIR" && -d "$FIGMA_TEMP_DIR" ]]; then rm -rf "$FIGMA_TEMP_DIR"; fi
}

usage() {
  cat <<'EOF'
Figma MCP Server installer

Usage:
  curl -fsSL https://wpp-jamie-mills.github.io/figma-mcp-server-site/install.sh | bash
  curl -fsSL https://wpp-jamie-mills.github.io/figma-mcp-server-site/install.sh | bash -s -- --dir "$HOME/Tools/figma"

Options:
  --dir <path>   Data folder for the plugin copy, pairing code and download
                 (default: ~/.figma-mcp-server). Pick the same folder in the
                 "Data folder" field of Claude Desktop's install dialog.
  --token        Ask for the Figma token in the secure prompt, even if one is saved and even without a
                 terminal. Without --token, a run with no terminal or with --no-wait never opens the
                 prompt (it waits for a person): ask Claude to run figma_set_token instead.
  --status       Print the install state (Claude extension, token, plugin, pairing, and what the
                 server last wrote to status.json) and exit. Never prints the token.
  --no-wait      Open Claude Desktop's install dialog and exit without waiting for Claude to list the
                 new version (same as FIGMA_INSTALL_WAIT_SECS=0). Check later with --status: exit 0 means the
                 installer finished its steps, not that Claude Desktop installed the extension.
  --allow-figma-restart
                 Consent, without a terminal, to the one question "quit and reopen Figma to import
                 the plugin?". It never answers the Claude Desktop restart question.
  --help         Show this help.

This installer may need to quit and reopen Figma and Claude Desktop. It asks first each time. Without a
terminal (FIGMA_INSTALL_TTY=/dev/null) it never restarts an app: when Figma is open and the plugin isn't
imported yet it says how to finish (re-run with --allow-figma-restart after asking the user, or import by
hand). It also refuses to quit the app it is running inside. If quitting an app fails, macOS may need
Automation permission for your terminal (System Settings > Privacy & Security > Automation).

Environment:
  FIGMA_MCP_HOME  Same as --dir (--dir wins).
EOF
}

# Reads or edits claude_desktop_config.json with JavaScript for Automation, so no jq or node is needed.
#   config_figma <config> <expected args[0]> check   -> prints match | nomatch | invalid | missing | error
#   config_figma <config> <expected args[0]> remove  -> prints removed | nomatch | invalid | missing | writefail | error
# "remove" only deletes mcpServers.figma when its args[0] is the expected path, and writes atomically.
# "error" means osascript itself failed. The helpers never exit non-zero, so set -e can't end the install.
config_figma() {
  osascript -l JavaScript - "$1" "$2" "$3" <<'JXA' || echo error
ObjC.import("Foundation");
function run(argv) {
  const [given, want, action] = argv;
  // Edit the real file behind a symlinked config (e.g. dotfiles) rather than replacing the link.
  const path = $(given).stringByResolvingSymlinksInPath.js;
  const text = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null);
  if (text.isNil()) return "missing";
  let cfg;
  try {
    cfg = JSON.parse(text.js);
  } catch (e) {
    return "invalid";
  }
  const entry = cfg && cfg.mcpServers && cfg.mcpServers.figma;
  if (!entry || !Array.isArray(entry.args) || entry.args[0] !== want) return "nomatch";
  if (action !== "remove") return "match";
  delete cfg.mcpServers.figma;
  const out = $(JSON.stringify(cfg, null, 2) + "\n");
  return out.writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, null)
    ? "removed"
    : "writefail";
}
JXA
}

FIGMA_KEYCHAIN_SERVICE="${FIGMA_KEYCHAIN_SERVICE:-figma-mcp-server}"
FIGMA_KEYCHAIN_ACCOUNT="${FIGMA_KEYCHAIN_ACCOUNT:-figma}"

# True when the Keychain item exists. Presence only: attributes are read, never the token.
token_present() {
  security find-generic-password -s "$FIGMA_KEYCHAIN_SERVICE" -a "$FIGMA_KEYCHAIN_ACCOUNT" >/dev/null 2>&1
}

# Hidden-input prompt, figd_ check, /v1/me test and Keychain save in one process: the token never
# appears in argv, the environment or a file. Prints one JSON line ({"ok":true,"handle":...} or
# {"ok":false,"reason":...}). Keep identical to TOKEN_PROMPT_JXA in src/token-prompt.ts (a test checks).
token_prompt() {
  local api_base="https://api.figma.com/v1"
  # The address goes into a curl config line, so only a plain http(s) URL is accepted.
  local url_re='^https?://[^"[:space:]]+$'
  if [[ "${FIGMA_INSTALLER_TEST:-}" == "1" && "${FIGMA_API_BASE_URL:-}" =~ $url_re ]]; then api_base="$FIGMA_API_BASE_URL"; fi
  osascript -l JavaScript - "$FIGMA_KEYCHAIN_SERVICE" "$FIGMA_KEYCHAIN_ACCOUNT" "$api_base" <<'JXA'
ObjC.import("Foundation");
ObjC.import("AppKit");
ObjC.import("signal");

// Runs a program with input on stdin; returns its exit status and stdout. A program that exits before
// it has read its input (a dead curl) breaks the pipe: that comes back as a failure status.
function exec(path, args, input) {
  // Writing to a closed pipe raises SIGPIPE, which would kill this process; ignore it (SIG_IGN is 1).
  $.signal(13, 1);
  const task = $.NSTask.alloc.init;
  task.setLaunchPath($(path));
  task.setArguments($(args));
  const stdin = $.NSPipe.pipe;
  const stdout = $.NSPipe.pipe;
  task.setStandardInput(stdin);
  task.setStandardOutput(stdout);
  task.setStandardError($.NSPipe.pipe);
  task.launch;
  let wrote = true;
  try {
    stdin.fileHandleForWriting.writeData($(input).dataUsingEncoding($.NSUTF8StringEncoding));
  } catch (e) {
    wrote = false;
  }
  try { stdin.fileHandleForWriting.closeFile; } catch (e) {}
  const data = stdout.fileHandleForReading.readDataToEndOfFile;
  task.waitUntilExit;
  const status = task.terminationStatus;
  return { status: wrote || status !== 0 ? status : 1, stdout: ObjC.unwrap($.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding)) || "" };
}

// The pasteboard the token was pasted from. Tests name a private one so they never touch the real clipboard.
function pasteboard(env, testMode) {
  const name = ObjC.unwrap(env.objectForKey("FIGMA_TEST_PASTEBOARD"));
  return testMode && name ? $.NSPasteboard.pasteboardWithName(name) : $.NSPasteboard.generalPasteboard;
}

// Empties the pasteboard, but only if it still holds nothing but the token that was just pasted.
function clearPasteboardIfHolds(pb, token) {
  const held = ObjC.unwrap(pb.stringForType($.NSPasteboardTypeString));
  if (typeof held === "string" && held.trim() === token) pb.clearContents;
}

// argv: service, account, apiBase. Prints one JSON line; the token never leaves this process
// except on the stdin of curl and security -i.
function run(argv) {
  const [service, account, apiBase] = argv;
  // They end up in a security -i command line, so allow nothing that could split it.
  const safe = /^[A-Za-z0-9._-]+$/;
  if (!safe.test(service || "") || !safe.test(account || "")) return JSON.stringify({ ok: false, reason: "store" });
  const env = $.NSProcessInfo.processInfo.environment;
  // Test seams (a token file, another API address, a private pasteboard) work only with this variable.
  // The token file is also refused for the default Keychain item, so a stray variable can't store a stub there.
  const testMode = ObjC.unwrap(env.objectForKey("FIGMA_INSTALLER_TEST")) === "1";
  // The address goes into a curl config line: in test mode only a plain http(s) URL is accepted.
  if (testMode && !/^https?:\/\/[^"\s]+$/.test(apiBase || "")) return JSON.stringify({ ok: false, reason: "network" });
  const base = testMode ? apiBase : "https://api.figma.com/v1";
  const stubFile = testMode && service !== "figma-mcp-server" ? ObjC.unwrap(env.objectForKey("FIGMA_TOKEN_STUB_FILE")) : "";
  let token;
  if (stubFile) {
    token = ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError(stubFile, $.NSUTF8StringEncoding, null)).trim();
  } else {
    const app = Application.currentApplication();
    app.includeStandardAdditions = true;
    try { app.activate(); } catch (e) {}
    let answer;
    try {
      answer = app.displayDialog(
        "Paste your Figma personal access token (it starts with figd_). It is stored in your macOS Keychain and never shown again.",
        { withTitle: "Figma MCP Server", defaultAnswer: "", hiddenAnswer: true, buttons: ["Cancel", "Save"], defaultButton: "Save", cancelButton: "Cancel", withIcon: "note", givingUpAfter: 600 },
      );
    } catch (e) {
      return JSON.stringify({ ok: false, reason: "cancelled" });
    }
    if (answer.gaveUp) return JSON.stringify({ ok: false, reason: "timeout" });
    token = answer.textReturned.trim();
  }
  // The pasted token may still be on the clipboard; remove it now that the dialog is gone.
  clearPasteboardIfHolds(pasteboard(env, testMode), token);
  if (!/^figd_[A-Za-z0-9_-]{10,}$/.test(token)) return JSON.stringify({ ok: false, reason: "format" });

  // curl reads its config (including the token header) from stdin, so the token is never in argv.
  let out;
  try {
    out = exec("/usr/bin/curl", ["-sS", "--max-time", "20", "-K", "-"],
      'url = "' + base + '/me"\nheader = "X-Figma-Token: ' + token + '"\nwrite-out = "\\n%{http_code}"\n');
  } catch (e) {
    return JSON.stringify({ ok: false, reason: "network" });
  }
  if (out.status !== 0) return JSON.stringify({ ok: false, reason: "network" });
  const lines = out.stdout.split("\n");
  const status = Number(lines.pop());
  if (status === 401 || status === 403) return JSON.stringify({ ok: false, reason: "rejected" });
  if (status !== 200) return JSON.stringify({ ok: false, reason: "network", status });
  let handle = "";
  try { handle = JSON.parse(lines.join("\n")).handle || ""; } catch (e) {}

  let stored;
  try {
    stored = exec("/usr/bin/security", ["-i"], "add-generic-password -U -s " + service + " -a " + account + " -w " + token + "\n");
  } catch (e) {
    return JSON.stringify({ ok: false, reason: "store" });
  }
  if (stored.status !== 0) return JSON.stringify({ ok: false, reason: "store" });
  return JSON.stringify({ ok: true, handle });
}
JXA
}

# Version of the Figma extension that Claude Desktop lists as installed, or "none".
claude_extension_version() {
  osascript -l JavaScript - "$1" <<'JXA' || echo none
ObjC.import("Foundation");
function run(argv) {
  const text = $.NSString.stringWithContentsOfFileEncodingError(
    $(argv[0]).stringByResolvingSymlinksInPath,
    $.NSUTF8StringEncoding,
    null,
  );
  if (text.isNil()) return "none";
  try {
    const all = JSON.parse(text.js).extensions || {};
    const key = Object.keys(all).find((k) => /\.figma-canvas-bridge$/.test(k));
    return key && all[key].version ? String(all[key].version) : "none";
  } catch (e) {
    return "none";
  }
}
JXA
}

# Adds (or checks) the plugin's entry in Figma's settings.json, which Figma reads at launch. Only run the
# "add" while Figma is closed: Figma rewrites the file from memory when it quits.
#   figma_settings <settings.json> <manifest.json> add     -> added | present | invalid | missing | writefail | error
#   figma_settings <settings.json> <manifest.json> check   -> verified | present | absent | invalid | missing | error
# The plugin counts as imported when ANY localFileExtensions entry has a manifestPath equal to
# <plugin dir>/manifest.json, <plugin dir>/code.js or <plugin dir>/ui.html. "verified" means Figma has loaded
# the plugin: a manifest.json entry with fileMetadata.codeFileId, or a code.js/ui.html entry with fileMetadata.
# "present" means only our manifest.json entry exists and Figma hasn't processed it yet. "add" never adds a
# manifest.json entry when any of those entries exists (no duplicates): it returns "present" or "verified".
#
# Shape of the entry we add ({id, manifestPath, lastKnownName, lastKnownPluginId}): from Figma's own loader code.
# Shape of what Figma leaves behind, captured from real Figma 126.x runs on 2026-10-12: once Figma has loaded
# the plugin it completes our manifest entry with fileMetadata ({type: "manifest", codeFileId, uiFileIds}; the
# name and plugin id are already in the entry we wrote) and adds
#   {id, manifestPath: <plugin dir>/code.js, fileMetadata: {type: "code", manifestFileId: <manifest id>}} and
#   {id, manifestPath: <plugin dir>/ui.html, fileMetadata: {type: "ui",   manifestFileId: <manifest id>}}.
# That three-entry shape was still there after quitting and reopening Figma, and the plugin was still listed
# under Plugins > Development (under its manifest name). One earlier snapshot, taken from a settings file
# shortly after the first load, held only the code and ui entries, so every state is recognised.
#
# "add" never rewrites the whole file through JSON.parse/JSON.stringify (that would corrupt integers beyond 2^53
# and reformat everything): it inserts the new entry as text and leaves every other byte alone. It copies the
# file to settings.json.bak-figma-<stamp> first (keeping the 3 newest of those), checks that the result still
# parses, writes it atomically with the original file mode, and returns "invalid" without writing if the
# result wouldn't parse.
figma_settings() {
  osascript -l JavaScript - "$1" "$2" "$3" <<'JXA' || echo error
ObjC.import("Foundation");

const isSpace = (c) => c === " " || c === "\t" || c === "\n" || c === "\r";

// Index just past the string whose opening quote is at i, or -1.
function stringEnd(text, i) {
  for (let j = i + 1; j < text.length; j++) {
    if (text[j] === "\\") j++;
    else if (text[j] === '"') return j + 1;
  }
  return -1;
}

// The members of the object or array that opens at `open`: where each starts and ends (end is just past its
// last character) and its key for an object. null if the container never closes.
function scan(text, open) {
  const members = [];
  let depth = 0;
  let start = -1;
  let key = null;
  let last = open;
  const finish = () => {
    if (start >= 0) members.push({ start, end: last + 1, key });
    start = -1;
    key = null;
  };
  for (let i = open + 1; i < text.length; i++) {
    const c = text[i];
    if (isSpace(c)) continue;
    if (c === '"') {
      const e = stringEnd(text, i);
      if (e < 0) return null;
      if (start < 0) {
        start = i;
        if (text[open] === "{") key = JSON.parse(text.slice(i, e));
      }
      i = e - 1;
      last = i;
      continue;
    }
    if (depth === 0 && (c === "]" || c === "}")) {
      finish();
      return { members };
    }
    if (depth === 0 && c === ",") {
      finish();
      last = i;
      continue;
    }
    if (start < 0) start = i;
    if (c === "[" || c === "{") depth++;
    else if (c === "]" || c === "}") depth--;
    last = i;
  }
  return null;
}

// Where `piece` goes to add a member after the last one (or into an empty container), as [index, text].
// The whitespace that led the last member is reused, so a pretty-printed file stays pretty-printed.
function appendTo(text, container, piece) {
  const found = scan(text, container);
  if (!found) return null;
  const last = found.members[found.members.length - 1];
  if (!last) return [container + 1, piece];
  let from = last.start;
  while (from > 0 && isSpace(text[from - 1])) from--;
  return [last.end, "," + text.slice(from, last.start) + piece];
}

// The text with the entry added to localFileExtensions (or the key added to the top-level object); null if
// the file isn't laid out as expected.
function insertEntry(text, entry) {
  let root = 0;
  while (root < text.length && isSpace(text[root])) root++;
  if (text[root] !== "{") return null;
  const top = scan(text, root);
  if (!top) return null;
  const member = top.members.filter((m) => m.key === "localFileExtensions").pop();
  const json = JSON.stringify(entry);
  let at;
  if (member) {
    let v = stringEnd(text, member.start);
    while (isSpace(text[v])) v++;
    if (text[v] !== ":") return null;
    v++;
    while (isSpace(text[v])) v++;
    if (text[v] !== "[") return null;
    at = appendTo(text, v, json);
  } else {
    at = appendTo(text, root, '"localFileExtensions":[' + json + "]");
  }
  return at && text.slice(0, at[0]) + at[1] + text.slice(at[0]);
}

// Copies the file next to itself as <name>.bak-figma-<stamp> and keeps only the 3 newest such copies
// (the new one and the 2 newest of the installer's own earlier ones).
function backUp(fm, path) {
  const d = new Date();
  const p = (n) => String(n).padStart(2, "0");
  const stamp = "" + d.getFullYear() + p(d.getMonth() + 1) + p(d.getDate()) + "-" + p(d.getHours()) + p(d.getMinutes()) + p(d.getSeconds());
  let copy = path + ".bak-figma-" + stamp;
  for (let n = 1; fm.fileExistsAtPath(copy); n++) copy = path + ".bak-figma-" + stamp + "-" + n;
  if (!fm.copyItemAtPathToPathError(path, copy, null)) return false;
  const dir = $(path).stringByDeletingLastPathComponent.js;
  const prefix = $(path).lastPathComponent.js + ".bak-figma-";
  const made = $(copy).lastPathComponent.js;
  // Only names the installer itself generates (<stamp> or <stamp>-<n>) count as its backups, and the copy
  // just made is never a candidate, whatever its stamp says (a clock set back would sort it oldest).
  const stampOf = (n) => /^(\d{8}-\d{6})(?:-(\d+))?$/.exec(n.slice(prefix.length));
  const key = (n) => stampOf(n)[1] + "-" + String(stampOf(n)[2] || 0).padStart(10, "0");
  const older = ObjC.deepUnwrap(fm.contentsOfDirectoryAtPathError(dir, null))
    .filter((n) => n !== made && n.startsWith(prefix) && stampOf(n))
    .sort((a, b) => (key(a) < key(b) ? -1 : key(a) > key(b) ? 1 : 0));
  for (const name of older.slice(0, -2)) fm.removeItemAtPathError(dir + "/" + name, null);
  return true;
}

function run(argv) {
  const [given, manifestPath, action] = argv;
  const path = $(given).stringByResolvingSymlinksInPath.js;
  const text = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null);
  if (text.isNil()) return "missing";
  const original = text.js;
  let cfg;
  try {
    cfg = JSON.parse(original);
  } catch (e) {
    return "invalid";
  }
  if (!cfg || typeof cfg !== "object" || Array.isArray(cfg)) return "invalid";
  if ("localFileExtensions" in cfg && !Array.isArray(cfg.localFileExtensions)) return "invalid";
  const list = cfg.localFileExtensions || [];
  // The plugin counts as imported when any entry points at its manifest.json, code.js or ui.html (once Figma
  // has loaded the plugin it completes the manifest entry and adds code and ui entries; one snapshot showed
  // only the code and ui entries).
  // Paths match as exact strings after the folder part has had its symlinks resolved (so a data folder reached
  // through a symlink matches an entry written with the real path, and the other way round). The file name is
  // compared as written: "<dir>-old/code.js", "<dir>/code.js/" and a different plugin folder never match.
  const key = (p) => {
    const i = p.lastIndexOf("/");
    if (i < 0) return p;
    return $(p.slice(0, i)).stringByResolvingSymlinksInPath.js + "/" + p.slice(i + 1);
  };
  const dir = manifestPath.slice(0, manifestPath.lastIndexOf("/"));
  const ours = [manifestPath, dir + "/code.js", dir + "/ui.html"].map(key);
  const found = list.filter((e) => e && typeof e.manifestPath === "string" && ours.includes(key(e.manifestPath)));
  const state = () => {
    if (!found.length) return "absent";
    const loaded = found.some((e) =>
      key(e.manifestPath) === ours[0] ? e.fileMetadata && e.fileMetadata.codeFileId : e.fileMetadata && typeof e.fileMetadata === "object",
    );
    return loaded ? "verified" : "present";
  };
  if (action === "check") return state();
  if (found.length) return state();
  // NSString drops a leading byte order mark when it reads, so writing the text back would lose it. Refuse
  // such a file rather than change a byte other than the inserted entry.
  const head = $.NSData.dataWithContentsOfFile($(path));
  if (!head.isNil() && ObjC.unwrap(head.subdataWithRange($.NSMakeRange(0, Math.min(3, head.length))).base64EncodedStringWithOptions(0)) === "77u/") return "invalid";
  const manifestText = $.NSString.stringWithContentsOfFileEncodingError(manifestPath, $.NSUTF8StringEncoding, null);
  if (manifestText.isNil()) return "missing";
  let manifest;
  try {
    manifest = JSON.parse(manifestText.js);
  } catch (e) {
    return "invalid";
  }
  const ids = list.map((e) => (e && Number.isSafeInteger(e.id) ? e.id : 0));
  const added = {
    id: Math.max(0, ...ids) + 1,
    manifestPath: manifestPath,
    lastKnownName: manifest.name,
    lastKnownPluginId: manifest.id,
  };
  const edited = insertEntry(original, added);
  if (edited === null) return "invalid";
  try {
    const again = JSON.parse(edited).localFileExtensions;
    if (!Array.isArray(again) || !again.some((e) => e && e.manifestPath === manifestPath)) return "invalid";
  } catch (e) {
    return "invalid";
  }
  const fm = $.NSFileManager.defaultManager;
  const mode = fm.attributesOfItemAtPathError(path, null).objectForKey("NSFilePosixPermissions");
  if (!backUp(fm, path)) return "writefail";
  if (!$(edited).writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, null)) return "writefail";
  // The atomic write makes a new file; give it the old file's permissions.
  if (!mode.isNil()) fm.setAttributesOfItemAtPathError($.NSDictionary.dictionaryWithObjectForKey(mode, "NSFilePosixPermissions"), path, null);
  return "added";
}
JXA
}

# Puts the plugin files from the verified bundle in <data>/figma-plugin, where Figma will import them from.
# The bundle sits in the data folder while the user clicks through Claude's dialog, so it is copied into a
# private folder, that copy is hashed, and only that copy is unpacked: the file that was hashed is the file
# that is read. A bundle that no longer matches the hash verified at download is refused.
# Everything happens inside $FIGMA_TEMP_DIR, which the exit trap removes, so an interrupted run leaves nothing.
# The new folder is built next to the unpacked files and swapped in with a rename only once it is complete,
# so a failure midway leaves the previous <data>/figma-plugin as it was.
extract_plugin() {
  local mcpb="$1" dest="$2" version="$3" expected_sha="$4" now tmp rc copy stage
  tmp="$(mktemp -d "${FIGMA_TEMP_DIR:-${TMPDIR:-/tmp}}/plugin.XXXXXX")" || return 1
  copy="$tmp/bundle.mcpb"
  if ! cp "$mcpb" "$copy" 2>/dev/null; then
    rm -rf "$tmp"
    return 1
  fi
  now="$(shasum -a 256 <"$copy" | awk '{ print $1 }')"
  if [[ -z "$expected_sha" || "$now" != "$expected_sha" ]]; then
    print_error "$mcpb changed after it was verified, so it was not unpacked"
    rm -rf "$tmp"
    return 1
  fi
  if unzip -qo "$copy" 'figma-plugin/manifest.json' 'figma-plugin/code.js' 'figma-plugin/ui.html' -d "$tmp" 2>/dev/null &&
    [[ -f "$tmp/figma-plugin/manifest.json" && -f "$tmp/figma-plugin/code.js" && -f "$tmp/figma-plugin/ui.html" ]]; then
    stage="$tmp/stage"
    mkdir -p "$stage" && chmod 700 "$stage" &&
      { [[ ! -d "$dest" ]] || cp -R "$dest"/. "$stage"/; } &&
      cp "$tmp/figma-plugin/manifest.json" "$stage/" &&
      cp "$tmp/figma-plugin/code.js" "$stage/" &&
      cp "$tmp/figma-plugin/ui.html" "$stage/" &&
      { [[ -z "$version" ]] || printf '%s\n' "$version" >"$stage/.version"; }
    rc=$?
    # While the previous folder is moved aside it is the only copy: an interrupt in that window must not let the
    # exit trap delete $tmp. The flag is reset only once the swap has succeeded (or the old folder is back).
    if [[ $rc -eq 0 && -d "$dest" ]]; then
      FIGMA_KEEP_TEMP=true
      mv "$dest" "$tmp/old" || rc=1
      # A failed move leaves the folder where it was, so there is nothing to protect.
      [[ -d "$tmp/old" ]] || FIGMA_KEEP_TEMP=false
    fi
    if [[ $rc -eq 0 ]] && ! mv "$stage" "$dest"; then
      rc=1
      # Put the previous folder back. If that fails too, it is the only copy left: keep it, and tell the user where.
      if [[ -d "$tmp/old" ]] && ! mv "$tmp/old" "$dest"; then
        FIGMA_KEEP_TEMP=true
        print_error "Couldn't put your previous plugin folder back; it is kept at $tmp/old"
        return 1
      fi
    fi
    if [[ $rc -eq 0 || ! -d "$tmp/old" ]]; then FIGMA_KEEP_TEMP=false; fi
    rm -rf "$tmp"
    return $rc
  fi
  rm -rf "$tmp"
  return 1
}

# True when a .download.XXXXXX folder holds only what this script puts there: the three downloaded files and
# plugin.XXXXXX folders (bundle copy, unpacked files, staged folder). A previous <data>/figma-plugin moved
# aside during the swap ("old") is not ours to delete, so it makes the folder stay.
is_plain_file() { [[ -f "$1" && ! -L "$1" ]]; }
is_plain_dir() { [[ -d "$1" && ! -L "$1" ]]; }

# True when a folder holds only the plugin files (plain files, nothing else, no hidden extras like ..x).
holds_only_plugin_files() {
  local h
  for h in "$1"/* "$1"/.[!.]* "$1"/..?*; do
    [[ -e "$h" || -L "$h" ]] || continue
    case "${h##*/}" in manifest.json | code.js | ui.html | .version) is_plain_file "$h" || return 1 ;; *) return 1 ;; esac
  done
}

download_leftover_is_ours() {
  local dir="$1" f g
  for f in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
    [[ -e "$f" || -L "$f" ]] || continue
    case "${f##*/}" in
      latest.mcpb | latest.mcpb.sha256 | latest.version) is_plain_file "$f" || return 1 ;;
      plugin.??????)
        is_plain_dir "$f" || return 1
        for g in "$f"/* "$f"/.[!.]* "$f"/..?*; do
          [[ -e "$g" || -L "$g" ]] || continue
          case "${g##*/}" in
            bundle.mcpb) is_plain_file "$g" || return 1 ;;
            stage | figma-plugin) { is_plain_dir "$g" && holds_only_plugin_files "$g"; } || return 1 ;;
            *) return 1 ;;
          esac
        done
        ;;
      *) return 1 ;;
    esac
  done
  return 0
}

# Reads a yes/no answer from the terminal (default no). Without a usable terminal the answer is no.
# The answer source must be a regular file (the tests' scripted answers) or a terminal; /dev/null or another
# device can't answer, so nothing is printed for it.
can_answer() {
  local p="$FIGMA_INSTALL_TTY_PATH"
  [[ -r "$p" ]] || return 1
  [[ -f "$p" ]] && return 0
  [[ -c "$p" ]] || return 1
  { [[ -t 3 ]]; } 2>/dev/null 3<"$p"
}

ask_yes_no() {
  local answer=""
  can_answer || return 1
  printf '%s [y/N] ' "$1"
  { read -r -t 600 answer <"$FIGMA_INSTALL_TTY_PATH"; } 2>/dev/null || true
  case "$(lowercase "$answer")" in y | yes) return 0 ;; *) return 1 ;; esac
}

app_running() { pgrep -x "$1" >/dev/null 2>&1; }

# True when this installer runs inside the app at $1 (its .app folder): any process up the parent chain has its
# executable under that folder. Quitting the app would then end the installer, and the terminal it runs in.
# Best effort only: ps may show a bare command name or a title the app rewrote, and a process that was
# reparented to launchd no longer has the app above it, so a miss is possible. That is why the question is
# only ever asked after an explicit yes (a terminal answer; for Figma also --allow-figma-restart) and never
# assumed from this check alone.
inside_app() {
  local app_path="${1%/}" pid="$$" line ppid comm i
  for ((i = 0; i < 64; i++)); do
    line="$(ps -o ppid=,comm= -p "$pid" 2>/dev/null || true)"
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -n "$line" ]] || return 1
    ppid="${line%%[[:space:]]*}"
    comm="${line#"$ppid"}"
    comm="${comm#"${comm%%[![:space:]]*}"}"
    case "$comm" in "$app_path"/*) return 0 ;; esac
    [[ "$ppid" =~ ^[0-9]+$ && "$ppid" -gt 1 && "$ppid" != "$pid" ]] || return 1
    pid="$ppid"
  done
  return 1
}

# Quits an app politely and waits (up to ~30s) for it to go. Returns 1 if it is still running, if the quit
# was refused, or if this installer runs inside the app. $2 is the app's .app folder.
quit_app() {
  local app="$1" app_path="$2" i quit_ok=true limit=60
  if inside_app "$app_path"; then
    print_warning "This installer is running inside $app, so it won't quit it (that would end the install). Quit and reopen $app yourself."
    return 1
  fi
  osascript -e "tell application \"$app\" to quit" >/dev/null 2>&1 || quit_ok=false
  # A refused quit request won't be followed by a quit: give the app 2 seconds, not 30.
  [[ "$quit_ok" == true ]] || limit=4
  for ((i = 0; i < limit; i++)); do
    app_running "$app" || return 0
    sleep 0.5
  done
  [[ "$quit_ok" == true ]] || print_warning "macOS refused the quit request. It may need your permission: in System Settings > Privacy & Security > Automation, allow your terminal to control $app, then run the installer again (or quit $app yourself)."
  [[ "$quit_ok" != true ]] || print_warning "$app is still running after 30 seconds. If macOS asked to let your terminal control $app, allow it (System Settings > Privacy & Security > Automation), or quit $app yourself."
  return 1
}

# Reads <data>/status.json (written by the server, see src/ready.ts) with JavaScript for Automation. Prints
# "key=value" lines for the non-secret fields only (control characters removed, long values cut), the age in
# seconds, and "unreadable" when the file isn't JSON. The file never holds the token; only these fields are read.
read_status_file() {
  osascript -l JavaScript - "$1" <<'JXA' || echo unreadable
ObjC.import("Foundation");
function run(argv) {
  const text = $.NSString.stringWithContentsOfFileEncodingError($(argv[0]), $.NSUTF8StringEncoding, null);
  if (text.isNil()) return "unreadable";
  let s;
  try {
    s = JSON.parse(text.js);
  } catch (e) {
    return "unreadable";
  }
  if (!s || typeof s !== "object" || Array.isArray(s)) return "unreadable";
  const clean = (v) => (typeof v === "string" || typeof v === "number" ? String(v).replace(/[\u0000-\u001f\u007f-\u009f]/g, "").slice(0, 200) : "");
  const token = s.token || {};
  const plugin = s.plugin || {};
  const prompt = s.tokenPrompt || {};
  const out = [
    ["server_version", s.serverVersion],
    ["token_state", token.state],
    ["handle", token.handle],
    ["token_prompt", prompt.state],
    ["plugin_state", plugin.state],
    ["plugin_file", plugin.fileName],
    ["plugin_page", plugin.pageName],
    ["server_pid", Number.isSafeInteger(s.serverPid) && s.serverPid >= 1 ? s.serverPid : ""],
  ];
  const at = Date.parse(s.updatedAt);
  out.push(["age", isNaN(at) ? "" : Math.max(0, Math.round((Date.now() - at) / 1000))]);
  return out.map(([k, v]) => k + "=" + clean(v)).join("\n");
}
JXA
}

# What the server last wrote to status.json, plus whether that is still current: stale when it is older than
# 10 minutes or the server process that wrote it is gone.
print_server_status() {
  local file="$1" raw line key value
  if [[ ! -f "$file" ]]; then
    echo "status_file: missing"
    return 0
  fi
  raw="$(read_status_file "$file")"
  if [[ "$raw" == unreadable* ]]; then
    echo "status_file: $file (unreadable)"
    return 0
  fi
  local server_version="" token_state="" handle="" token_prompt="" plugin_state="" plugin_file="" plugin_page="" pid="" age=""
  while IFS= read -r line; do
    key="${line%%=*}"
    value="${line#*=}"
    case "$key" in
      server_version) server_version="$value" ;;
      token_state) token_state="$value" ;;
      handle) handle="$value" ;;
      token_prompt) token_prompt="$value" ;;
      plugin_state) plugin_state="$value" ;;
      plugin_file) plugin_file="$value" ;;
      plugin_page) plugin_page="$value" ;;
      server_pid) pid="$value" ;;
      age) age="$value" ;;
    esac
  done <<<"$raw"
  echo "status_file: $file"
  [[ -z "$server_version" ]] || echo "server_version: $server_version"
  echo "status_age_seconds: ${age:-unknown}"
  local stale=no
  if [[ ! "$age" =~ ^[0-9]+$ || "$age" -gt 600 ]]; then
    stale="yes (updated more than 10 minutes ago)"
  elif [[ ! "$pid" =~ ^[1-9][0-9]*$ ]] || ! kill -0 "$pid" 2>/dev/null; then
    stale="yes (the server that wrote it isn't running)"
  fi
  echo "stale: $stale"
  echo "token_state: ${token_state:-unknown}"
  [[ -z "$handle" ]] || echo "handle: $handle"
  [[ -z "$token_prompt" ]] || echo "token_prompt: $token_prompt"
  echo "plugin_state: ${plugin_state:-unknown}"
  [[ -z "$plugin_file" ]] || echo "plugin_file: $plugin_file"
  [[ -z "$plugin_page" ]] || echo "plugin_page: $plugin_page"
}

print_status() {
  local data_dir="$1" claude_support="$2"
  local ext
  ext="$(claude_extension_version "$claude_support/extensions-installations.json")"
  echo "data_dir: $data_dir"
  echo "claude_extension: $ext"
  if token_present; then echo "token: present"; else echo "token: missing"; fi
  if [[ -f "$data_dir/figma-plugin/.version" ]]; then
    echo "plugin_files: $(tr -d '[:space:]' <"$data_dir/figma-plugin/.version")"
  else
    echo "plugin_files: missing"
  fi
  local fsettings="${FIGMA_SETTINGS_FILE:-$HOME/Library/Application Support/Figma/settings.json}"
  if [[ -f "$fsettings" && -f "$data_dir/figma-plugin/manifest.json" ]]; then
    echo "figma_plugin_import: $(figma_settings "$fsettings" "$data_dir/figma-plugin/manifest.json" check)"
  else
    echo "figma_plugin_import: unknown"
  fi
  if [[ -s "$data_dir/bridge-token" ]]; then echo "pairing_code: present"; else echo "pairing_code: missing"; fi
  print_server_status "$data_dir/status.json"
}

# One line for the end of the install: what happened to the plugin import.
plugin_summary() {
  case "$1" in
    imported) echo "imported" ;;
    already) echo "already imported${2:+ ($2)}" ;;
    added) echo "added, not yet loaded${2:+ ($2)}" ;;
    manual) echo "needs manual import" ;;
    *) echo "skipped" ;;
  esac
}

main() {
  [[ -n "${HOME:-}" ]] || die "HOME isn't set, so the installer can't find your home folder"
  local data_dir="" force_token=false status_only=false no_wait=false allow_figma_restart=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dir)
        [[ $# -ge 2 && -n "$2" ]] || die "--dir needs a folder path"
        data_dir="$2"
        shift 2
        ;;
      --dir=*)
        data_dir="${1#--dir=}"
        [[ -n "$data_dir" ]] || die "--dir needs a folder path"
        shift
        ;;
      --token)
        force_token=true
        shift
        ;;
      --status)
        status_only=true
        shift
        ;;
      --no-wait)
        no_wait=true
        shift
        ;;
      --allow-figma-restart)
        allow_figma_restart=true
        shift
        ;;
      --help | -h)
        usage
        exit 0
        ;;
      *) die "Unknown argument: $1 (try --help)" ;;
    esac
  done

  # They go into a security command line in the token prompt, so allow nothing that could split it.
  [[ "$FIGMA_KEYCHAIN_SERVICE" =~ ^[A-Za-z0-9._-]+$ ]] || die "FIGMA_KEYCHAIN_SERVICE may only contain letters, digits, dots, underscores and hyphens"
  [[ "$FIGMA_KEYCHAIN_ACCOUNT" =~ ^[A-Za-z0-9._-]+$ ]] || die "FIGMA_KEYCHAIN_ACCOUNT may only contain letters, digits, dots, underscores and hyphens"

  local default_dir="${HOME%/}/.figma-mcp-server"
  [[ -n "$data_dir" ]] || data_dir="${FIGMA_MCP_HOME:-$default_dir}"
  # Expand a leading ~ (the shell doesn't when the path arrives quoted or via the environment).
  if [[ "$data_dir" == \~ || "$data_dir" == \~/* ]]; then data_dir="$HOME${data_dir:1}"; fi
  data_dir="${data_dir%/}"

  [[ "$data_dir" == /* ]] || die "The data folder must be an absolute path: $data_dir"
  case "/$data_dir/" in
    */../* | */./*) die "The data folder can't contain . or .. segments: $data_dir" ;;
  esac
  local claude_support="$HOME/Library/Application Support/Claude"
  # Compare physical, lower-cased paths: macOS volumes are case-insensitive by default.
  local canon_data canon_default canon_home p canon_p
  canon_data="$(canonical_path "$data_dir")" || die "Can't resolve the data folder: $data_dir"
  canon_data="$(lowercase "$canon_data")"
  canon_default="$(canonical_path "$default_dir")" || die "Can't resolve $default_dir"
  canon_default="$(lowercase "$canon_default")"
  canon_home="$(canonical_path "$HOME")" || die "Can't resolve your home folder"
  canon_home="$(lowercase "$canon_home")"
  for p in "$claude_support/Claude Extensions" /Applications /System /Library /usr /bin /sbin /etc /private/etc; do
    canon_p="$(lowercase "$(canonical_path "$p")")"
    if [[ "$canon_data" == "$canon_p" || "$canon_data" == "$canon_p/"* ]]; then
      die "Can't use a restricted location as the data folder: $data_dir"
    fi
  done
  [[ "$canon_data" != "$canon_home" ]] || die "Can't use your home folder itself (a restricted location) as the data folder"
  # The default folder may hold the old git clone, which is moved aside below, so nothing may live inside it.
  if [[ "$canon_data" == "$canon_default/"* ]]; then
    die "The data folder can't be inside $default_dir; use that folder itself or one outside it"
  fi
  local is_default=false
  if [[ "$canon_data" == "$canon_default" ]]; then
    is_default=true
    data_dir="$default_dir"
  fi

  local tty_path="${FIGMA_INSTALL_TTY:-/dev/tty}"
  FIGMA_INSTALL_TTY_PATH="$tty_path"
  local claude_app="${FIGMA_CLAUDE_APP:-/Applications/Claude.app}"
  local install_base="${FIGMA_INSTALL_BASE:-$FIGMA_SITE_BASE_DEFAULT}"
  install_base="${install_base%/}"
  local config_file="$claude_support/claude_desktop_config.json"
  # Under curl | bash there is no local install.sh, so the pointers to --status spell out the whole command.
  # Every value is shell-quoted (printf %q) so the printed command can be pasted even when a path holds a
  # space, $, backtick, quote or backslash.
  local q_base q_dir
  printf -v q_base '%q' "$install_base"
  printf -v q_dir '%q' "$data_dir"
  local status_cmd="curl -fsSL $q_base/install.sh | bash -s -- --status"
  if [[ "$is_default" != true ]]; then status_cmd+=" --dir $q_dir"; fi

  if [[ "$status_only" == true ]]; then
    [[ "$(uname -s)" == "Darwin" ]] || die "This installer requires macOS"
    print_status "$data_dir" "$claude_support"
    return 0
  fi

  echo ""
  echo -e "${BLUE}╔═══════════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BLUE}║                    Figma MCP Server Installer                     ║${NC}"
  echo -e "${BLUE}║          Let Claude read, comment on, and draw in Figma           ║${NC}"
  echo -e "${BLUE}╚═══════════════════════════════════════════════════════════════════╝${NC}"
  echo ""

  print_warning "This installer may need to quit and reopen Figma and Claude Desktop. It will ask first each time. Save your work in both."
  echo ""

  print_step "Checking prerequisites..."
  [[ "$(uname -s)" == "Darwin" ]] || die "This installer requires macOS"
  [[ -d "$claude_app" ]] || die "Claude.app not found at: $claude_app (install Claude Desktop first)"
  local tool
  for tool in curl shasum osascript open security; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is not available"
  done
  print_success "macOS and Claude Desktop found"

  # Old git-clone install from the previous installer: a clone in ~/.figma-mcp-server plus a
  # claude_desktop_config.json entry pointing at its dist/index.js. Detect now, change nothing yet.
  local old_entry="$default_dir/dist/index.js"
  local old_git=false old_cfg=false
  [[ -d "$default_dir/.git" ]] && old_git=true
  if [[ -f "$config_file" && "$(config_figma "$config_file" "$old_entry" check)" == "match" ]]; then
    old_cfg=true
  fi
  local migrate=false
  if [[ -L "$default_dir" && ( "$old_git" == true || "$old_cfg" == true ) ]]; then
    print_warning "$default_dir is a symlink, so the old install is left unchanged; remove it and the \"figma\" server in Claude Desktop's config yourself"
  elif [[ "$old_git" == true && "$old_cfg" == true ]]; then
    migrate=true
    print_step "Found an old git-clone install; it will be replaced after the download is verified"
  elif [[ "$old_cfg" == true ]]; then
    print_warning "Found a partial old installation: Claude Desktop's config has a \"figma\" server pointing at $old_entry, but no git clone there. Remove that entry so two Figma servers don't run"
  elif [[ "$old_git" == true ]]; then
    print_warning "Found a partial old installation: a git clone in $default_dir with no matching config entry — leaving it unchanged"
  fi

  # The data folder must be new, empty, or one of ours.
  if [[ -e "$data_dir" && ! -d "$data_dir" ]]; then die "Not a folder: $data_dir"; fi
  if [[ -d "$data_dir" ]]; then
    local ours=false
    if [[ -e "$data_dir/.figma-mcp-home" || -e "$data_dir/bridge-token" ]]; then ours=true; fi
    # The server itself creates figma-plugin/ in the default folder.
    if [[ "$is_default" == true && ( -d "$data_dir/figma-plugin" || "$migrate" == true ) ]]; then ours=true; fi
    if [[ "$ours" != true && -n "$(find "$data_dir" -mindepth 1 -maxdepth 1 ! -name '.download.*' ! -name .DS_Store 2>/dev/null)" ]]; then
      die "That folder is not empty and isn't a Figma MCP data folder: $data_dir"
    fi
    [[ -w "$data_dir" ]] || die "That folder isn't writable: $data_dir"
    # Leftovers from an interrupted run: only our own temp folders (mktemp's 6-character suffix,
    # holding nothing but what this script creates). Anything else in one makes it stay.
    local leftover
    for leftover in "$data_dir"/.download.??????; do
      [[ -d "$leftover" && ! -L "$leftover" ]] || continue
      # Touched in the last 15 minutes: another installer run may be using it.
      [[ -z "$(find "$leftover" -maxdepth 0 -mmin -15 2>/dev/null)" ]] || continue
      ! download_leftover_is_ours "$leftover" || rm -rf "$leftover"
    done
  else
    mkdir -p "$data_dir" || die "Couldn't create $data_dir"
    chmod 700 "$data_dir" || die "Couldn't set permissions on $data_dir"
  fi
  # Mark the folder as ours straight away, so a re-run after an interruption recognises it.
  touch "$data_dir/.figma-mcp-home"
  print_success "Data folder: $data_dir"

  # Download into a temp folder and verify before anything is changed.
  FIGMA_TEMP_DIR="$(mktemp -d "$data_dir/.download.XXXXXX")" || die "Couldn't create a temporary folder"
  trap cleanup_temp EXIT

  print_step "Downloading the latest extension..."
  curl -fsSL "$install_base/latest.mcpb" -o "$FIGMA_TEMP_DIR/latest.mcpb" || die "Download failed: $install_base/latest.mcpb"
  curl -fsSL "$install_base/latest.mcpb.sha256" -o "$FIGMA_TEMP_DIR/latest.mcpb.sha256" || die "Download failed: $install_base/latest.mcpb.sha256"
  local version=""
  if curl -fsSL "$install_base/latest.version" -o "$FIGMA_TEMP_DIR/latest.version" 2>/dev/null; then
    version="$(tr -d '[:space:]' <"$FIGMA_TEMP_DIR/latest.version")"
  fi

  local expected actual
  expected="$(awk 'NR == 1 { print tolower($1) }' "$FIGMA_TEMP_DIR/latest.mcpb.sha256")"
  # Hash from stdin: shasum escapes file names containing backslashes and prefixes the hash with "\".
  actual="$(shasum -a 256 <"$FIGMA_TEMP_DIR/latest.mcpb" | awk '{ print $1 }')"
  if [[ ! "$expected" =~ ^[0-9a-f]{64}$ || "$expected" != "$actual" ]]; then
    print_error "Checksum mismatch — nothing was installed"
    print_error "Expected: ${expected:-<none>}"
    print_error "Got:      $actual"
    print_error "This can happen for up to about 10 minutes while a new release propagates; wait and run the installer again."
    exit 1
  fi
  print_success "Downloaded and verified${version:+ version $version}"

  # Replace the old git-clone install now that the new bundle is verified. The clone is only moved
  # aside once its config entry is gone, so Claude Desktop never points at a missing server. It is
  # moved, not deleted, in case it holds local changes.
  if [[ "$migrate" == true ]]; then
    local stamp backup result old_copy
    stamp="$(date +%Y%m%d-%H%M%S)"
    backup="$config_file.bak-figma-$stamp"
    cp -p "$config_file" "$backup" || die "Couldn't back up $config_file"
    # Make the destination before touching the config, so a failure here changes nothing.
    old_copy="$default_dir.old-$stamp"
    mkdir -m 700 "$old_copy" || die "Couldn't create $old_copy; nothing was changed"
    result="$(config_figma "$config_file" "$old_entry" remove)"
    if [[ "$result" == "removed" ]]; then
      print_success "Removed the old \"figma\" server from Claude Desktop's config (backup: $backup)"
      local item moved_all=true
      for item in "$default_dir"/* "$default_dir"/.[!.]*; do
        [[ -e "$item" || -L "$item" ]] || continue
        case "${item##*/}" in
          bridge-token | figma-plugin | .figma-mcp-home | latest.mcpb | latest.mcpb.sha256 | latest.version | .download.*) ;;
          *) mv "$item" "$old_copy/" || moved_all=false ;;
        esac
      done
      if [[ "$moved_all" == true ]]; then
        print_success "Moved the old clone to $old_copy (kept your pairing code and plugin folder). Delete it once you don't need it."
      else
        print_warning "Moved most of the old clone to $old_copy, but some files couldn't be moved and are still in $default_dir"
      fi
    else
      rmdir "$old_copy" 2>/dev/null || true
      print_warning "Couldn't update Claude Desktop's config ($result); left the old install in place"
    fi
  fi

  local name
  for name in latest.mcpb latest.mcpb.sha256 latest.version; do
    if [[ -d "$data_dir/$name" ]]; then die "$data_dir/$name is a folder; move it out of the way and run the installer again"; fi
  done
  mv -f "$FIGMA_TEMP_DIR/latest.mcpb" "$data_dir/latest.mcpb"
  mv -f "$FIGMA_TEMP_DIR/latest.mcpb.sha256" "$data_dir/latest.mcpb.sha256"
  if [[ -n "$version" ]]; then mv -f "$FIGMA_TEMP_DIR/latest.version" "$data_dir/latest.version"; fi

  # Keep an existing pairing when switching to a custom folder: copy, never move.
  if [[ "$is_default" != true && -f "$default_dir/bridge-token" && ! -e "$data_dir/bridge-token" ]]; then
    if (umask 077 && cp "$default_dir/bridge-token" "$data_dir/bridge-token") && chmod 600 "$data_dir/bridge-token"; then
      print_success "Copied your pairing code to the new folder"
    else
      print_warning "Couldn't copy your pairing code; Figma will ask you to pair again"
    fi
  fi

  # Pairing code: created here so it can be shown at the end (and copied) instead of asked for later.
  # Same format and alphabet as the server (no 0/O/1/I/L), file mode 600.
  local code_created=false manifest_copied=false
  if [[ ! -s "$data_dir/bridge-token" ]]; then
    local raw
    raw="$(LC_ALL=C tr -dc 'ABCDEFGHJKMNPQRSTUVWXYZ23456789' </dev/urandom 2>/dev/null | head -c 8 || true)"
    if [[ ${#raw} -eq 8 ]]; then
      if ! { (umask 077 && printf '%s-%s\n' "${raw:0:4}" "${raw:4:4}" >"$data_dir/bridge-token") && chmod 600 "$data_dir/bridge-token"; }; then
        print_warning "Couldn't create the pairing code; Claude will make one when it starts"
      else
        code_created=true
      fi
    fi
  fi

  # Figma token: kept only in the Keychain. Ask when there is none (or with --token).
  local handle=""
  if [[ "${FIGMA_INSTALL_SKIP_TOKEN:-}" == "1" ]]; then
    print_step "Skipping the token step (FIGMA_INSTALL_SKIP_TOKEN=1)"
  elif [[ "$force_token" == true ]] || { [[ "$no_wait" != true ]] && can_answer && ! token_present; }; then
    # The prompt is a modal dialog that waits for a person (up to 10 minutes, three tries). It opens only when
    # asked for with --token, or on a real terminal without --no-wait: an agent's run must return quickly.
    echo ""
    print_step "Your Figma personal access token is needed (it is saved to your Keychain, never shown in chat)."
    echo "  Create one at https://www.figma.com/settings/tokens with these scopes:"
    echo "    current_user:read, file_content:read, file_metadata:read, file_versions:read,"
    echo "    file_comments:read, file_comments:write, library_content:read, projects:read,"
    echo "    file_variables:read (variables need a Figma Enterprise plan)"
    if [[ "${FIGMA_INSTALL_NO_OPEN:-}" != "1" ]]; then
      open "https://www.figma.com/settings/tokens" >/dev/null 2>&1 || true
    fi
    local result="" attempt
    for attempt in 1 2 3; do
      # The prompt can stay open for 10 minutes: keep the temp folder "recent" for the leftover sweep.
      touch "$FIGMA_TEMP_DIR" 2>/dev/null || true
      result="$(token_prompt || true)"
      case "$result" in
        *'"ok":true'*)
          # Decode the JSON string properly (quotes, backslashes and \u escapes in a handle).
          handle="$(osascript -l JavaScript -e 'function run(argv) { try { return JSON.parse(argv[0]).handle || ""; } catch (e) { return ""; } }' "$result" 2>/dev/null || true)"
          # Control characters (ESC included) must not reach the terminal or the notification.
          handle="$(printf '%s' "$handle" | LC_ALL=C tr -d '\000-\037\177')"
          print_success "Token saved to the Keychain${handle:+ (Figma user @$handle)}"
          break
          ;;
        *'"reason":"cancelled"'*)
          print_warning "Token prompt cancelled. Run the installer with --token, or ask Claude to run figma_set_token, to add it later."
          break
          ;;
        *'"reason":"timeout"'*)
          print_warning "The token prompt timed out, so no token was saved. Run the installer with --token, or ask Claude to run figma_set_token, to add it later."
          break
          ;;
        *'"reason":"format"'*) print_warning "That doesn't look like a Figma token (it starts with figd_). Try again." ;;
        *'"reason":"rejected"'*) print_warning "Figma rejected that token. Check it is current and has the scopes above, then try again." ;;
        *'"reason":"network"'*) print_warning "Couldn't reach the Figma API to check the token. Check your connection, then try again." ;;
        *'"reason":"store"'*) print_warning "Couldn't save the token to the Keychain." ;;
        *) print_warning "The token prompt failed or ended without a result, so no token was saved." ;;
      esac
      [[ "$attempt" -lt 3 ]] || print_warning "No token saved. Ask Claude to run figma_set_token when you have one."
    done
  elif ! token_present; then
    print_warning "No Figma token is saved yet. Ask Claude to run figma_set_token (a secure prompt), or re-run with --token."
  else
    print_success "A Figma token is already saved in the Keychain"
  fi

  local ext_file="$claude_support/extensions-installations.json"
  local before
  before="$(claude_extension_version "$ext_file")"

  # Claude already lists this version: don't open the install dialog again.
  local already_installed=false
  # Same version listed but another data folder: the dialog opens so the Data folder can be set, and the
  # listing can't show when that is done, so "already listed" must not count as success.
  local reopen_same=false
  [[ -n "$version" && "$before" == "$version" && "$is_default" != true ]] && reopen_same=true
  # Only for the default data folder: with --dir the extension's "Data folder" setting in Claude must be set
  # in the dialog, so it opens even when this version is already listed.
  if [[ -n "$version" && "$before" == "$version" && "$is_default" == true ]]; then
    already_installed=true
    print_success "Figma MCP Server $version is already installed"
  elif [[ "${FIGMA_INSTALL_NO_OPEN:-}" == "1" ]]; then
    print_step "Would open: open -a \"$claude_app\" \"$data_dir/latest.mcpb\""
  else
    print_step "Opening Claude Desktop's install dialog..."
    open -a "$claude_app" "$data_dir/latest.mcpb" ||
      print_warning "Couldn't open it automatically. Double-click $data_dir/latest.mcpb to install."
  fi

  if [[ "$already_installed" != true ]]; then
    echo ""
    echo "In the install dialog:"
    if [[ "$is_default" != true ]]; then
      printf '  1. Set "Data folder" to: %b%s%b\n' "$BLUE" "$data_dir" "$NC"
      echo "  2. Click Install."
    else
      echo "  Leave \"Data folder\" as it is and click Install."
    fi
  fi

  # Wait until Claude lists the extension at the new version, instead of asking for Enter.
  local wait_secs="${FIGMA_INSTALL_WAIT_SECS:-}"
  if [[ -z "$wait_secs" ]]; then
    if [[ "${FIGMA_INSTALL_NO_OPEN:-}" == "1" ]]; then wait_secs=0; else wait_secs=600; fi
  fi
  if [[ "$no_wait" == true || "$already_installed" == true ]]; then wait_secs=0; fi
  local installed="none" waited=0
  while :; do
    # Keep the temp folder "recent" for the leftover sweep while a long wait goes on.
    touch "$FIGMA_TEMP_DIR" 2>/dev/null || true
    installed="$(claude_extension_version "$ext_file")"
    if [[ -n "$version" ]]; then
      [[ "$installed" != "$version" ]] || break
    elif [[ "$installed" != "none" && "$installed" != "$before" ]]; then
      break
    fi
    [[ "$waited" -lt "$wait_secs" ]] || break
    [[ "$waited" -ne 0 ]] || print_step "Waiting for you to click Install in Claude Desktop..."
    sleep 2
    waited=$((waited + 2))
  done

  # Import the plugin into Figma by editing its settings file while Figma is closed. The settings are read
  # first: an entry that is already there is left alone, and Figma is only quit when it has to be.
  local figma_app="${FIGMA_APP:-/Applications/Figma.app}"
  local figma_settings_file="${FIGMA_SETTINGS_FILE:-$HOME/Library/Application Support/Figma/settings.json}"
  local plugin_manifest="$data_dir/figma-plugin/manifest.json"
  local plugin_state="skipped" plugin_note=""
  local loaded_note="added; Figma completes it (adding code.js and ui.html entries) the next time it starts"
  if [[ ! -d "$figma_app" && ! -f "$figma_settings_file" ]]; then
    print_step "Figma desktop isn't installed here, so the plugin import is skipped"
  elif extract_plugin "$data_dir/latest.mcpb" "$data_dir/figma-plugin" "$version" "$expected"; then
    local known
    known="$(figma_settings "$figma_settings_file" "$plugin_manifest" check)"
    case "$known" in
      verified)
        plugin_state="already"
        print_success "The Figma MCP Server for Claude plugin is already imported in Figma; Figma was left alone"
        ;;
      present)
        plugin_state="already"
        plugin_note="$loaded_note"
        print_success "The Figma MCP Server for Claude plugin is already imported in Figma's settings; Figma was left alone"
        ;;
      absent)
        local figma_open=false quit_by_us=false
        if [[ "${FIGMA_INSTALL_NO_OPEN:-}" != "1" ]] && app_running Figma; then figma_open=true; fi
        local go=true
        if [[ "$figma_open" == true ]]; then
          go=false
          if inside_app "$figma_app"; then
            print_warning "This installer is running inside Figma, so it won't quit it. Quit and reopen Figma yourself."
          elif [[ "$allow_figma_restart" == true ]]; then
            print_step "Quitting and reopening Figma to import the plugin (--allow-figma-restart)"
            if quit_app Figma "$figma_app"; then go=true quit_by_us=true; else print_warning "Figma didn't quit"; fi
          else
            touch "$FIGMA_TEMP_DIR" 2>/dev/null || true
            if ask_yes_no "Figma is open. Quit and reopen it to import the Figma MCP Server for Claude plugin? Save your work first."; then
              if quit_app Figma "$figma_app"; then go=true quit_by_us=true; else print_warning "Figma didn't quit"; fi
            fi
          fi
        fi
        if [[ "$go" == true ]]; then
          local imported
          imported="$(figma_settings "$figma_settings_file" "$plugin_manifest" add)"
          case "$imported" in
            added | present | verified) plugin_state="added" ;;
            *)
              plugin_state="failed"
              print_warning "Couldn't edit Figma's settings ($imported)"
              ;;
          esac
          if [[ "$quit_by_us" == true ]]; then open -a "$figma_app" || print_warning "Couldn't reopen Figma; open it yourself."; fi
          if [[ "$plugin_state" == "added" ]]; then
            local i=0 seen
            if [[ "$quit_by_us" == true ]]; then
              touch "$FIGMA_TEMP_DIR" 2>/dev/null || true
              while [[ $i -lt 20 ]]; do
                seen="$(figma_settings "$figma_settings_file" "$plugin_manifest" check)"
                [[ "$seen" != "verified" ]] || break
                sleep 1
                i=$((i + 1))
              done
            else
              seen="$(figma_settings "$figma_settings_file" "$plugin_manifest" check)"
            fi
            if [[ "$seen" == "verified" ]]; then
              plugin_state="imported"
              print_success "Imported the Figma MCP Server for Claude plugin into Figma"
            elif [[ "$quit_by_us" == true ]]; then
              plugin_note="$loaded_note"
              print_warning "Added to Figma's settings; Figma hasn't loaded it yet. Give it a moment, or check with: $status_cmd"
            else
              plugin_note="$loaded_note"
              print_success "Added the Figma MCP Server for Claude plugin to Figma's settings; it will be there next time Figma starts (Figma completes the entry then)"
            fi
          fi
        else
          plugin_state="declined"
          print_warning "Figma is open and the plugin isn't imported yet, so Figma was not restarted. To finish: quit and reopen Figma yourself and run the installer again, or run it again with --allow-figma-restart (only once the user agreed to quit and reopen Figma)."
        fi
        ;;
      *)
        plugin_state="failed"
        print_warning "Couldn't edit Figma's settings ($known)"
        ;;
    esac
    if [[ "$plugin_state" == "failed" || "$plugin_state" == "declined" ]]; then
      plugin_state="manual"
      print_warning "Import the plugin by hand: in Figma desktop choose Plugins → Development → Import plugin from manifest… and pick:"
      echo "  $plugin_manifest"
      if [[ "${FIGMA_INSTALL_NO_OPEN:-}" != "1" ]]; then printf '%s' "$plugin_manifest" | pbcopy 2>/dev/null && { manifest_copied=true; echo "  (that path is on your clipboard)"; }; fi
    fi
  else
    plugin_state="manual"
    print_warning "Couldn't unpack the plugin files from the download; ask Claude to run figma_canvas_setup instead"
  fi
  echo ""
  local finished=false
  if [[ "$reopen_same" == true ]]; then
    print_warning "Finish the dialog (set Data folder), then run: $status_cmd"
  elif [[ -n "$version" && "$installed" == "$version" ]] || [[ -z "$version" && "$installed" != "none" && "$installed" != "$before" ]]; then
    finished=true
    print_success "Claude Desktop lists Figma MCP Server $installed"
    # An upgrade: Claude may still be running the old server. Restart only if the user agrees.
    if [[ "$before" != "none" && "$before" != "$installed" && "${FIGMA_INSTALL_NO_OPEN:-}" != "1" ]] && app_running Claude; then
      touch "$FIGMA_TEMP_DIR" 2>/dev/null || true
      if inside_app "$claude_app"; then
        print_warning "This installer is running inside Claude Desktop, so it won't quit it. Restart Claude Desktop yourself to use the new version."
      elif ask_yes_no "Claude Desktop may still be running the old version. Quit and reopen it now?"; then
        if quit_app Claude "$claude_app"; then
          open -a "$claude_app" || print_warning "Couldn't reopen Claude Desktop; open it yourself."
        else
          print_warning "Claude Desktop didn't quit; restart it yourself to use the new version."
        fi
      else
        print_warning "Restart Claude Desktop yourself to use the new version."
      fi
    fi
    if [[ "${FIGMA_INSTALL_NO_OPEN:-}" != "1" || "${FIGMA_INSTALL_NOTIFY:-}" == "1" ]]; then
      local note
      if [[ -n "$handle" ]]; then note="Figma connected as @$handle"; else note="Figma MCP Server $installed is installed"; fi
      # The text travels as an argument, never as AppleScript source, so quotes and backslashes stay text.
      osascript -e 'on run argv' -e 'display notification (item 1 of argv) with title "Figma MCP Server"' -e 'end run' -- "$note" >/dev/null 2>&1 || true
    fi
  elif [[ "$wait_secs" -gt 0 ]]; then
    print_warning "Claude Desktop doesn't list the new version yet (installed: $installed). Finish the install dialog, then run: $status_cmd"
  else
    print_step "Not waiting for Claude Desktop to finish; run this to check: $status_cmd"
  fi

  echo ""
  if [[ "$finished" == true ]]; then print_success "Done."; else print_warning "Install not confirmed."; fi
  echo "Plugin: $(plugin_summary "$plugin_state" "$plugin_note")"
  echo ""
  local plugin_name="Figma MCP Server for Claude"
  local code="" copied=false shown=false paired_before=false
  if [[ -s "$data_dir/bridge-token" ]]; then
    code="$(tr -d '[:space:]' <"$data_dir/bridge-token")"
    if [[ "$code_created" == true ]]; then
      # Shown and copied only when this run made the code, on a terminal: output that is piped or logged
      # shouldn't carry it. Not copied over the plugin path copied above: repeat and agent runs leave the
      # clipboard alone (figma_ensure_ready copies the code, at most every 10 minutes).
      if [[ -t 1 ]]; then
        shown=true
        if [[ "$manifest_copied" != true && "${FIGMA_INSTALL_NO_OPEN:-}" != "1" ]] &&
          printf '%s' "$code" | pbcopy 2>/dev/null; then copied=true; fi
      fi
    else
      paired_before=true
    fi
  fi
  case "$plugin_state" in
    imported | already | added) ;;
    *)
      # Not in Figma yet: the Claude-side route stays on offer next to the manual steps below.
      echo "Next: in Claude, ask \"Is Figma connected?\" (it runs figma_ensure_ready), or ask it to run"
      echo "figma_canvas_setup for where the Figma plugin is and how to import it into Figma desktop."
      echo ""
      ;;
  esac
  if [[ "$paired_before" == true ]]; then echo "Connect Figma:"; else echo "Connect Figma (one time):"; fi
  case "$plugin_state" in
    manual)
      echo "  0. Import the plugin first: Plugins → Development → Import plugin from manifest… and choose $plugin_manifest"
      ;;
    skipped)
      if [[ -f "$plugin_manifest" ]]; then
        echo "  0. Import the plugin first: Plugins → Development → Import plugin from manifest… and choose $plugin_manifest"
      else
        echo "  0. Import the plugin first (ask Claude to run figma_canvas_setup for where it is and how to import it)."
      fi
      ;;
    added)
      if [[ "${quit_by_us:-false}" == true ]]; then
        echo "  Figma hasn't loaded the plugin yet; give it a moment or check with --status."
      else
        echo "  Reopen Figma first, so it loads the plugin."
      fi
      ;;
  esac
  if [[ "$paired_before" == true ]]; then
    echo "  A pairing code already exists: open a file and start the plugin via Plugins → Development → $plugin_name, or click \"Reconnect Claude\"."
    echo "  If Figma asks for it, ask Claude \"Is Figma connected?\" and it will put the code on your clipboard."
  else
    echo "  1. In Figma desktop, open any file."
    echo "  2. Choose Plugins → Development → $plugin_name."
    if [[ "$shown" == true && "$copied" == true ]]; then
      printf '  3. In the window that opens, paste the pairing code (⌘V): %b%s%b\n' "$BLUE" "$code" "$NC"
    elif [[ "$shown" == true ]]; then
      printf '  3. In the window that opens, enter this pairing code: %b%s%b\n' "$BLUE" "$code" "$NC"
    else
      echo "  3. In the window that opens, paste or enter the pairing code; ask Claude \"Is Figma connected?\" and it will put the code on your clipboard."
    fi
    echo "Next time: click \"Reconnect Claude\" in the file's right-hand panel, or press ⌥⌘P (Run last plugin)."
  fi
  if [[ "$is_default" == true ]]; then
    echo "To check the state: run the same command with --status."
  else
    printf 'To check the state: run the same command with --status (keep --dir %s).\n' "$q_dir"
  fi
  if ! token_present; then echo "No Figma token is saved yet: ask Claude to run figma_set_token, or run this installer with --token."; fi
  if [[ "$is_default" == true ]]; then
    echo "To update later, run the same command again."
  else
    printf 'To update later, run the same command again with --dir %s\n' "$q_dir"
  fi
  echo ""
}

main "$@"
