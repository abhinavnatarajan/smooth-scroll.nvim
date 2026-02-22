--- Easing functions for smooth-scroll.nvim
---
--- Each easing function maps a normalised progress value `t ∈ [0, 1]` to an
--- output value in the same range.  The output describes *how much* of the
--- total distance has been covered at time `t`.  The animation engine uses the
--- derivative of this curve to determine per-tick timing — steeper regions
--- produce shorter intervals (faster movement) and shallower regions produce
--- longer intervals (slower movement).
---
---@module "smooth-scroll.easing"

--- An easing function: takes normalised time and returns normalised progress.
---@alias SmoothScrollEasingFn fun(t: number): number

--- Easing name recognised by the plugin.
---@alias SmoothScrollEasingName
---| "linear"
---| "ease_out_quad"
---| "ease_out_cubic"
---| "ease_in_out_quad"
---| "ease_in_out_cubic"

---@class smooth-scroll.easing
local M = {}

--- Linear easing — constant speed, no acceleration.
---
--- `f(t) = t`
---
---@param t number Normalised time in `[0, 1]`.
---@return number progress Normalised progress in `[0, 1]`.
function M.linear(t)
  return t
end

--- Quadratic ease-out — starts fast, decelerates to a stop.
---
--- `f(t) = t × (2 − t)`
---
---@param t number Normalised time in `[0, 1]`.
---@return number progress Normalised progress in `[0, 1]`.
function M.ease_out_quad(t)
  return t * (2 - t)
end

--- Cubic ease-out — starts fast, decelerates more strongly than quadratic.
---
--- `f(t) = 1 − (1 − t)³`
---
---@param t number Normalised time in `[0, 1]`.
---@return number progress Normalised progress in `[0, 1]`.
function M.ease_out_cubic(t)
  local u = 1 - t
  return 1 - u * u * u
end

--- Quadratic ease-in-out — accelerates in the first half, decelerates in the
--- second.
---
--- ```
--- f(t) = 2t²              if t < 0.5
---      = −1 + (4 − 2t)t   otherwise
--- ```
---
---@param t number Normalised time in `[0, 1]`.
---@return number progress Normalised progress in `[0, 1]`.
function M.ease_in_out_quad(t)
  if t < 0.5 then
    return 2 * t * t
  else
    return -1 + (4 - 2 * t) * t
  end
end

--- Cubic ease-in-out — accelerates then decelerates, with a stronger curve
--- than the quadratic variant.
---
--- ```
--- f(t) = 4t³                      if t < 0.5
---      = 1 + 0.5 × (2t − 2)³     otherwise
--- ```
---
---@param t number Normalised time in `[0, 1]`.
---@return number progress Normalised progress in `[0, 1]`.
function M.ease_in_out_cubic(t)
  if t < 0.5 then
    return 4 * t * t * t
  else
    local u = 2 * t - 2
    return 1 + 0.5 * u * u * u
  end
end

--- Lookup table mapping easing names to their implementations.
---@type table<SmoothScrollEasingName, SmoothScrollEasingFn>
M.functions = {
  linear = M.linear,
  ease_out_quad = M.ease_out_quad,
  ease_out_cubic = M.ease_out_cubic,
  ease_in_out_quad = M.ease_in_out_quad,
  ease_in_out_cubic = M.ease_in_out_cubic,
}

--- Resolve an easing specifier to a callable function.
---
--- Accepts either a `SmoothScrollEasingName` string or a custom function with
--- the signature `fun(t: number): number`.  If the string does not match any
--- built-in name a warning is emitted and `ease_out_quad` is returned as a
--- safe fallback.
---
---@param easing SmoothScrollEasingName|SmoothScrollEasingFn Easing name or custom function.
---@return SmoothScrollEasingFn fn The resolved easing function.
function M.resolve(easing)
  if type(easing) == "function" then
    return easing
  end
  local fn = M.functions[easing]
  if not fn then
    vim.notify(
      string.format("[smooth-scroll] Unknown easing '%s', falling back to ease_out_quad", easing),
      vim.log.levels.WARN
    )
    return M.ease_out_quad
  end
  return fn
end

return M
