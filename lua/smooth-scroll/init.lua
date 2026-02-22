--- smooth-scroll.nvim — Public API
---
--- Entry point for users.  Exposes `setup()`, low-level scroll primitives
--- (`scroll()`, `scroll_fraction()`), named motion helpers for every supported
--- scroll type, and keymap wiring.
---
---@module "smooth-scroll"

local config = require("smooth-scroll.config")
local scroller = require("smooth-scroll.scroller")

---@class smooth-scroll
local M = {}

---------------------------------------------------------------------------
-- State query
---------------------------------------------------------------------------

--- Return whether a scroll animation is currently in progress.
---
---@return boolean is_scrolling `true` if an animation is running.
function M.is_scrolling()
  return scroller.is_scrolling
end

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------

--- Initialise the plugin with user options and register default keymaps.
---
--- Should be called once from the user's Neovim configuration (e.g. in a
--- `lazy.nvim` `config` function).  Merges `opts` into the default
--- configuration via `config.setup()` and then wires up all enabled keymaps.
---
--- Calling `setup()` again is allowed — it fully replaces the previous
--- configuration and re-registers keymaps.
---
---@param opts? SmoothScrollConfig Partial configuration table. Omitted keys keep their defaults.
function M.setup(opts)
  config.setup(opts)
  M._setup_keymaps()
end

---------------------------------------------------------------------------
-- Core scroll primitives
---------------------------------------------------------------------------

--- Scroll by an exact number of screen lines.
---
--- Positive values scroll **down**, negative values scroll **up**.  Delegates
--- directly to the animation engine.
---
---@param lines integer Number of screen lines. Positive = down, negative = up.
---@param opts? SmoothScrollOpts Per-call overrides (duration, easing, scroll_mode, …).
function M.scroll(lines, opts)
  scroller.scroll(lines, opts)
end

--- Scroll by a fraction of the current window height.
---
--- The fraction is multiplied by `nvim_win_get_height(0)` and rounded to the
--- nearest integer to obtain the number of screen lines.  Positive fractions
--- scroll down, negative fractions scroll up.
---
--- Example: `scroll_fraction(0.5)` scrolls half a page down.
---
---@param fraction number Fraction of window height (e.g. `0.5` = half page, `-0.25` = quarter page up).
---@param opts? SmoothScrollOpts Per-call overrides.
function M.scroll_fraction(fraction, opts)
  local win = (opts and opts.win and opts.win ~= 0) and opts.win or 0
  local win_height = vim.api.nvim_win_get_height(win)
  local lines = math.floor(fraction * win_height + 0.5)
  scroller.scroll(lines, opts)
end

---------------------------------------------------------------------------
-- Named motion functions
---------------------------------------------------------------------------

--- Scroll half a page down (analogous to `<C-d>`).
---
--- Uses `vim.wo.scroll` which Neovim keeps at half the window height.
---
---@param opts? SmoothScrollOpts Per-call overrides.
function M.half_page_down(opts)
  local win = (opts and opts.win and opts.win ~= 0) and opts.win or 0
  local lines = vim.api.nvim_get_option_value("scroll", { win = win })
  scroller.scroll(lines, opts)
end

--- Scroll half a page up (analogous to `<C-u>`).
---
--- Uses `vim.wo.scroll` which Neovim keeps at half the window height.
---
---@param opts? SmoothScrollOpts Per-call overrides.
function M.half_page_up(opts)
  local win = (opts and opts.win and opts.win ~= 0) and opts.win or 0
  local lines = vim.api.nvim_get_option_value("scroll", { win = win })
  scroller.scroll(-lines, opts)
end

--- Scroll a full page down (analogous to `<C-f>`).
---
--- Keeps 2 lines of overlap with the previous view, matching Vim's native
--- `<C-f>` behaviour.
---
---@param opts? SmoothScrollOpts Per-call overrides.
function M.page_down(opts)
  local win = (opts and opts.win and opts.win ~= 0) and opts.win or 0
  local win_height = vim.api.nvim_win_get_height(win)
  local lines = math.max(1, win_height - 2)
  scroller.scroll(lines, opts)
end

--- Scroll a full page up (analogous to `<C-b>`).
---
--- Keeps 2 lines of overlap with the previous view, matching Vim's native
--- `<C-b>` behaviour.
---
---@param opts? SmoothScrollOpts Per-call overrides.
function M.page_up(opts)
  local win = (opts and opts.win and opts.win ~= 0) and opts.win or 0
  local win_height = vim.api.nvim_win_get_height(win)
  local lines = math.max(1, win_height - 2)
  scroller.scroll(-lines, opts)
end

--- Scroll to put the cursor line at the top of the window (analogous to `zt`).
---
--- Uses the peek-and-animate strategy with `scroll_mode = "viewport"`: the
--- viewport scrolls via `<C-e>`/`<C-y>` while the cursor stays on the same
--- buffer line throughout the animation.
---
---@param opts? SmoothScrollOpts Per-call overrides.
function M.center_top(opts)
  opts = vim.tbl_extend("force", opts or {}, { scroll_mode = "viewport" })
  scroller.scroll_to_target("zt", opts)
