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

spec.describe('user interface zoom', function()
    spec.it('normalizes saved zoom and bounds manual adjustments', function()
        spec.equal(surface.normalize_scale('0.80\n'), 0.8)
        spec.equal(surface.normalize_scale(0.8 - 0.1), 0.7)
        spec.equal(surface.normalize_scale(0.1), 0.5)
        spec.equal(surface.normalize_scale(9), 2)
    end)
    spec.it('defaults to 100% for missing or invalid preferences and supports older runtimes', function()
        for _, value in ipairs({'', 'broken', 0, -1, 0/0, math.huge}) do
            spec.equal(surface.normalize_scale(value), 1)
        end
        spec.equal(surface.normalize_scale(nil), 1)
        spec.nil_value(surface.adapt_display({}))
    end)
    spec.it('retains user zoom across resolutions and DPI changes without scaling OS bounds twice', function()
        local info, applied
        local rg = {
            display_info = function() return info end,
            set_ui_scale = function(scale) applied = scale end,
        }
        info = {width=1366, height=768, dpi_x=1, dpi_y=1, ui_scale=1,
            window_scale_x=1, window_scale_y=1, window_width=960, window_height=700}
        local result = surface.adapt_display(rg, 0.8)
        spec.equal(applied, 0.8)
        spec.equal(result.window_scale_x, 0.8)
        spec.equal(result.window_width, 960)
        -- Move the same window from the compact monitor to a 4K/200% monitor.
        info = {width=3840, height=2160, dpi_x=2, dpi_y=2, ui_scale=0.8,
            window_scale_x=1.6, window_scale_y=1.6, window_width=1920, window_height=1400}
        result = surface.adapt_display(rg, 0.8)
        spec.equal(applied, 0.8)
        spec.equal(result.window_scale_x, 1.6)
        spec.equal(result.window_scale_y, 1.6)
        spec.equal(result.window_width, 1920)
        spec.equal(result.window_height, 1400)
    end)
    spec.it('does not enlarge the default UI based on a high monitor resolution', function()
        local rg = {display_info=function() return {width=7680,height=4320,dpi_x=2,dpi_y=2,ui_scale=1} end,
            set_ui_scale=function(value) spec.equal(value,1) end}
        spec.equal(surface.adapt_display(rg).ui_scale,1)
    end)
end)

spec.describe('available window space', function()
    spec.it('prioritizes the selected settings panel and restores both sidebars when wide enough', function()
        local left,right=surface.panel_visibility(650,true,true,300)
        spec.equal(left,false); spec.equal(right,false)
        left,right=surface.panel_visibility(800,true,true,300)
        spec.equal(left,false); spec.equal(right,true)
        left,right=surface.panel_visibility(1000,true,true,300)
        spec.equal(left,true); spec.equal(right,true)
        left,right=surface.panel_visibility(800,true,false,300)
        spec.equal(left,true); spec.equal(right,false)
    end)
    spec.it('reduces composer whitespace in short windows while leaving fonts alone', function()
        spec.equal(surface.composer_height(620),78)
        spec.equal(surface.composer_height(300),54)
        spec.equal(surface.composer_height(100),42)
    end)
end)

local failed = spec.finish()
return { __init = function() if failed > 0 then os.exit(1) end; xthread.stop(0) end }
