---
applyTo: "**/*.js"
---

# Shopify Widget JavaScript Rules

- **ES5 only** — NO `let`/`const` (use `var`), NO arrow functions, NO template literals, NO destructuring
- **Module pattern**: always use `VR.register("name", function(ctx){ ... })` for new modules
- **Null-safe DOM**: check every `querySelector` result before use
- **Event bus**: `VR.on(event, cb)`, `VR.emit(event, data)`, `VR.state(key)`, `VR.state(key, val)`
- **Load order**: config → core → modules → monolith → landing → auth → start
