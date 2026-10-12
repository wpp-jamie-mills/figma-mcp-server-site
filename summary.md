# Figma MCP Server

**Let Claude Desktop read, comment on, and draw in your Figma files. It runs locally on your Mac.**

Version **2.7.4** · macOS · Claude Desktop extension · 40 tools

Ask Claude about a design and it reads the real file. Ask it to build something and it appears in Figma while you watch. Figma MCP Server connects Claude Desktop to Figma: it reads files through the Figma API, and it draws, edits, componentises and animates in the file you have open through a small paired Figma plugin.

- [Install: for people](#install-for-people)
- [Install: for AI agents](#install-for-ai-agents)
- [Why use it](#why-use-it)
- [What you can do](#what-you-can-do)
- [Tools](#tools)
- [Security and privacy](#security-and-privacy)
- [Troubleshooting](#troubleshooting)

---

## Install: for people

Open Terminal and run:

```bash
curl -fsSL https://wpp-jamie-mills.github.io/figma-mcp-server-site/install.sh | bash
```

Then:

1. If no token is saved yet, paste your Figma personal access token into the secure prompt (it goes straight to your macOS Keychain), then click Install in the dialog Claude Desktop opens.
2. Ask Claude: "Is Figma connected?" It runs `figma_ensure_ready`, which checks your token and the Figma plugin and tells you the one next step.
3. For the drawing tools (Figma Desktop needed), follow that next step (the drawing setup steps below have the details).

**Heads up:** The installer may need to quit and reopen Figma and Claude Desktop. It asks first each time, so save your work in both.

Token scopes: Create the token at https://www.figma.com/settings/tokens and give it only these scopes: `current_user:read` (`figma_whoami`), `file_content:read` and `file_metadata:read` (reading files, nodes and images), `file_versions:read` (version history), `file_comments:read` and `file_comments:write` (comments), `library_content:read` (components and styles), `projects:read` (projects and files) and `file_variables:read` (variables, which need a Figma Enterprise plan).

You need macOS and Claude Desktop. You don't need Node.js, npm or git. To update later, run the same command again (with the same `--dir`, if you used one).

## Install: for AI agents

Use these steps if you are an AI agent installing this for a user. The installer may need to quit and reopen Figma and Claude Desktop. It asks first each time, so save your work in both.

1. **Check the machine.** Continue only if `uname -s` prints `Darwin` and `/Applications/Claude.app` exists. Otherwise tell the user it needs macOS with Claude Desktop installed.
2. **Run the installer** with this one command. It downloads the extension, checks its SHA-256, opens Claude Desktop's install dialog, and imports the plugin into Figma Desktop. It needs no other tools. `FIGMA_INSTALL_TTY=/dev/null` means there is no terminal: the installer never quits or restarts an app and answers no to every question. `--no-wait` makes it exit 0 once the dialog is open instead of waiting for the user to click **Install**. With no terminal or `--no-wait` it never opens the Figma token prompt (a dialog that waits for a person), so the command returns quickly; if no token is saved it says so, and the token is saved afterwards by `figma_set_token` or by the user running the installer with `--token`. Exit 0 means the installer finished its steps, not that Claude Desktop installed the extension: confirm with `--status`. It exits non-zero, with the reason on stderr, if anything fails before the dialog opens; if Claude Desktop can't be opened it prints how to open the downloaded file instead.

   ```bash
   curl -fsSL https://wpp-jamie-mills.github.io/figma-mcp-server-site/install.sh | FIGMA_INSTALL_TTY=/dev/null bash -s -- --no-wait
   ```

   To keep its data somewhere other than `~/.figma-mcp-server`, add `--dir "<absolute path>"` after `--no-wait`, and tell the user to choose the same folder in the dialog's **Data folder** field. If Claude Desktop already lists this version and you use the default data folder, the installer skips the dialog and says so. With `--dir` the dialog still opens so the Data folder can be set; the installer then says to finish the dialog and prints the `--status` command to run afterwards.

   If Figma is open and the plugin isn't imported yet, the installer leaves Figma alone and says how to finish. Ask the user whether Figma may be quit and reopened (they should save their work first). Only after they say yes, run the same command again with `--allow-figma-restart` added after `--no-wait`: that flag only answers yes to the Figma question and never restarts Claude Desktop. Otherwise the user imports the plugin by hand (Plugins → Development → Import plugin from manifest…, as the installer prints). After an upgrade the installer tells the user to restart Claude Desktop themselves; never quit Claude Desktop from inside Claude Desktop.

3. **Hand over to the user.** The installer opens Claude Desktop's install dialog. Ask the user to click **Install**, then confirm with `--status`. If no token is saved, call `figma_set_token` (a secure prompt that goes straight to the Keychain), or have the user run the installer with `--token`. They can create a token at https://www.figma.com/settings/tokens. Never ask for the token in chat, and never write it to a file or a command line.
4. **Verify.** Run the installer with `--status`, or read `~/.figma-mcp-server/status.json`; neither contains the token. Inside Claude Desktop, one call to `figma_ensure_ready` reports the version, token, plugin state and the next step. If the token is missing, call `figma_set_token`.
5. **Drawing (optional).** The installer imports the plugin. Call `figma_ensure_ready`: it copies the pairing code to the clipboard. The user opens any file in Figma, chooses Plugins → Development → Figma MCP Server for Claude, pastes the pairing code (⌘V) in the window that opens, and starts the plugin each session with one click (Reconnect Claude in the file's right-hand panel once the plugin has run in that file, or ⌥⌘P).

| Fact         | Value                                                                                                                                       |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------------------- |
| Platform     | macOS with Claude Desktop                                                                                                                   |
| Form         | Claude Desktop extension (`.mcpb`), local stdio MCP server                                                                                  |
| Tools        | 40: 13 read, 20 canvas, 7 animation                                                                                                             |
| Token        | macOS Keychain only (service `figma-mcp-server`, account `figma`), saved from a hidden-input prompt                                         |
| Data folder  | `~/.figma-mcp-server` by default: plugin files, pairing code, session token, status.json                                                    |
| Local bridge | Server binds `127.0.0.1:3055` only; the plugin connects to `ws://localhost:3055` (the name Figma requires); paired with an 8-character code |
| Update       | Run the same command again (with the same `--dir`, if one was used)                                                                         |

## Why use it

- **Grounded in the real file.** Claude reads actual layers, text, components, variables, comments and version history, not a screenshot or a description.
- **From conversation to canvas.** Describe a layout, a component or an animation and Claude builds it in the open file, with live updates your collaborators see too.
- **Design-system aware.** Claude can audit published components and styles, turn layers into components, add component properties and place instances.
- **Motion included.** Keyframes, built-in animation styles, timelines and path animation, where your Figma plan supports motion.
- **Local and private by design.** The server runs on your Mac. The local bridge only listens on your own machine and needs a pairing code, and your token stays in your Keychain.
- **One command to install, one to update.** No developer tools, no config files.

## What you can do

**Read files** (no Figma Desktop needed). Claude can read any file your token can access: list projects and files, export layers as PNG, JPG, SVG or PDF, read components, styles and variables, see version history and comments, and post comments. You need a [Figma personal access token](https://www.figma.com/settings/tokens).

**Draw and edit** (needs Figma Desktop and a one-off pairing). Claude can create, edit, group, move, clone and delete layers, import SVG, work with components and instances, and add animations.

Try asking:

```
"List my Figma projects"
"Export the 'Hero' frame from [file URL] as PNG"
"What components does our design system have?"
"Post a comment: 'Looks good!' on this file"
"Create a rectangle 200×100 at position 50,50"
"Group these layers into a 'Header' frame"
```

Paste a Figma file URL or give a file key and Claude does the rest. Figma's API can't list your teams, so give a team ID (the number after `/team/` in a team page URL) or paste file URLs directly.

### Setting up drawing in Figma

1. The installer imports the plugin into Figma for you. It only asks to quit and reopen Figma when Figma is open and the plugin isn't imported yet.
2. In Figma desktop, open any file.
3. Choose Plugins → Development → Figma MCP Server for Claude.
4. In the window that opens, paste the pairing code (⌘V). The installer copies it to your clipboard (format `XXXX-XXXX`) when it creates it. If it isn't on your clipboard, ask Claude "Is Figma connected?": it runs `figma_ensure_ready`, tells you what's missing and copies the code. The plugin connects straight away and shrinks to a "Connected to Claude" strip.
5. Next time, click **Reconnect Claude** in the file's right-hand panel (it appears in files where the plugin has already run; in a new file use Plugins → Development → Figma MCP Server for Claude), or press ⌥⌘P (Run last plugin). Keep the plugin window open while Claude works.

Figma remembers the code, so pairing is a one-off. The code is kept in `<data folder>/bridge-token`. If the import didn't work, `figma_canvas_setup` (or `install.sh --status`) shows where the plugin files are.

## Tools

### Read tools

| Tool | What it does |
|---|---|
| `figma_whoami` | Return the Figma user the configured access token belongs to (handle, email). |
| `figma_list_projects` | List the projects in a Figma team. |
| `figma_list_files` | List the files in a Figma project, most recently modified first, with their file keys and URLs. |
| `figma_get_file` | Get a Figma file's metadata and page/frame outline. depth 1 = pages only, 2 = pages + top-level frames (default), 3+ = deeper layers (can be large). |
| `figma_get_nodes` | Get the layer tree for specific frames/layers: names, types, sizes, text content, fonts, fills, auto-layout. |
| `figma_export_images` | Render frames or layers to PNG, JPG, SVG or PDF. |
| `figma_get_comments` | List comments on a Figma file, newest first, threaded, with author, date, resolved state and the node they're pinned to. |
| `figma_post_comment` | Post a comment on a Figma file as the token's owner — visible to everyone with access. |
| `figma_get_components` | List the published components, component sets and styles (colour, text, effect, grid) in a file — useful for auditing a design system or library. |
| `figma_get_variables` | List variable collections, modes and variables (design tokens) defined in a file, with resolved values per mode. |
| `figma_get_versions` | List a file's version history (named versions and autosaves): who, when, label and description. |
| `figma_set_token` | Open a native macOS prompt where the user pastes their Figma personal access token (figd_…). |
| `figma_ensure_ready` | Report whether Figma and the canvas plugin are ready, and the one next step. |

### Canvas tools (create and edit)

| Tool | What it does |
|---|---|
| `figma_canvas_status` | Check whether the Figma MCP Server for Claude plugin is connected, and to which file and page. |
| `figma_canvas_get_nodes` | List layers in the file open in Figma: the current page's top-level nodes, a node's children (parent_id), or the current selection (selection=true). |
| `figma_canvas_set_page` | Switch to a page by name or id, creating it if create=true and it doesn't exist. |
| `figma_canvas_create` | Create a FRAME, RECTANGLE, ELLIPSE, LINE or TEXT node on the current page or inside parent_id, with properties applied (position, size, fill, stroke, radius, auto layout, text and font). |
| `figma_canvas_update` | Change properties of one or more existing layers (same property set as figma_canvas_create). |
| `figma_canvas_import_svg` | Draw an SVG on the canvas as editable layers (vectors, groups and text). |
| `figma_canvas_delete` | Delete layers by id. |
| `figma_canvas_group` | Wrap layers in a group (as='group') or a frame sized to their bounds (as='frame'). |
| `figma_canvas_ungroup` | Ungroup groups (like ⇧⌘G), or dissolve frames, keeping each child's position and stacking place in the parent. |
| `figma_canvas_get_text_styles` | Read the font, size and enabled OpenType features (e.g. SS01, LIGA) of text layers, run by run. |
| `figma_canvas_screenshot` | Render a layer (or the current selection) as a PNG and return it inline, so you can check what was drawn. |
| `figma_canvas_focus` | Select layers and scroll/zoom the Figma viewport to them so the user can see them. |
| `figma_canvas_make_component` | Convert an existing frame or group into a main component in place (like ⌥⌘K). |
| `figma_canvas_add_component_property` | Add a TEXT, BOOLEAN or INSTANCE_SWAP property to a main component and bind it to layers inside it: TEXT → a text layer's characters, BOOLEAN → a layer's visibility, INSTANCE_SWAP → a nested instance's main component (default_value is then a component id). |
| `figma_canvas_create_instance` | Create an instance of a component, either at x,y in a parent (default: current page), or in place of an existing layer (replace_id: same parent, position and stacking order; the replaced layer is deleted). |
| `figma_canvas_set_instance_properties` | Set component property values on an instance by property name, e.g. {"Headline": "Autumn, unhurried", "Image": "<component id>"}. |
| `figma_canvas_clone` | Duplicate a layer (⌘D), optionally into another parent and position. |
| `figma_canvas_move` | Re-parent a layer (parent_id, or page by name/id, created if missing) and/or change its stacking. |
| `figma_canvas_rescale` | Scale a layer and everything in it proportionally (like the K scale tool), e.g. 1.8 to enlarge a scene illustration. |
| `figma_canvas_setup` | Step-by-step instructions to connect Figma to this server: where the plugin files are, how to import it, and how to get the pairing code. |

### Animation tools (Figma Motion required)

| Tool | What it does |
|---|---|
| `figma_canvas_motion_status` | Check whether Figma's motion (timeline/keyframe) API is enabled for this account, read a layer's frame timeline, and list Figma's built-in animation styles. |
| `figma_canvas_set_keyframes` | Add manual keyframe tracks to one or more layers (not top-level frames — animate their children). |
| `figma_canvas_get_motion` | Read a layer's manual keyframe tracks, applied animation styles and its frame's timeline. |
| `figma_canvas_clear_motion` | Remove all keyframe tracks and animation styles from layers (the layers themselves are untouched). recursive=true also clears everything inside them, e.g. pass a frame id to strip a whole slide. |
| `figma_canvas_follow_path` | Move a layer's centre along a vector path between start and end seconds (e.g. a dot leading a connector line as it draws). |
| `figma_canvas_set_timeline` | Set the duration (seconds) of the timeline of the top-level frame containing a layer. |
| `figma_canvas_apply_animation_style` | Apply one of Figma's built-in animation styles (names from figma_canvas_motion_status, e.g. Fade) to a layer, with duration, timeline offset and style props (e.g. {timing:'in', easing:{type:'EASE_OUT'}}). |

## Security and privacy

- The bridge listens on `127.0.0.1:3055` only, so only your Mac can reach it. The plugin connects to `ws://localhost:3055` because Figma's plugin rules require that name; it reaches the same local address, and the server never binds any other.
- Connections carrying a web-page origin are refused. A sandboxed page can still connect (it looks like the plugin), so the pairing code is what protects the bridge.
- The plugin must present a pairing code (`XXXX-XXXX`) stored in `<data folder>/bridge-token`, readable only by you. Code checks are paced to 4 per second in total and never lock you out. Unpaired connections are capped at 16 (idle ones are dropped first), limited to 4 KB per message, and closed after 10 seconds. After the first pairing, the plugin reconnects with a long random session token (`<data folder>/bridge-session`) that skips the queue, so a hostile page on your Mac flooding connections can no longer block it. A first pairing made while such a page is running can still stall.
- Your Figma token lives only in the macOS Keychain, saved from a hidden-input prompt; it never goes through chat, command-line arguments or files. Give it only the scopes you need and revoke it at https://www.figma.com/settings/tokens.
- The installer's SHA-256 check catches a corrupted or partial download, not a compromised site: the checksum and the installer are served from the same site. Read `install.sh` before running it if that matters to you.
- Canvas edits appear live to collaborators and can be undone with ⌘Z in Figma.

## Troubleshooting

- **"No Figma token found"**: ask Claude to run `figma_set_token`, or run the installer again with `--token`.
- **"The Figma plugin isn't connected"**: open the file in Figma Desktop, choose Plugins → Development → Figma MCP Server for Claude and keep its window open. If you haven't set it up yet, ask Claude to run `figma_canvas_setup`.
- **"The Figma plugin tried to connect but isn't paired"**: ask Claude "Is Figma connected?" (it runs `figma_ensure_ready` and copies the pairing code to your clipboard), then paste it (⌘V) in the plugin window.

---

<sub>Generated from the project README for version 2.7.4. It is rebuilt automatically when the features or install instructions change.</sub>
