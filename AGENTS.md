# AGENTS.md - AI / Developer Reference for smooth-scroll.nvim

## Project Overview

A Neovim plugin that provides smooth, animated scrolling for all major scroll
motions. Written in Lua, targeting Neovim 0.10+.

## Key Architectural Decisions

### Screen-line scrolling (not buffer lines)

This is the most important design constraint. ALL scrolling is implemented in
terms of **screen lines** (i.e., what the user visually sees), not buffer lines.
This correctly handles soft-wrapped lines and folded regions.

- **Viewport scrolling**: `<C-e>` / `<C-y>` (each scrolls 1 screen line)
- **Cursor movement**: `gj` / `gk` (each moves 1 screen line)
- Executed via `vim.cmd.normal({ args, bang = true })` to avoid remapping

Which commands are used depends on `scroll_mode`:
- `scroll_mode = "cursor"` (**cursor-led**): only `gj`/`gk`. Neovim scrolls
  the viewport automatically when `scrolloff` is reached.
- `scroll_mode = "viewport"` (**viewport-only**): only `<C-e>`/`<C-y>`. No
  drift correction — the cursor stays on the same buffer line. Used by
  `zt`/`zz`/`zb`. When the viewport hits a buffer boundary (top or bottom),
  remaining lines automatically fall back to cursor movement (`gj`/`gk`) so
  the cursor continues toward the buffer edge instead of halting.
- `scroll_mode = "both"` (**viewport-led with drift correction**):
  `<C-e>`/`<C-y>` scrolls the viewport; `gj`/`gk` drift correction keeps the
  cursor pinned at its original screen-line position (winline).

**Why not `winrestview()`?** `winrestview({ topline = N })` operates at
buffer-line granularity only -- it cannot position the viewport at a specific
wrapped sub-line within a buffer line.

### Variable lines per tick, variable timing

Each timer tick scrolls one or more screen lines. When the total line count fits
within the frame budget (`max_fps`), each tick scrolls exactly 1 line. When
the distance exceeds the budget, lines are distributed across ticks using the
easing curve so that each tick may scroll multiple lines.

Easing controls the **interval between ticks**. The easing curve's inverse
derivative determines per-step weights, which are normalised so that intervals
always sum to exactly `duration` ms — duration is authoritative.

`compute_intervals()` in `scroller.lua` returns two parallel arrays:
`intervals` (ms per tick) and `lines_per_tick` (screen lines to scroll in that
tick). `max_fps` (clamped to [1, 250]) determines the maximum number of frames:
`max_frames = floor(duration_ms * max_fps / 1000)`.

### Single reused one-shot timer

One `vim.uv.new_timer()` is created for the plugin's lifetime. It is
stopped/restarted per animation. This avoids GC pressure from creating timers on
every scroll.

The timer is intentionally used as a **one-shot chain**, not a repeating timer:
each tick schedules the next tick only after the current tick has completed. This
prevents libuv timer firings from building up a backlog of `vim.schedule()`d
callbacks while Neovim is busy processing animation work or user input. The
animation also stops immediately after the last scheduled step rather than
waiting for an extra timer interval.

Each animation gets a monotonically increasing token. Scheduled callbacks capture
that token and no-op if it no longer matches the active animation. This protects
new animations from stale callbacks that were already scheduled before an
interruption or direction change.

### Interruption behaviour

Controlled by the `interrupt_behaviour` option (`"cancel"` or `"accumulate"`).

- `"cancel"` (default): a new scroll input stops the current timer and starts a
  fresh animation from the current viewport position. Remaining distance is
  discarded. No queuing or blending.
- `"accumulate"`: when the new scroll is in the **same direction** as the
  running animation, unscrolled lines from the cancelled animation are added to
  the new one (clamped to `MAX_ACCUMULATE_LINES` in `scroller.lua`, default
  200). Opposite-direction scrolls still cancel normally. This is the default
  for scroll-wheel keymaps so that rapid wheel input builds momentum instead of
  restarting from scratch each time.

