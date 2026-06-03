--- Core animation engine for smooth-scroll.nvim
---
--- Owns the single reused `vim.uv` timer, manages per-tick scrolling
--- (viewport + cursor), applies easing-derived variable timing, handles
--- boundary detection, winline drift correction, and animation interruption.
---
--- All scrolling is expressed in **screen lines** — `<C-e>`/`<C-y>` for the
--- viewport and `gj`/`gk` for the cursor — so folds and wrapping are handled
--- natively.
---
---@module "smooth-scroll.scroller"

local easing_mod = require("smooth-scroll.easing")
local config = require("smooth-scroll.config")

---@class smooth-scroll.scroller
local M = {}

---------------------------------------------------------------------------
-- Upvalue caches for hot-path Neovim API calls
---------------------------------------------------------------------------

local api = vim.api
local fn = vim.fn
local cmd_normal = vim.cmd.normal

local nvim_get_current_win = api.nvim_get_current_win
local nvim_win_is_valid = api.nvim_win_is_valid
local nvim_win_call = api.nvim_win_call
local fn_line = fn.line
local fn_winline = fn.winline
local fn_winsaveview = fn.winsaveview
local fn_winrestview = fn.winrestview
local fn_getwininfo = fn.getwininfo
local fn_virtcol = fn.virtcol
local fn_screenpos = fn.screenpos

local math_floor = math.floor
local math_max = math.max
local math_min = math.min
local math_abs = math.abs

---------------------------------------------------------------------------
-- Pre-computed terminal codes
---------------------------------------------------------------------------

--- Terminal code for `<C-e>` (scroll viewport down by one screen line).
---@type string
local CTRL_E = vim.keycode("<C-e>")

--- Terminal code for `<C-y>` (scroll viewport up by one screen line).
---@type string
local CTRL_Y = vim.keycode("<C-y>")

---------------------------------------------------------------------------
-- Timer & animation state
---------------------------------------------------------------------------

--- Maximum number of screen lines that can accumulate when
--- `interrupt_behaviour = "accumulate"`.  This prevents runaway accumulation
--- from very rapid scroll-wheel input.  Not exposed in user config — adjust
--- here if needed.
local MAX_ACCUMULATE_LINES = 200

--- Single reused libuv timer for the plugin's lifetime.
local timer, err = vim.uv.new_timer()
if not timer then
	vim.notify("smooth-scroll.nvim: Could not get timer for scroller. " .. err, vim.log.levels.ERROR)
end
---@cast timer uv.uv_timer_t

--- Internal state for a running animation.
---
--- Created fresh by `scroll()` and cleared by `stop()`.
---
---@class SmoothScrollAnimationState
---@field steps number[] Per-tick interval durations in milliseconds, one entry per tick.
---@field lines_per_tick integer[] Number of screen lines to scroll in each tick (parallel to `steps`).
---@field step_index integer Current step (0-based before first tick, incremented at the start of each tick).
---@field direction -1|1 Scroll direction: `1` = down, `-1` = up.
---@field scroll_mode SmoothScrollMode How cursor and viewport interact during this animation.
---@field expected_winline integer Expected `vim.fn.winline()` value after the previous tick (used for drift correction in `"both"` mode).
---@field on_complete? fun() Optional callback invoked when the animation finishes normally or reaches a boundary.
---@field saved_eventignore? string Previous value of `vim.o.eventignore`, restored when the animation ends.
---@field win integer Target window handle. Resolved to a concrete window ID (never 0) at animation start.
---@field viewport_at_boundary boolean When `true`, the viewport has hit a buffer boundary during a `"viewport"` mode animation. Subsequent lines fall back to cursor movement (`gj`/`gk`) instead of stopping the animation.
---@field last_buf_line integer Total number of buffer lines (`vim.fn.line("$")`), precomputed at animation start for bottom boundary detection.
---@field viewport_bottom_margin integer Number of empty `~` lines below the last buffer line that triggers cursor-movement fallback when scrolling down in `"viewport"` mode.