end

--- Scroll to put the cursor line at the centre of the window (analogous to `zz`).
---
--- Uses the peek-and-animate strategy with `scroll_mode = "viewport"`: the
--- viewport scrolls via `<C-e>`/`<C-y>` while the cursor stays on the same
--- buffer line throughout the animation.
---
---@param opts? SmoothScrollOpts Per-call overrides.
function M.center(opts)
  opts = vim.tbl_extend("force", opts or {}, { scroll_mode = "viewport" })
  scroller.scroll_to_target("zz", opts)
end

--- Scroll to put the cursor line at the bottom of the window (analogous to `zb`).
---
--- Uses the peek-and-animate strategy with `scroll_mode = "viewport"`: the
--- viewport scrolls via `<C-e>`/`<C-y>` while the cursor stays on the same
--- buffer line throughout the animation.
---
---@param opts? SmoothScrollOpts Per-call overrides.
function M.center_bottom(opts)
  opts = vim.tbl_extend("force", opts or {}, { scroll_mode = "viewport" })
  scroller.scroll_to_target("zb", opts)
end

---------------------------------------------------------------------------
-- Mouse wheel
---------------------------------------------------------------------------

--- Scroll down by `mouse_wheel_lines` screen lines (analogous to `<ScrollWheelDown>`).
---
--- The number of lines is read from `config.current.mouse_wheel_lines` (default 3)
--- and can be overridden per-call via `opts.mouse_wheel_lines`.
---
---@param opts? SmoothScrollOpts Per-call overrides.
function M.scroll_wheel_down(opts)
  local resolved = config.resolve(opts)
  local lines = resolved.mouse_wheel_lines or 3
  scroller.scroll(lines, opts)
end

--- Scroll up by `mouse_wheel_lines` screen lines (analogous to `<ScrollWheelUp>`).
---
--- The number of lines is read from `config.current.mouse_wheel_lines` (default 3)
--- and can be overridden per-call via `opts.mouse_wheel_lines`.
---
---@param opts? SmoothScrollOpts Per-call overrides.
function M.scroll_wheel_up(opts)
  local resolved = config.resolve(opts)
  local lines = resolved.mouse_wheel_lines or 3
  scroller.scroll(-lines, opts)
end

--- Stop any in-progress scroll animation immediately.
---
--- Delegates to `scroller.stop()`.  Safe to call when no animation is running.
function M.stop()
  scroller.stop()
end

---------------------------------------------------------------------------
-- Keymap setup
---------------------------------------------------------------------------

--- Lookup table mapping motion names (from `SmoothScrollKeymap.motion`) to
--- their implementing functions on this module.
---
---@type table<string, fun(opts?: SmoothScrollOpts)>
local motion_map = {
  half_page_down = M.half_page_down,
  half_page_up = M.half_page_up,
  page_down = M.page_down,
  page_up = M.page_up,
  center_top = M.center_top,
  center = M.center,
  center_bottom = M.center_bottom,
  scroll_wheel_down = M.scroll_wheel_down,
  scroll_wheel_up = M.scroll_wheel_up,
}

--- Register Neovim keymaps from the current configuration.
---
--- Iterates over `config.current.keymaps` and creates `vim.keymap.set`
--- bindings for each entry.  Per-keymap option overrides (duration, easing,
--- scroll_mode) are captured in the mapping closure.
---
--- This is an internal function called automatically by `setup()`.
---@private
function M._setup_keymaps()
  local keymaps = config.current.keymaps
  if not keymaps then
    return
  end

  for lhs, keymap in pairs(keymaps) do
    if not keymap then
      goto continue
    end
    local fn = motion_map[keymap.motion]
    if not fn then
      vim.notify(
        string.format("[smooth-scroll] Unknown motion '%s' for keymap '%s'", keymap.motion, lhs),
        vim.log.levels.WARN
      )
      goto continue
    end

    -- Build per-keymap override opts (only if at least one override is set)
    ---@type SmoothScrollOpts?
    local key_opts = nil
    if keymap.duration or keymap.easing or keymap.scroll_mode or keymap.max_fps then
      key_opts = {
        duration = keymap.duration,
        easing = keymap.easing,
        scroll_mode = keymap.scroll_mode,
        max_fps = keymap.max_fps,
      }
    end

    -- Determine modes (normalise string → table)
    ---@type string[]
    local modes = keymap.modes or { "n", "x" }
    if type(modes) == "string" then
      modes = { modes }
    end

    -- Create the mapping
    vim.keymap.set(modes, lhs, function()
      fn(key_opts)
    end, {
      desc = string.format("smooth-scroll: %s", keymap.motion),
      silent = true,
    })

    ::continue::
  end
end

return M
