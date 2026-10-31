package.path = 'scripts/?.lua;' .. package.path
local spec = dofile('tests/lua/spec_helper.lua')
local surface = require('xagent.ui.surface')

local function adapter()
    local rg, styles = {}, {}
    for i, key in ipairs({ 'BUTTON', 'TEXTBOX', 'BORDER_WIDTH', 'BASE_COLOR_NORMAL',
        'BASE_COLOR_FOCUSED', 'BASE_COLOR_PRESSED', 'TEXT_COLOR_NORMAL',
        'TEXT_COLOR_FOCUSED', 'TEXT_COLOR_PRESSED', 'BORDER_COLOR_NORMAL',
        'BORDER_COLOR_FOCUSED', 'BORDER_COLOR_PRESSED' }) do rg[key] = i end
    rg.get_style = function(control, prop) return styles[control * 100 + prop] or 42 end
    rg.set_style = function(control, prop, value) styles[control * 100 + prop] = value end
    rg.get_mouse = function() return 20, 20 end
    rg.draw_rectangle = function() end
    return rg
end

spec.describe('rounded UI surfaces', function()
    spec.it('preserves editor arguments, submission state and theme styles', function()
        local rg = adapter()
        rg.textbox_multi = function(x, y, w, h, value, edit, sends)
            spec.equal(x, 12); spec.equal(w, 300)
            spec.equal(value, '草稿'); spec.equal(edit, false); spec.equal(sends, true)
            spec.equal(rg.get_style(rg.TEXTBOX, rg.BORDER_COLOR_PRESSED), 42)
            return '草稿', false, nil
        end
        local value, edit, sent = surface.editor(rg, {20,30,40,255}, 12, 20, 300, 78, '草稿', false, true)
        spec.equal(value, '草稿'); spec.equal(edit, false); spec.nil_value(sent)
        for _, prop in ipairs({rg.BORDER_WIDTH, rg.BASE_COLOR_NORMAL, rg.BASE_COLOR_FOCUSED,
            rg.BASE_COLOR_PRESSED, rg.BORDER_COLOR_NORMAL, rg.BORDER_COLOR_FOCUSED,
            rg.BORDER_COLOR_PRESSED}) do spec.equal(rg.get_style(rg.TEXTBOX, prop), 42) end
    end)
    spec.it('delegates button activation to raygui and restores its text colors', function()
        local rg = adapter()
        rg.button = function() return false end -- raygui can reject clicks while locked
        spec.equal(surface.button(rg, 0, 0, 100, 40, '发送', {20,30,40,255}, {255,255,255,255}, 9), false)
        spec.equal(rg.get_style(rg.BUTTON, rg.TEXT_COLOR_PRESSED), 42)
        rg.button = function() return true end
        spec.equal(surface.button(rg, 0, 0, 100, 40, '发送', {20,30,40,255}, {255,255,255,255}, 9), true)
    end)
end)

local failed = spec.finish()
return { __init = function() if failed > 0 then os.exit(1) end; xthread.stop(0) end }