--- The currently-running animation, or `nil` when idle.
---@type SmoothScrollAnimationState?
local currentAnimationState = nil

--- Whether an animation is currently in progress.
---@type boolean
M.is_scrolling = false

---------------------------------------------------------------------------
-- Public: stop
---------------------------------------------------------------------------

--- Immediately cancel the current animation.
---
--- Stops the timer, restores any suppressed events, and resets internal state.
--- Safe to call when no animation is running (no-op).
function M.stop()
	if not M.is_scrolling then
		return
	end
	timer:stop()
	M.is_scrolling = false
	-- Restore event settings
	if currentAnimationState and currentAnimationState.saved_eventignore then
		vim.o.eventignore = currentAnimationState.saved_eventignore
		currentAnimationState.saved_eventignore = nil
	end
	currentAnimationState = nil
end

---------------------------------------------------------------------------
-- Internal: interval computation
---------------------------------------------------------------------------

--- Compute the per-tick animation schedule from the easing curve.
---
--- Returns two parallel arrays: `intervals` (ms per tick) and `lines_per_tick`
--- (screen lines to scroll in that tick).
---
--- When `total_lines <= max_frames`, each tick scrolls exactly 1 line and
--- intervals sum to `duration_ms` (the smooth case).
---
--- When `total_lines > max_frames`, lines are distributed into `max_frames`
--- buckets so that each tick may scroll multiple lines.  Intervals still sum
--- to `duration_ms` — duration is always authoritative.
---
---@param total_lines integer Absolute number of screen lines to scroll (> 0).
---@param duration_ms number Total animation duration in milliseconds.
---@param easing_fn SmoothScrollEasingFn Easing function mapping `[0,1] → [0,1]`.
---@param max_fps number Maximum frames per second; clamped to [1, 250].
---@return number[] intervals Array of interval durations in ms, one per tick.
---@return integer[] lines_per_tick Array of screen lines to scroll per tick (parallel to intervals).
local function compute_intervals(total_lines, duration_ms, easing_fn, max_fps)
	if total_lines <= 0 then
		return {}, {}
	end

	-- Clamp max_fps to [1, 250]
	max_fps = math_max(1, math_min(250, max_fps))

	local max_frames = math_max(1, math_floor(duration_ms * max_fps / 1000))

	-- For single-line scrolls, just return one tick
	if total_lines == 1 then
		return { duration_ms }, { 1 }
	end

	-- Determine number of ticks (frames) and lines per tick
	local num_ticks
	local lines_per_tick = {}

	if total_lines <= max_frames then
		-- Smooth case: one line per tick
		num_ticks = total_lines
		for i = 1, num_ticks do
			lines_per_tick[i] = 1
		end
	else
		-- Multi-line case: distribute total_lines across max_frames ticks.
		-- Use the easing curve to determine how many lines each tick should cover
		-- so that the visual distribution matches the easing shape.
		num_ticks = max_frames
		local assigned = 0
		for i = 1, num_ticks do
			local t0 = (i - 1) / num_ticks
			local t1 = i / num_ticks
			local frac = easing_fn(t1) - easing_fn(t0)
			local bucket = math_floor(frac * total_lines + 0.5)
			if bucket < 1 then
				bucket = 1
			end
			lines_per_tick[i] = bucket
			assigned = assigned + bucket
		end

		-- Fix rounding errors: adjust the last bucket
		local diff = total_lines - assigned
		lines_per_tick[num_ticks] = math_max(1, lines_per_tick[num_ticks] + diff)
	end

	-- Compute easing-based intervals that sum to duration_ms.
	-- Sample the easing curve per tick; use inverse delta as weight.
	local raw_weights = {}
	local total_weight = 0

	for i = 1, num_ticks do
		local t0 = (i - 1) / num_ticks
		local t1 = i / num_ticks
		local delta = easing_fn(t1) - easing_fn(t0)
		local w
		if delta > 0 then
			w = 1 / delta
		else
			w = 1000 -- effectively very slow for zero-delta
		end
		raw_weights[i] = w
		total_weight = total_weight + w
	end

	-- Normalise so the intervals sum to duration_ms
	local intervals = {}
	for i = 1, num_ticks do
		intervals[i] = math_max(1, math_floor((raw_weights[i] / total_weight) * duration_ms + 0.5))
	end

	return intervals, lines_per_tick
