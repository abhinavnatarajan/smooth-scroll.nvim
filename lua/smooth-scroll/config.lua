--- Configuration management for smooth-scroll.nvim
---
--- Provides a typed default configuration, a `setup()` function that deep-merges
--- user overrides, and a `resolve()` helper for merging per-call option tables at
--- runtime.
---
---@module "smooth-scroll.config"

---------------------------------------------------------------------------
-- Types
---------------------------------------------------------------------------

--- Scroll mode controls how the cursor and viewport behave during animation.
---
--- - `"cursor"`: cursor-led scrolling. Only `gj`/`gk` is used; Neovim scrolls
---   the viewport automatically when the cursor approaches `scrolloff`.
--- - `"viewport"`: viewport-only scrolling. Only `<C-e>`/`<C-y>` is used; the
---   cursor stays on the same buffer line. Used by `zt`/`zz`/`zb`.
--- - `"both"`: viewport-led scrolling with drift correction. `<C-e>`/`<C-y>`
---   scrolls the viewport and `gj`/`gk` drift correction keeps the cursor
---   pinned at its original screen-line position (winline).
---
---@alias SmoothScrollMode "cursor"|"viewport"|"both"

--- Interrupt behaviour controls what happens when a new scroll is triggered
--- while an animation is already in progress.
---
--- - `"cancel"`: the running animation is stopped and its remaining distance
---   is discarded.  The new scroll starts from scratch.
--- - `"accumulate"`: if the new scroll is in the **same direction** as the
---   running animation, any unscrolled lines from the cancelled animation are
---   added to the new one.  Opposite-direction scrolls still cancel normally.
---   The accumulated total is clamped to a developer-tunable maximum (see
---   `MAX_ACCUMULATE_LINES` in `scroller.lua`).
---
---@alias SmoothScrollInterruptBehaviour "cancel"|"accumulate"

--- Duration may be a fixed number of milliseconds or a function that receives
--- the total number of screen lines to scroll and returns the duration in
--- milliseconds.  Using a function allows the animation speed to scale with
--- distance.
---
---@alias SmoothScrollDuration integer|fun(lines: integer): integer

--- Per-keymap configuration entry.
---
--- Each entry maps a key sequence to a named motion function and optionally
--- overrides global settings for that particular binding.
---
---@class SmoothScrollKeymap
---@field motion string Name of the motion function (e.g. `"half_page_down"`).
---@field modes? string|string[] Vim mode(s) to create the mapping in. Defaults to `{ "n", "x" }`.
---@field duration? SmoothScrollDuration Override global `duration` for this keymap.
---@field easing? SmoothScrollEasingName|SmoothScrollEasingFn Override global easing for this keymap.
---@field scroll_mode? SmoothScrollMode Override global `scroll_mode` for this keymap.
---@field max_fps? number Override global `max_fps` for this keymap.
---@field disable_events? boolean Override global `disable_events` for this keymap.
---@field mouse_wheel_lines? number Override global `mouse_wheel_lines` for this keymap.
---@field interrupt_behaviour? SmoothScrollInterruptBehaviour Override global `interrupt_behaviour` for this keymap.
---@field viewport_bottom_margin? integer Override global `viewport_bottom_margin` for this keymap.

--- Full plugin configuration.
---
---@class SmoothScrollConfig
---@field duration SmoothScrollDuration Animation duration — either a fixed number of milliseconds or a `fun(lines): ms` that scales with distance.
---@field easing SmoothScrollEasingName|SmoothScrollEasingFn Easing function name or a custom `fun(t):number`.
---@field max_fps number Maximum frames per second — controls the upper bound on tick rate. Clamped to [1, 250].
---@field scroll_mode SmoothScrollMode Controls how cursor and viewport interact during scrolling. See `SmoothScrollMode`.
---@field disable_events boolean Whether to suppress `WinScrolled`/`CursorMoved` autocommands during animation.
---@field mouse_wheel_lines number Number of screen lines to scroll per mouse wheel event. Defaults to `3`.
---@field interrupt_behaviour SmoothScrollInterruptBehaviour Controls what happens when a new scroll interrupts a running animation. See `SmoothScrollInterruptBehaviour`.
---@field viewport_bottom_margin? integer Number of empty `~` lines below the last buffer line that triggers cursor-movement fallback in `"viewport"` scroll mode when scrolling down. `nil` (default) uses the window's `scrolloff` value.
---@field keymaps table<string, SmoothScrollKeymap|false> Map from key sequence to keymap config.  Set a value to `false` to disable a default keymap.

