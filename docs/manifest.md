# Manifest reference

Extensions declare identity and integration surfaces in a JSON manifest loaded by
`core.lib.ExtensionManifest`.

```text
<root>\<name>.manifest.json    beside <root>\<name>.lua
<root>\<name>\manifest.json    inside a folder extension
```

## Example

```json
{
  "schema_version": 2,
  "id": "example",
  "name": "Example",
  "version": "1.0.0",
  "description": "Example Lunar extension.",
  "platforms": ["windows", "linux"],
  "host_api": 2,
  "capabilities": ["tabs", "settings"],
  "provides": {
    "tabs": ["Example"],
    "settings": ["Example"]
  }
}
```

## Fields

| Field | Type | Required | Notes |
|---|---|---|---|
| `schema_version` | number | no | `1` or `2` (default `1`). `platforms` and `host_api` need `2`, so a host too old to understand them rejects the manifest instead of ignoring them. |
| `id` | string | no | Lowercase letters, digits, `.`, `_`, `-`. Derived from the file or folder name when omitted. Must be unique across loaded extensions. |
| `name` | string | yes* | Display name. Falls back to the discovered default name. |
| `version` | string | yes* | Shown in the Help menu. Falls back to the extension table's `version`. |
| `description` | string | no | Free text. |
| `group` | string | no | Default tab group for this extension's tabs, e.g. `"Diagnostics"`. Use `/` to nest: `"Tools/Parsers"`. Advisory — see below. |
| `capabilities` | array of strings | no | Integration surfaces the extension uses, e.g. `tabs`, `settings`, `menus`, `routes`. |
| `provides` | object of string arrays | no | What the extension contributes per capability, e.g. `{"tabs": ["Example"]}`. |
| `platforms` | array of strings | no | Schema 2. `windows`, `linux`, `macos`. Omitted means all. On any other platform the extension is skipped before its code runs; Help > Window Diagnostics lists it with the reason. |
| `host_api` | integer | no | Schema 2. The oldest host API the extension needs (default `1`). This host provides `2`: `1` plus `ctx:registerTheme` and `ctx:registerFont`. A newer requirement is reported as a load error asking the user to update Lunar. |

\* Required unless the value can be derived from the discovery defaults or from
`id`, `name`, and `version` fields on the returned extension table.

`group` is a **default, not a constraint**. The host applies it the first time it
sees a tab and records the result; from then on the user's own arrangement wins,
so moving the tab elsewhere is not undone on the next launch. A group created
this way is also removed automatically once it holds nothing, unlike one the user
made by hand. Individual tabs can override the manifest value with
`ctx:addTab(title, widget, owner, { group = "Elsewhere" })`. See
[Tab groups](tab-groups.md).

Two read-only fields are added by the loader and are visible through
`HostAPI:getManifest`:

| Field | Meaning |
|---|---|
| `manifest_path` | Path the manifest was loaded from. |
| `manifest_source` | `"file"` when a manifest was found, `"implicit"` when identity was synthesized. |

## Validation errors

Validation is strict and reported in the app when it fails:

- `manifest must decode to an object`
- `unsupported manifest schema_version <n> (expected 1)`
- `manifest id must contain only lowercase letters, digits, '.', '_' or '-'`
- `manifest name is required`
- `manifest version is required`
- `capabilities must be an array of strings`-style errors from the array
  normalizer, and `provides must be an object`
- `duplicate extension id: <id>` from `HostAPI:registerExtension`

## Ids and routing

The manifest `id` is also the routing target: `lunar://plugin/<id>` activates the
extension's first tab, and `lunar://plugin/<id>/<action>` invokes a handler
registered with `HostAPI:registerRouteHandler`. Choose a stable id — changing it
breaks saved addresses.

## Runtime merge

`ExtensionManifest.mergeRuntime` reconciles the manifest with the loaded
extension table: `id`, `name`, and `version` set on the extension table win over
the manifest defaults, and the merged manifest is written back to
`ext.manifest`. Use this to keep a single source of truth for versions in
subclass-based extensions.