end

---------------------------------------------------------------------------
-- Internal: per-tick helpers
---------------------------------------------------------------------------

--- Execute one scroll tick — move by exactly one screen line.
---
--- **`"cursor"` mode**: moves the cursor with `gj`/`gk` only.  The viewport
--- scrolls automatically when `scrolloff` is reached — no explicit
--- `<C-e>`/`<C-y>` is issued.
---
--- **`"viewport"` or `"both"` mode**: scrolls the viewport with
--- `<C-e>`/`<C-y>`.  The cursor is not moved directly.  In `"both"` mode,
--- drift correction in `correct_drift()` keeps the cursor pinned at its
--- original winline.  In `"viewport"` mode, no drift correction is applied
--- so the cursor stays on the same buffer line.
---
---@param direction -1|1 `1` = scroll down, `-1` = scroll up.
---@param scroll_mode SmoothScrollMode `"cursor"` uses `gj`/`gk`; `"viewport"` and `"both"` use `<C-e>`/`<C-y>`.
local function scroll_one_line(direction, scroll_mode)
	if scroll_mode == "cursor" then
		-- Cursor-led: just move the cursor; Neovim scrolls the viewport
		-- automatically when the cursor approaches `scrolloff`.
		if direction == 1 then
			cmd_normal({ bang = true, args = { "gj" } })
		else
			cmd_normal({ bang = true, args = { "gk" } })
		end
	else
		-- Viewport-led ("viewport" or "both"): scroll the viewport directly.
		if direction == 1 then
			cmd_normal({ bang = true, args = { CTRL_E } })
		else
			cmd_normal({ bang = true, args = { CTRL_Y } })
		end
	end
end

--- Correct cursor drift after a viewport-led scroll tick (`scroll_mode = "both"`).
---
--- When the viewport moves via `<C-e>`/`<C-y>`, the cursor's screen-line
--- position (winline) can drift because Neovim adjusts it to keep the cursor
--- on-screen.  This function issues corrective `gj`/`gk` commands to pin
--- the cursor back to its expected winline.  At most 3 corrections per call.
---
--- Only meaningful in `"both"` mode.  In `"cursor"` mode, cursor movement is
--- intentional and no correction is needed.  In `"viewport"` mode, drift
--- correction is deliberately skipped so the cursor stays on its buffer line.
---
---@param expected integer Expected `vim.fn.winline()` value.
---@return integer new_expected The (potentially corrected) winline value to use as the expectation for the next tick.
local function correct_drift(expected)
	local actual = fn_winline()
	local drift = actual - expected

	if drift == 0 then
		return expected
	end

	-- Clamp corrections to avoid runaway loops
	local corrections = math_min(math_abs(drift), 3)
	if drift > 0 then
		-- Cursor is too low — move it up
		for _ = 1, corrections do
			cmd_normal({ bang = true, args = { "gk" } })
		end
	else
		-- Cursor is too high — move it down
		for _ = 1, corrections do
			cmd_normal({ bang = true, args = { "gj" } })
		end
	end

	return fn_winline()
end

