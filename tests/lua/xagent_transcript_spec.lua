-- Regression: fake bold must redraw exactly one PHYSICAL pixel to the right.
-- The native renderer snaps glyphs to whole device pixels; a sub-logical offset
-- (the old +0.6) rounded inconsistently per glyph and looked like a blurry ghost.
package.path = 'scripts/?.lua;' .. package.path
local spec = dofile('tests/lua/spec_helper.lua')
local transcript = require('xagent.ui.transcript')

-- Offline raygui double: records draw_text calls; width = 8px per byte.
local function adapter(info)
    local calls = {}
    local rg = {
        measure_text = function(s) return #s * 8 end,
        get_mouse = function() return -1, -1 end,
        get_wheel = function() return 0 end,
        draw_rectangle = function() end,
        begin_scissor = function() end,
        end_scissor = function() end,
        draw_text = function(text, x, y) calls[#calls + 1] = { text = text, x = x, y = y } end,
    }
    if info then rg.display_info = function() return info end end
    return rg, calls
end

local function bold_pair(calls, text)
    local hits = {}
    for _, c in ipairs(calls) do
        if c.text == text then hits[#hits + 1] = c end
    end
    spec.equal(#hits, 2, 'bold run "' .. text .. '" must be drawn exactly twice')
    return hits[2].x - hits[1].x, hits[1].y - hits[2].y
end

local function near(got, want, message)
    spec.truthy(math.abs(got - want) < 1e-9, message or ('offset ' .. got .. ' ~= ' .. want))
end

spec.describe('transcript fake bold', function()
    spec.it('shifts the bold pass one device pixel at fractional DPI', function()
        local rg, calls = adapter({ dpi_x = 1.25, dpi_y = 1.25, ui_scale = 1 })
        local view = transcript.new_view({ raygui = rg, font_size = 16 })
        view:draw({ { role = 'assistant', text = '**Bold** plain' } }, 0, 0, 400, 300)
        local dx, dy = bold_pair(calls, 'Bold')
        near(dx, 1 / 1.25)
        spec.equal(dy, 0)
        local plain = 0
        for _, c in ipairs(calls) do
            if c.text == ' plain' then plain = plain + 1 end
        end
        spec.equal(plain, 1, 'non-bold runs are drawn once')
    end)
    spec.it('composes user zoom with system DPI', function()
        local rg, calls = adapter({ dpi_x = 1.25, dpi_y = 1.25, ui_scale = 1.6 })
        local view = transcript.new_view({ raygui = rg, font_size = 16 })
        view:draw({ { role = 'assistant', text = '# Title' } }, 0, 0, 400, 300)
        local dx = bold_pair(calls, 'Title')
        near(dx, 1 / (1.25 * 1.6))
    end)
    spec.it('falls back to one logical pixel on runtimes without display_info', function()
        local rg, calls = adapter(nil)
        local view = transcript.new_view({ raygui = rg, font_size = 16 })
        view:draw({ { role = 'assistant', text = '**Bold**' } }, 0, 0, 400, 300)
        local dx = bold_pair(calls, 'Bold')
        near(dx, 1)
    end)
end)

local failed = spec.finish()
return { __init = function() if failed > 0 then os.exit(1) end; xthread.stop(0) end }