package.path = 'scripts/?.lua;' .. package.path
local spec = dofile('tests/lua/spec_helper.lua')
local file = assert(io.open('scripts/xagent/gui.lua', 'rb'))
local source = file:read('*a'); file:close()
local first = assert(source:find('local WINBTN_W =', 1, true))
local last = assert(source:find('local function draw_window_controls', first, true))

local function fixture()
    local S = { frame = 10, win_last_press = 8 }
    local native = { down = true, maximized = false, resized = 0, moved = 0 }
    local rg = {
        mouse_down = function() return native.down end,
        is_window_maximized = function() return native.maximized end,
        get_mouse = function() return 200, 100 end,
        mouse_screen = function() return 400, 300 end,
        set_mouse_cursor = function() end,
        set_window_size = function() native.resized = native.resized + 1 end,
        set_window_pos = function() native.moved = native.moved + 1 end,
    }
    local env = setmetatable({ S = S, raygui = rg, HEADER_H = 38 }, { __index = _G })
    local frame = assert(load(source:sub(first, last - 1) .. '\nreturn window_chrome',
        '@window-chrome', 't', env))()
    S.win_grab = { mode = 'e', sx = 100, sy = 100, wx = 0, wy = 0, ww = 960, wh = 700 }
    return frame, S, native
end

spec.describe('window chrome while maximized', function()
    spec.it('cancels a resize gesture after entering maximized state', function()
        local frame, S, native = fixture()
        native.maximized = true
        spec.equal(frame(2560, 1440), false)
        spec.nil_value(S.win_grab)
        spec.equal(native.resized, 0); spec.equal(native.moved, 0)
    end)
    spec.it('keeps normal window resizing available', function()
        local frame, _, native = fixture()
        spec.equal(frame(960, 700), true)
        spec.equal(native.resized, 1)
    end)
end)

local failed = spec.finish()
return { __init = function() if failed > 0 then os.exit(1) end; xthread.stop(0) end }