--- Check whether the viewport has hit a scroll boundary.
---
--- Detect whether a scroll tick actually moved anything.
---
--- **Cursor-led** (`"cursor"` mode): compares cursor screen position
--- (`winline` + `virtcol`) before and after `gj`/`gk`.  Uses screen-level
--- coordinates so that movement across wrapped sub-lines is detected correctly.
---
--- **Viewport-led** (`"viewport"` / `"both"`): compares `topline` and
--- `skipcol` before and after `<C-e>`/`<C-y>`.  `skipcol` changes when
--- scrolling within a wrapped top line even though `topline` stays the same.
---
---@param scroll_mode SmoothScrollMode Which mode the tick is operating in.
---@param prev table Snapshot captured *before* the scroll tick. For `"cursor"`: `{ lnum, winline, virtcol }`. For `"viewport"`/`"both"`: `{ topline, skipcol }`.
---@return boolean at_boundary `true` if the scroll had no effect.
local function at_boundary(scroll_mode, prev)
	if scroll_mode == "cursor" then
		-- Cursor-led: check if cursor actually moved.
		-- We check buffer line number (lnum), screen row (winline), and virtual
		-- column (virtcol).  All three must be unchanged for a true boundary.
		-- When the cursor enters the scrolloff zone, gj/gk moves the cursor
		-- (lnum changes) while Neovim simultaneously scrolls the viewport to
		-- maintain scrolloff, leaving winline/virtcol unchanged.  Checking lnum
		-- prevents that from being misdetected as a boundary.
		local new_lnum = fn_line(".")
		local new_winline = fn_winline()
		local new_virtcol = fn_virtcol(".")
		return new_lnum == prev.lnum and new_winline == prev.winline and new_virtcol == prev.virtcol
	else
		-- Viewport-led: check if the viewport actually scrolled.
		-- skipcol tracks the display offset within a wrapped topline, so it
		-- changes when <C-e>/<C-y> scrolls within a wrapped top line.
		local view = fn_winsaveview()
		return view.topline == prev.topline and view.skipcol == prev.skipcol
	end
end

---------------------------------------------------------------------------
-- Internal: timer callback
---------------------------------------------------------------------------