--- Per-call option overrides that may be passed to any scroll function.
---
---@class SmoothScrollOpts
---@field duration? SmoothScrollDuration Override animation duration.
---@field easing? SmoothScrollEasingName|SmoothScrollEasingFn Override easing function.
---@field max_fps? number Override maximum frames per second.
---@field scroll_mode? SmoothScrollMode Override scroll mode (cursor/viewport/both).
---@field disable_events? boolean Override event suppression behaviour.
---@field mouse_wheel_lines? number Override number of screen lines per mouse wheel event.
---@field interrupt_behaviour? SmoothScrollInterruptBehaviour Override interrupt behaviour for this call.
---@field viewport_bottom_margin? integer Override viewport bottom margin for this call. See `SmoothScrollConfig.viewport_bottom_margin`.
---@field on_complete? fun() Callback invoked when the scroll animation finishes.
---@field win? integer Target window handle (from `nvim_get_current_win()` or similar). When set, scrolling is performed in this window. If the target is not the current window, `scroll_mode` is forced to `"viewport"` — only the viewport moves, the cursor is not touched. `0` or `nil` means the current window.

---------------------------------------------------------------------------
-- Module
---------------------------------------------------------------------------

---@class smooth-scroll.config
local M = {}

--- Default configuration values.
---
--- These are used as the base for `vim.tbl_deep_extend` when the user calls
--- `setup()`.  Any key not specified by the user keeps its default.
---
---@type SmoothScrollConfig
M.defaults = {
  duration = function(lines) return lines * 12 end,
  easing = "linear",
  max_fps = 60,
  scroll_mode = "viewport",
  disable_events = true,
  mouse_wheel_lines = 3,
  interrupt_behaviour = "cancel",
  keymaps = {
    ["<C-d>"] = { motion = "half_page_down", modes = { "n", "x", "o" } },
    ["<C-u>"] = { motion = "half_page_up", modes = { "n", "x", "o" } },
    ["<C-f>"] = { motion = "page_down", modes = { "n", "x", "o" } },
    ["<C-b>"] = { motion = "page_up", modes = { "n", "x", "o" } },
    ["zt"] = { motion = "center_top", modes = "n" },
    ["zz"] = { motion = "center", modes = "n" },
    ["zb"] = { motion = "center_bottom", modes = "n" },
    ["<ScrollWheelDown>"] = {
      motion = "scroll_wheel_down",
      modes = { "n", "x", "i" },
      scroll_mode = "viewport",
      mouse_wheel_lines = 1,
      duration = 100,
      interrupt_behaviour = "accumulate",
    },
    ["<ScrollWheelUp>"] = {
      motion = "scroll_wheel_up",
      modes = { "n", "x", "i" },
      scroll_mode = "viewport",
      mouse_wheel_lines = 1,
      duration = 100,
      interrupt_behaviour = "accumulate",
    },
  },
}

--- Currently active (merged) configuration.
---
--- After `setup()` is called this holds the result of merging defaults with user
--- options.  Before `setup()` it is a deep copy of `defaults`.
---
---@type SmoothScrollConfig
M.current = vim.deepcopy(M.defaults)

--- Merge user-provided options into the defaults and activate the result.
---
--- Keymap entries are handled specially: setting a key to `false` in `opts.keymaps`
--- removes that default binding rather than overwriting it with a falsy value.
---
--- This function is idempotent — calling it again overwrites the previous merge.
---
---@param opts? SmoothScrollConfig Partial user configuration.  `nil` or `{}` keeps all defaults.
---@return SmoothScrollConfig config The merged, now-active configuration.
function M.setup(opts)
  opts = opts or {}

  -- Handle keymaps specially: false values should disable the keymap
  local user_keymaps = opts.keymaps
  opts.keymaps = nil -- remove before deep extend so we handle it manually

  M.current = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)

  if user_keymaps then
    for key, val in pairs(user_keymaps) do
      if val == false then
        M.current.keymaps[key] = nil
      else
        M.current.keymaps[key] = vim.tbl_deep_extend(
          "force",
          M.current.keymaps[key] or {},
          val
        )
      end
    end
  end

  return M.current
end

--- Resolve effective options for a single scroll call.
---
--- Merges per-call overrides on top of the currently active global config.  If
--- `opts` is `nil` or empty the global config is returned directly (no copy).
---
---@param opts? SmoothScrollOpts Per-call overrides.
---@return SmoothScrollConfig effective The effective option set for this call.
function M.resolve(opts)
  if not opts or next(opts) == nil then
    return M.current
  end
  -- Manual shallow merge: all config fields are scalar, so
  -- vim.tbl_deep_extend overhead is unnecessary.  For booleans use
  -- the ~= nil pattern to preserve explicit `false` values.
  local cur = M.current
  return {
    duration = opts.duration or cur.duration,
    easing = opts.easing or cur.easing,
    max_fps = opts.max_fps or cur.max_fps,
    scroll_mode = opts.scroll_mode or cur.scroll_mode,
    disable_events = opts.disable_events ~= nil and opts.disable_events or cur.disable_events,
    mouse_wheel_lines = opts.mouse_wheel_lines or cur.mouse_wheel_lines,
    interrupt_behaviour = opts.interrupt_behaviour or cur.interrupt_behaviour,
    viewport_bottom_margin = opts.viewport_bottom_margin ~= nil and opts.viewport_bottom_margin or cur.viewport_bottom_margin,
    -- Per-call only fields (not in defaults)
    win = opts.win,
    on_complete = opts.on_complete,
  }
end

return M