### Peek-and-animate strategy

For target-based motions (zt, zz, zb), the plugin:

1. Saves the current view (`winsaveview()`)
2. Executes the native command to find the target position
3. Measures the topline delta
4. Restores the original view
5. Animates the delta using screen-line scrolling
6. On completion, re-executes the native command for exact final positioning

This is implemented in `scroller.scroll_to_target()`.

### Winline drift correction

When `scroll_mode = "both"` (viewport-led with drift correction),
`<C-e>`/`<C-y>` can cause the cursor's screen-line position (`winline()`) to
drift from its original value. After each tick, `winline()` is checked against
`expected_winline`. Drift can occur due to:

- Cursor on topline being pushed down by `<C-e>`
- Buffer end where `<C-e>` is a no-op
- `scrolloff` adjustments
- Folds expanding/collapsing

Correction is done with `gj`/`gk` commands, max 3 per tick.

When `scroll_mode = "cursor"` (cursor-led), no drift correction is performed —
the cursor moves intentionally via `gj`/`gk` and Neovim handles viewport
scrolling automatically through `scrolloff`.

When `scroll_mode = "viewport"` (viewport-only), no drift correction is
performed — the cursor stays on the same buffer line while only the viewport
moves.

**Note**: Drift is NOT primarily caused by soft wrapping. Both `<C-e>`/`<C-y>`
and `gj`/`gk` each individually handle wrapping correctly.

### Cross-window scrolling (`win` option)

The `win` option (per-call only, in `SmoothScrollOpts`) allows scrolling a
window other than the current one. Key design points:

- `win` accepts a window handle (`integer`). `0` or `nil` means current window.
- When `win` refers to a non-current window, `scroll_mode` is **forced to
  `"viewport"`** — we never move the cursor in a window we don't own.
- All window-dependent operations in the tick loop are wrapped in
  `vim.api.nvim_win_call(win, fn)` so they execute in the target window's
  context.
- Window validity is checked each tick (`nvim_win_is_valid`); if the window has
  been closed, the animation stops immediately.
- `scroll_to_target()` also wraps its peek operations (winsaveview, native cmd,
  winrestview) and `on_complete` callback in `nvim_win_call`.
- The tick function is split into `tick_inner(anim)` (pure window-dependent
  logic returning `(finished, on_complete)`) and `tick()` (dispatches to
  `tick_inner` directly for current window, or via `nvim_win_call` for
  non-current windows).

### Event suppression

During animation, `WinScrolled` and `CursorMoved` events are optionally
suppressed via `eventignore` to avoid triggering autocmds on every tick. This is
restored after animation completes (including on interruption).

## File Structure

```
lua/
  smooth-scroll/
    init.lua                  -- Public API (setup, motion functions, keymaps)
    config.lua                -- Config types, defaults, merge logic
    scroller.lua              -- Core animation engine (timer, tick, intervals)
    easing.lua                -- Easing functions (5 built-in)
```

### Module Responsibilities

- **init.lua** (public API): `setup()`, 9 motion functions, `scroll()`,
  `scroll_fraction()`, `stop()`, `is_scrolling()`, keymap wiring. This is what
  users interact with.

- **config.lua**: Defines `SmoothScrollConfig`, `SmoothScrollOpts`,
  `SmoothScrollKeymap` types. Provides `setup()` for merging user config with
  defaults, and `resolve()` for per-call option overrides. Default keymaps live
  here.

- **scroller.lua**: The animation engine. Manages `SmoothScrollAnimationState`
  (includes `win` field for cross-window support), computes easing-based
  intervals, handles `scroll_one_line()`, drift correction, boundary detection,
  and the `scroll_to_target()` peek-and-animate strategy. `tick_inner()` is the
  pure window-dependent tick logic; `tick()` dispatches to it directly or via
  `nvim_win_call()` for non-current windows. Contains the single reused `vim.uv`
  timer.