--- Core tick logic — scrolls lines, checks boundaries, corrects drift.
---
--- Extracted so it can be called directly or inside `nvim_win_call` depending
--- on whether the target window is the current window.
---
--- In `"viewport"` mode, when the viewport hits a buffer boundary (top or
--- bottom), remaining lines in the tick and subsequent ticks fall back to
--- cursor movement (`gj`/`gk`) instead of stopping the animation.  This
--- ensures that, e.g., scrolling up past the top of the buffer continues
--- moving the cursor toward line 1 rather than halting.
---
---@return boolean finished `true` if the animation should stop after this tick.
---@return fun()|nil on_complete Callback to invoke after stopping (if any).
local function tick_inner(anim)
	-- Number of screen lines to scroll this tick
	local lines_this_tick = anim.lines_per_tick[anim.step_index]

	for _ = 1, lines_this_tick do
		-- In viewport mode, once we've detected a viewport boundary, all
		-- remaining lines are scrolled via cursor movement (gj/gk).
		if anim.viewport_at_boundary then
			local prev_lnum = fn_line(".")
			local prev_winline = fn_winline()
			local prev_virtcol = fn_virtcol(".")
			scroll_one_line(anim.direction, "cursor")
			-- If the cursor can't move either, we're truly at the boundary.
			-- Checks buffer line (lnum), screen row (winline), and virtual
			-- column (virtcol) — all three must be unchanged.
			if fn_line(".") == prev_lnum and fn_winline() == prev_winline and fn_virtcol(".") == prev_virtcol then
				return true, anim.on_complete
			end
		else
			-- Bottom boundary detection for viewport mode: when scrolling down,
			-- check whether enough empty ~ lines have appeared below the last
			-- buffer line BEFORE scrolling. This prevents one extra <C-e> from
			-- slipping through before the cursor-movement fallback kicks in.
			if
				anim.scroll_mode == "viewport"
				and anim.direction == 1
				and fn_line("w$") >= anim.last_buf_line
			then
				local pos = fn_screenpos(anim.win, anim.last_buf_line, 1)
				local last_line_winrow = pos.row - anim.win_top_row + 1
				local empty_below = anim.win_body_height - last_line_winrow
				if empty_below >= anim.viewport_bottom_margin then
					anim.viewport_at_boundary = true
				end
			end

			-- If we just detected the bottom boundary, don't scroll the viewport —
			-- fall back to cursor movement on the next loop iteration.
			if anim.viewport_at_boundary then
				local prev_lnum = fn_line(".")
				local prev_winline = fn_winline()
				local prev_virtcol = fn_virtcol(".")
				scroll_one_line(anim.direction, "cursor")
				if fn_line(".") == prev_lnum and fn_winline() == prev_winline and fn_virtcol(".") == prev_virtcol then
					return true, anim.on_complete
				end
			else
				-- Snapshot state before scroll for boundary detection.
				-- Uses screen-level coordinates so wrapped lines are handled:
				-- cursor mode: winline + virtcol (detect sub-line movement)
				-- viewport mode: topline + skipcol (detect wrapped topline scroll)
				local prev
				if anim.scroll_mode == "cursor" then
					prev = { lnum = fn_line("."), winline = fn_winline(), virtcol = fn_virtcol(".") }
				else
					local view = fn_winsaveview()
					prev = { topline = view.topline, skipcol = view.skipcol }
				end

				-- Execute one scroll line
				scroll_one_line(anim.direction, anim.scroll_mode)

				-- Check if we hit a boundary (topline unchanged / cursor unmoved)
				if at_boundary(anim.scroll_mode, prev) then
					if anim.scroll_mode == "viewport" then
						-- Viewport can't scroll any further — fall back to cursor
						-- movement for the remaining lines in this tick and all
						-- subsequent ticks.
						anim.viewport_at_boundary = true
					else
						return true, anim.on_complete
					end
				end
			end
		end
	end

	-- Correct drift: only in "both" mode where the viewport is scrolled
	-- via <C-e>/<C-y> and drift correction keeps the cursor pinned at
	-- its original winline via gj/gk.
	if anim.scroll_mode == "both" then
		anim.expected_winline = correct_drift(anim.expected_winline)
	end

	return false, nil
end

--- Main timer callback — executed inside `vim.schedule` on every tick.
---
--- Advances the animation by one step: scrolls one or more screen lines
--- (determined by `lines_per_tick`), checks for boundary conditions, corrects
--- drift, and adjusts the timer repeat interval for the next tick.  Stops the
--- animation when all steps are consumed or a boundary is reached.
---
--- When the target window is not the current window, all window-dependent
--- operations are executed inside `nvim_win_call` so that `vim.cmd.normal`,
--- `vim.fn.winline()`, etc. operate on the correct window.
local function tick()
	if not currentAnimationState or not M.is_scrolling then
		M.stop()
		return
	end

	local anim = currentAnimationState

	-- Validate that the target window still exists
	if not nvim_win_is_valid(anim.win) then
		M.stop()
		return
	end

	anim.step_index = anim.step_index + 1

	-- Check if animation is complete
	if anim.step_index > #anim.steps then
		local on_complete = anim.on_complete
		M.stop()
		if on_complete then
			on_complete()
		end
		return
	end

	-- Execute tick logic — in the target window context if not current
	local finished, on_complete
	finished, on_complete = nvim_win_call(anim.win, function()
		return tick_inner(anim)
	end)

	if finished then
		M.stop()
		if on_complete then
			on_complete()
		end
		return
	end

	-- Set the interval for the next tick
	if anim.step_index < #anim.steps then
		timer:set_repeat(anim.steps[anim.step_index + 1])
	end
end

---------------------------------------------------------------------------
-- Public: scroll
---------------------------------------------------------------------------

