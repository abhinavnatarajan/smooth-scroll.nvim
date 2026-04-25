# smooth-scroll.nvim

Smooth, animated scrolling for Neovim. Supports all major scroll motions with
configurable easing, duration, and frame rate.

## Features

- Smooth animation for `<C-d>`, `<C-u>`, `<C-f>`, `<C-b>`, `gg`, `G`, `zt`,
  `zz`, `zb`, `n`, `N`, and mouse wheel scrolling
- Correct handling of soft-wrapped lines and folded regions (all scrolling
  operates on screen lines, not buffer lines)
- 5 built-in easing functions, or supply your own
- Per-motion overrides for duration, easing, and cursor behavior
- Interrupt-friendly: new scroll input cancels the current animation instantly
- Optional event suppression during animation to avoid autocmd noise
- Works in normal, visual, and insert modes (where applicable)

## Requirements

- Neovim >= 0.10

## Installation

### lazy.nvim

```lua
{
  "abhinavnatarajan/smooth-scroll.nvim",
  opts = {},
}
```

### packer.nvim

```lua
use {
  "abhinavnatarajan/smooth-scroll.nvim",
  config = function()
    require("smooth-scroll").setup()
  end,
}
```

### Manual

Add this repository to your Neovim runtimepath, then:

```lua
require("smooth-scroll").setup()
```

## Configuration

All options are optional. Shown below are the defaults:

```lua
require("smooth-scroll").setup({
  -- Animation duration in milliseconds
  duration = 250,

  -- Easing function: "linear", "ease_out_quad", "ease_out_cubic",
  -- "ease_in_out_quad", "ease_in_out_cubic", or a custom function(t) -> t
  easing = "ease_out_quad",

  -- Maximum frames per second (controls upper bound on tick rate)
  max_fps = 60,

  -- Scroll mode: "cursor" (cursor-led), "viewport" (viewport-only),
  -- or "both" (viewport-led with drift correction)
  scroll_mode = "cursor",

  -- Suppress WinScrolled/CursorMoved events during animation
  disable_events = true,

  -- Number of screen lines per mouse wheel scroll event
  mouse_wheel_lines = 3,

  -- Keymap overrides. Set a key to `false` to disable it.
  keymaps = {
    ["<C-d>"]            = { motion = "half_page_down",   modes = { "n", "x" } },
    ["<C-u>"]            = { motion = "half_page_up",     modes = { "n", "x" } },
    ["<C-f>"]            = { motion = "page_down",        modes = { "n", "x" } },
    ["<C-b>"]            = { motion = "page_up",          modes = { "n", "x" } },
    ["gg"]               = { motion = "to_top",           modes = { "n", "x" } },
    ["G"]                = { motion = "to_bottom",        modes = { "n", "x" } },
    ["zt"]               = { motion = "center_top",       modes = { "n" } },
    ["zz"]               = { motion = "center",           modes = { "n" } },
    ["zb"]               = { motion = "center_bottom",    modes = { "n" } },
    ["n"]                = { motion = "search_next",      modes = { "n" } },
    ["N"]                = { motion = "search_prev",      modes = { "n" } },
    ["<ScrollWheelDown>"] = { motion = "scroll_wheel_down", modes = { "n", "x", "i" } },
    ["<ScrollWheelUp>"]   = { motion = "scroll_wheel_up",  modes = { "n", "x", "i" } },
  },
})
```

### Per-motion overrides

Each keymap entry can include `duration`, `easing`, and `scroll_mode` to
override the global defaults for that specific motion:

```lua
keymaps = {
  ["<C-d>"] = {
    motion = "half_page_down",
    modes = { "n", "x" },
    duration = 400,
    easing = "ease_in_out_cubic",
  },
}
```

### Disabling keymaps

Set any keymap to `false` to prevent the plugin from binding it:

```lua
keymaps = {
  ["gg"] = false,
  ["G"] = false,
}
```
You can also set `keymaps = false` to disable all default keymaps if you prefer to call the API functions directly or set up your own bindings.

## API

The plugin exposes a Lua API for programmatic use:

```lua
local ss = require("smooth-scroll")

-- Scroll by an exact number of screen lines (positive = down)
ss.scroll(10)
ss.scroll(-5, { duration = 100 })

-- Scroll by a fraction of the window height (0.5 = half page)
ss.scroll_fraction(0.5)
ss.scroll_fraction(-0.25, { easing = "linear" })

-- Named motions (all accept optional per-call overrides)
ss.half_page_down()
ss.half_page_up()
ss.page_down()
ss.page_up()
ss.to_top()
ss.to_bottom()
ss.center_top()
ss.center()
ss.center_bottom()
ss.search_next()
ss.search_prev()
ss.scroll_wheel_down()
ss.scroll_wheel_up()

-- Control
ss.stop()              -- Cancel current animation
ss.is_scrolling()      -- Returns true if an animation is in progress
```

### Per-call options

All motion functions and `scroll()`/`scroll_fraction()` accept an optional
table with these fields:

| Field           | Type               | Description                              |
|-----------------|--------------------|------------------------------------------|
| `duration`      | `integer`          | Animation duration in ms                 |
| `easing`        | `string\|function` | Easing function name or custom `f(t)->t` |
| `max_fps`       | `integer`          | Maximum frame rate (clamped to [1, 250]) |
| `scroll_mode`   | `string`           | `"cursor"`, `"viewport"`, or `"both"`    |
| `on_complete`   | `function`         | Callback when animation finishes         |

## Custom Easing Functions

A custom easing function takes a number `t` in `[0, 1]` and returns a number in
`[0, 1]`:

```lua
require("smooth-scroll").setup({
  easing = function(t)
    -- Example: ease-out quartic
    return 1 - (1 - t) ^ 4
  end,
})
```

## How It Works

Each animation tick scrolls exactly one screen line using `<C-e>`/`<C-y>`
(viewport) and `gj`/`gk` (cursor). The easing function controls the **time
interval between ticks**, not the step size. This produces smooth 1-pixel-row
increments with natural acceleration/deceleration.

For target-based motions like `gg`, `G`, and `n`, the plugin uses a
"peek-and-animate" strategy: it executes the native command to discover the
target position, measures the distance, restores the original view, animates to
the target, then re-executes the command for exact final positioning.

## License

Please see the LICENSE file in the repository for license information.
