# Routing (`lunar://` addresses)

Lunar has an address bar. Every addressable location in the application is a
`lunar://` URI parsed and serialized by `core.lib.RouteUri` and dispatched by
`HostAPI:dispatchAddress`.

## Grammar

```text
lunar://host/<target>[/<action>][?key=value&...]
lunar://plugin/<id>[/<action>][?key=value&...]
```

- The authority must be `host` or `plugin`.
- Path segments and query keys are limited to letters, digits, `.`, `_`, `-`
  (after percent-decoding). Control characters are rejected.
- At most two path segments are allowed: target and action.
- Query values are percent-encoded; serialization sorts keys so the same route
  always produces the same URI.

## Host routes

Host tabs register a routing id with `HostAPI:registerHostTab`, so
`lunar://host/settings` activates the Settings tab. Host routes take no action
segment.

## Plugin routes

`lunar://plugin/<id>` activates the extension's first tab. With an action segment
the host also invokes the matching handler:

```lua
function M.register(ctx)
    ctx:registerRouteHandler("run", function(params, route)
        start_run(params.preset)
    end, M)

    -- Describe where the user currently is, so the address bar and "copy
    -- address" produce a URI that can be pasted back.
    ctx:registerRouteSerializer(function()
        return { action = "run", params = { preset = current_preset } }
    end, M)
end
```

`params` values are always strings.

## Dispatch results

`HostAPI:dispatchAddress` and `HostAPI:dispatchRoute` return `true, result` on
success, or `nil, { code, message }` on failure. Codes are stable identifiers:

| Code | Meaning |
|---|---|
| `malformed_route` / `invalid_route` | The URI failed to parse. |
| `unknown_route` / `unknown_host_target` / `unknown_plugin` | No such target. |
| `unknown_plugin_action` / `unknown_host_action` | The target has no such action. |
| `route_unavailable` / `host_target_unavailable` | The target exists but cannot be activated. |
| `dispatch_failed` / `route_handler_error` | The handler raised. |

## Reading the current address

- `HostAPI:currentAddress` returns a route table for the active tab.
- `HostAPI:currentAddressURI` returns the serialized `lunar://` string.
- `HostAPI:currentRoute` is the older serializer-based equivalent.

Extensions that do not register a serializer are still addressable at
`lunar://plugin/<id>`; they simply cannot express in-tab state.