--- Start a smooth scroll animation by a given number of screen lines.
---
--- If an animation is already in progress it is interrupted (stopped) and the
--- new one begins immediately.  The easing curve determines the variable
--- timing between ticks.  When the total line count fits within the frame
--- budget (`max_fps`), each tick scrolls one screen line.  Otherwise lines
--- are distributed across ticks so the animation completes within
--- `duration` ms regardless of the scroll distance.
---
--- Return the number of screen lines remaining in `anim` that have not yet
--- been scrolled.  The result is always non-negative.
---@param anim SmoothScrollAnimationState
---@return integer
---@private
local function remaining_lines(anim)
	local rem = 0
	for i = anim.step_index + 1, #anim.lines_per_tick do
		rem = rem + anim.lines_per_tick[i]
	end
	return rem
end

--- A value of `0` for `lines` is a no-op.
---
---@param lines integer Number of screen lines to scroll. Positive = down, negative = up.
---@param opts? SmoothScrollOpts Per-call overrides merged on top of the global config.
function M.scroll(lines, opts)
	-- Interrupt any current animation, optionally accumulating remaining
	-- distance when scrolling in the same direction.
	if M.is_scrolling and currentAnimationState then
		local interrupt_behaviour = (opts and opts.interrupt_behaviour)
			or config.current.interrupt_behaviour
		local new_dir = lines > 0 and 1 or -1
		if interrupt_behaviour == "accumulate" and currentAnimationState.direction == new_dir then
			local rem = remaining_lines(currentAnimationState)
			lines = lines + rem * new_dir
			local abs_lines = math_abs(lines)
			if abs_lines > MAX_ACCUMULATE_LINES then
				lines = MAX_ACCUMULATE_LINES * new_dir
			end
		end
		M.stop()
	end

	if lines == 0 then
		return
	end

	local effective_config = config.resolve(opts)
	local direction = lines > 0 and 1 or -1
	local total_lines = math_abs(lines)
	local easing_fn = easing_mod.resolve(effective_config.easing)
	local raw_duration = effective_config.duration or 250
	local duration = type(raw_duration) == "function"
		and raw_duration(total_lines)
		or raw_duration
	---@cast duration number
	local max_fps = effective_config.max_fps or 60
	local scroll_mode = effective_config.scroll_mode or "cursor"

	-- Resolve target window: 0 / nil → current window ID
	local cur_win = nvim_get_current_win()
	local win = (opts and opts.win and opts.win ~= 0)
		and opts.win
		or cur_win

	-- Non-current windows force viewport-only mode: we must not move the
	-- cursor in a window we don't own.
	if win ~= cur_win then
		scroll_mode = "viewport"
	end

	-- Compute interval and lines-per-tick schedule
	local intervals, lines_per_tick = compute_intervals(total_lines, duration, easing_fn, max_fps)

	if #intervals == 0 then
		return
	end

	-- Capture expected_winline and last_buf_line in the target window context
	local expected_winline, last_buf_line
	if win == cur_win then
		expected_winline = fn_winline()
		last_buf_line = fn_line("$")
	else
		expected_winline, last_buf_line = nvim_win_call(win, function()
			return fn_winline(), fn_line("$")
		end)
	end
	---@cast last_buf_line integer

	-- Resolve viewport_bottom_margin: explicit config → scrolloff fallback
	local viewport_bottom_margin = effective_config.viewport_bottom_margin
	if viewport_bottom_margin == nil then
		viewport_bottom_margin = vim.wo[win].scrolloff
	end

	-- Early exit: if already at the bottom boundary in viewport mode scrolling
	-- down, don't start an animation at all.
	if scroll_mode == "viewport" and direction == 1 then
		local already_at_bottom = function()
			if fn_line(".") ~= last_buf_line then
				return false
			end
			if fn_line("w$") < last_buf_line then
				return false
			end
			local info = fn_getwininfo(win)[1]
			local pos = fn_screenpos(win, last_buf_line, 1)
			local last_line_winrow = pos.row - info.winrow + 1
			local empty_below = info.height - last_line_winrow
			return empty_below >= viewport_bottom_margin
		end

		local at_bottom
		if win == cur_win then
			at_bottom = already_at_bottom()
		else
			at_bottom = nvim_win_call(win, already_at_bottom)
		end

		if at_bottom then
			return
		end
	end

	-- Cache window geometry once — winrow and body height don't change
	-- during an animation, so we avoid calling getwininfo() on every tick.
	local info = fn_getwininfo(win)[1]
	local win_top_row = info.winrow
	local win_body_height = info.height

	-- Set up animation state
	currentAnimationState = {
		steps = intervals,
		lines_per_tick = lines_per_tick,
		step_index = 0,
		direction = direction,
		scroll_mode = scroll_mode,
		expected_winline = expected_winline,
		on_complete = opts and opts.on_complete,
		win = win,
		viewport_at_boundary = false,
		last_buf_line = last_buf_line,
		viewport_bottom_margin = viewport_bottom_margin,
		win_top_row = win_top_row,
		win_body_height = win_body_height,
	}

	-- Suppress events during animation
	if effective_config.disable_events then
		currentAnimationState.saved_eventignore = vim.o.eventignore
		vim.o.eventignore = "WinScrolled,CursorMoved"
	end

	M.is_scrolling = true

	-- Start the timer: first tick after intervals[1] ms, then repeating
	local first_interval = intervals[1]
	local repeat_interval = intervals[2] or first_interval

	timer:start(
		first_interval,
		repeat_interval,
		vim.schedule_wrap(tick)
	)