- **easing.lua**: Pure functions. 5 easing curves (`linear`, `ease_out_quad`,
  `ease_out_cubic`, `ease_in_out_quad`, `ease_in_out_cubic`). Lookup table +
  `resolve()` to accept name strings or custom functions.

## Type Annotations

All modules use LuaLS-style annotations (`@class`, `@alias`, `@param`,
`@return`, `@type`, `@private`, `@module`). These provide IDE support and serve
as documentation.

## Important Implementation Details

### Timer callbacks

`vim.uv.new_timer()` callbacks run in a libuv "fast" context. ALL Neovim API
calls inside timer callbacks MUST be wrapped with `vim.schedule_wrap()`.

### Boundary detection

`at_boundary()` checks if the scroll tick had any effect. In cursor-led mode
(`scroll_mode = "cursor"`), it compares cursor position (line + col) before and
after `gj`/`gk`. In viewport-led modes (`scroll_mode = "viewport"` or
`"both"`), it compares `topline` before and after `<C-e>`/`<C-y>`. In `"both"`
and `"cursor"` modes, a boundary means the animation stops early. In
`"viewport"` mode, a viewport boundary triggers a fallback: the
`viewport_at_boundary` flag is set on the animation state, and remaining lines
(in the current tick and all subsequent ticks) are scrolled via cursor movement
(`gj`/`gk`) instead. The animation only truly stops when the cursor itself
can no longer move.

**Bottom boundary detection**: When scrolling down in `"viewport"` mode,
`<C-e>` can continue advancing `topline` long after the last buffer line is
visible, filling the screen with `~` lines. To prevent this, after each
`<C-e>`, if the last buffer line is within the window (`line("w$") >=
last_buf_line`), the number of empty `~` lines below it is computed using
`screenpos()` and `getwininfo()`. When `empty_below >= viewport_bottom_margin`,
the `viewport_at_boundary` flag is set and remaining lines fall back to cursor
movement. `viewport_bottom_margin` defaults to `nil` (uses the window's
`scrolloff`); it can be overridden per-keymap or per-call.

### Default keymaps

| Key                | Motion              | Modes     |
|--------------------|---------------------|-----------|
| `<C-d>`            | half_page_down      | n, x      |
| `<C-u>`            | half_page_up        | n, x      |
| `<C-f>`            | page_down           | n, x      |
| `<C-b>`            | page_up             | n, x      |
| `zt`               | center_top          | n         |
| `zz`               | center              | n         |
| `zb`               | center_bottom       | n         |
| `<ScrollWheelDown>` | scroll_wheel_down  | n, x, i   |
| `<ScrollWheelUp>`   | scroll_wheel_up    | n, x, i   |

Keymaps can be disabled by setting them to `false` in config.

### Config defaults

- `duration`: `fun(lines) return lines * 12 end` (scales with distance)
- `easing`: `"ease_in_out_quad"`
- `max_fps`: 60
- `scroll_mode`: `"cursor"`
- `disable_events`: true
- `mouse_wheel_lines`: 3
- `interrupt_behaviour`: `"cancel"`
- `viewport_bottom_margin`: `nil` (uses window's `scrolloff`)

## Testing Notes

- Syntax has been validated with LuaJIT (`luajit -bl <file>`).
- No automated tests exist yet.
- To test manually: add to Neovim's runtimepath and call
  `require('smooth-scroll').setup()`.

## Common Tasks

### Adding a new motion

1. Add the function to `init.lua` (follow the pattern of existing motions)
2. Add an entry to `motion_map` in `init.lua`
3. Add a default keymap in `config.lua`'s `M.defaults.keymaps`

### Adding a new easing function

1. Add the function to `easing.lua`'s `M.functions` table
2. Add the name to the `SmoothScrollEasingName` alias

### Modifying scroll behavior

The core logic is in `scroller.lua`. Key entry points:
- `compute_intervals()` for timing
- `tick()` for per-step behavior
- `scroll_one_line()` for the atomic scroll operation
- `correct_drift()` for winline drift handling
