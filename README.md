# Roblox Executor MCP Server

An MCP server that bridges LLMs and a running Roblox Game Client — execute code, inspect scripts, spy on remotes, and more.

## Features

- **Code Execution & Data Querying** — Run Lua and fetch data from the game client.
- **Script Inspection** — Decompile LocalScripts/ModuleScripts and search across sources.
- **Instance Search** — CSS-like selectors via `QueryDescendants` and hierarchy trees.
- **Remote Spy** — [Cobalt](https://github.com/notpoiu/cobalt) integration to intercept, log, block, and ignore Remotes/Bindables.
- **Dex Explorer Full Control API** — [Dex](https://github.com/LorekeeperZinnia/Dex) Explorer/Properties/ScriptViewer/MainMenu read + write parity via action bus (`dex-bridge-2`).
- **Multi-Client** — Connect multiple Roblox clients simultaneously; target each by `clientId`. Dashboard at `http://localhost:16384/`.
- **Primary / Secondary** — Multiple MCP instances auto-coordinate; secondaries relay through the primary with automatic promotion.

## Prerequisites

- A Roblox executor supporting `loadstring`, `request`, and (preferably) `WebSocket`.
- Node.js ≥ 18.

## Quick Start

```bash
pnpm install && pnpm run build
```

### Add to your AI Client

**Cursor** — Settings > Features > MCP > Add: name `roblox-executor-mcp`, type `command`, command `node /path/to/MCPServer/dist/index.js`.

**Claude Desktop / Antigravity** — Add to your JSON config:
```json
{
  "mcpServers": {
    "roblox-executor-mcp": {
      "command": "node",
      "args": ["/path/to/MCPServer/dist/index.js"]
    }
  }
}
```

**Codex** — Add to your JSON config:
```json
[roblox-executor-mcp]
command = "npm"
args = ["/path/to/MCPServer/dist/index.js"]

```

**Codex** — Settings > MCP Settings > Add server: name `roblox-executor-mcp`, type `STDIO`, command `node`, args `/path/to/MCPServer/dist/index.js`.

### Connect from Roblox

Run `connector.luau` in your executor, or use the quick loader:
```lua
-- getgenv().BridgeURL = "10.0.0.4:16384" (defaults to localhost, change if needed)
-- getgenv().DisableWebSocket = true
loadstring(game:HttpGet("https://raw.githubusercontent.com/notpoiu/roblox-executor-mcp/refs/heads/main/connector.luau"))()
```

## Tools

| Category | Tool | Description |
|---|---|---|
| **Execution** | `execute` | Run Lua code (actions) |
| | `get-data-by-code` | Run Lua code and return results |
| **Scripts** | `get-script-content` | Decompile a script's source |
| | `search-scripts-sources` | Search all scripts by source content |
| **Introspection** | `list-clients` | List connected clients |
| | `get-console-output` | Retrieve console logs |
| | `search-instances` | CSS-like instance search |
| | `get-descendants-tree` | Instance hierarchy tree |
| | `get-game-info` | Game metadata |
| **Remote Spy** | `ensure-remote-spy` | Load Cobalt (required first) |
| | `get-remote-spy-logs` | Get captured remote call logs |
| | `clear-remote-spy-logs` | Clear all logs |
| | `block-remote` | Block/unblock a remote |
| | `ignore-remote` | Ignore/unignore a remote |
| **Dex Explorer (Read)** | `ensure-dex` | Load Dex from pinned release URL (prerequisite) |
| | `get-dex-status` | Dex loaded state, location, menu state, bridge state/version |
| | `get-dex-overview` | Load/menu/window/search/selection summary + bridge state |
| | `get-dex-selection` | Paginated current Dex selection snapshot |
| | `get-dex-explorer-tree` | Paginated Explorer tree snapshot (bridge + fallback) |
| | `search-dex-explorer` | Search Explorer by name/class/path with ancestor options |
| | `get-dex-properties` | Dex-style properties rows (instancePath first, else selection) |
| | `get-dex-script-viewer` | Script source from viewer/decompile/fallback |
| | `set-dex-menu-open` | Open/close Dex MainMenu (no unload) |
| **Dex Action Bus (Core)** | `dex-action` | Execute one low-level Dex action |
| | `dex-batch-actions` | Execute multiple Dex actions with stopOnError |
| | `dex-list-capabilities` | List supported actions and payload requirements |
| **Dex Task Tools (LLM-friendly)** | `dex-explorer-select` | Replace/add/remove/clear Explorer selection |
| | `dex-explorer-context-action` | Run Explorer context-equivalent actions |
| | `dex-explorer-move` | Reparent/move instances |
| | `dex-explorer-insert-object` | Insert object by class |
| | `dex-properties-set` | Set one property |
| | `dex-properties-set-batch` | Set multiple properties |
| | `dex-attributes-upsert` | Add/update one attribute |
| | `dex-attributes-remove` | Remove one attribute |
| | `dex-script-viewer-open` | Open script in Script Viewer |
| | `dex-script-viewer-export` | Export Script Viewer text (file/clipboard/raw) |
| | `dex-main-set-app-open` | Open/close Explorer/Properties/Script Viewer app |
| | `dex-settings-get` | Read Dex settings |
| | `dex-settings-set` | Update one Dex setting |
| | `dex-settings-reset` | Reset Dex settings to defaults |

Dex target resolution priority: `instancePath` first, then Dex `selectionIndex` (default `1`).

If bridge patching fails, read tools continue in fallback mode (`bridgeStatus=fallback|patch_failed`) with reduced fidelity.
Write/mutate actions require `bridgeStatus=ready` and return explicit `bridge_not_ready` when unavailable.

## Functional Parity Definition

`100% parity` means functional parity with built-in Dex `1.0.0` capabilities (Explorer/Properties/Script Viewer/Main Menu state and effects).  
Pixel-level animation parity is not in scope.

## Action Matrix

The low-level `DexAction` surface includes:

- Explorer selection/search/tree: `explorer.select.*`, `explorer.search.*`, `explorer.expand.all`, `explorer.collapse.all`, `explorer.jump_to_parent`, `explorer.select_children`
- Explorer context/mutate: `explorer.rename`, `explorer.cut`, `explorer.copy`, `explorer.paste_into`, `explorer.duplicate`, `explorer.delete`, `explorer.group`, `explorer.ungroup`, `explorer.reparent`, `explorer.insert_object`, `explorer.copy_path`, `explorer.call_function`, `explorer.get_lua_references`, `explorer.save_instance`, `explorer.view_connections`, `explorer.view_api`, `explorer.view_object`, `explorer.view_script`, `explorer.select_character`, `explorer.refresh_nil`, `explorer.hide_nil.toggle`, `explorer.teleport_to`
- Properties: `properties.select_target`, `properties.search.*`, `properties.set`, `properties.set_batch`, `properties.clear_value`, `properties.expand_category`, `properties.expand_property`, `properties.attributes.*`, `properties.sound_preview.*`
- Script Viewer: `script_viewer.open`, `script_viewer.get_text`, `script_viewer.copy_text`, `script_viewer.save_to_file`
- Main/Settings: `main.menu.set_open`, `main.app.set_open`, `main.window.focus`, `main.settings.get`, `main.settings.set`, `main.settings.reset`

## Security Note

This server allows arbitrary code execution in your Roblox client. Only use with trusted LLMs.