end

---------------------------------------------------------------------------
-- Public: scroll_to_target
---------------------------------------------------------------------------

--- Scroll to a target position using a "peek-and-animate" approach.
---
--- 1. Save the current view.
--- 2. Execute `native_cmd` (e.g. `"gg"`, `"G"`, `"zt"`) to discover the target.
--- 3. Measure the topline delta between the original and target views.
--- 4. Restore the original view.
--- 5. Animate the viewport by the measured delta.
--- 6. On completion, re-execute `native_cmd` so the cursor lands at the
---    precise final position (correct column, etc.).
---
--- If the delta is zero the native command is executed immediately without
--- animation.
---
---@param native_cmd string Normal-mode command to peek the target (e.g. `"gg"`, `"G"`, `"zt"`, `"n"`).
---@param opts? SmoothScrollOpts Per-call overrides.
function M.scroll_to_target(native_cmd, opts)
	-- Interrupt any current animation
	if M.is_scrolling then
		M.stop()
	end

	-- Resolve target window for the peek operations
	local win = (opts and opts.win and opts.win ~= 0)
		and opts.win
		or nvim_get_current_win()

	-- Peek the target position to measure topline delta.
	-- All operations (winsaveview, native_cmd, winrestview) must run in the
	-- target window context so that topline/cursor state is correct.
	local topline_delta = nvim_win_call(win, function()
		local saved_view = fn_winsaveview()
		cmd_normal({ bang = true, args = { native_cmd } })
		local target_view = fn_winsaveview()
		local delta = target_view.topline - saved_view.topline
		fn_winrestview(saved_view)
		return delta
	end)

	-- If no viewport movement needed, just execute the command directly
	if topline_delta == 0 then
		nvim_win_call(win, function()
			cmd_normal({ bang = true, args = { native_cmd } })
		end)
		return
	end

	-- Animate the scroll with a callback to re-execute the native command
	-- for precise final positioning (e.g. zt/zz/zb snapping to exact position).
	M.scroll(topline_delta, vim.tbl_extend("force", opts or {}, {
		win = win,
		on_complete = function()
			nvim_win_call(win, function()
				cmd_normal({ bang = true, args = { native_cmd } })
			end)
		end,
	}))
end

return M
