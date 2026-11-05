-- Exercise the production composer branch without a window or model request.
package.path = 'scripts/?.lua;' .. package.path
local spec = dofile('tests/lua/spec_helper.lua')
local file = assert(io.open('scripts/xagent/gui.lua', 'rb'))
local source = file:read('*a'); file:close()
assert(load(source, '@gui.lua'))
local first = assert(source:find('    local new_input, submitted, new_edit', 1, true))
local last = assert(source:find('    -- the "+" new-tab model picker', first, true))
local composer = source:sub(first, last - 1)

local function frame(answering, draft)
    local input, toolbar, placeholder, sent
    local tab = { input = draft, input_edit = true }
    local env = setmetatable({
        answering = answering, modal = false, tab = tab, S = {},
        lx = 20, rx = 620, iy = 400, INPUT_H = 78, FONT_SIZE = 16,
        composer_x = 52, composer_w = 536, card_bg = {},
        surface = { editor = function(rg, bg, ...) return rg.textbox_multi(...) end },
        raygui = { textbox_multi = function(x, y, w, h, value, edit)
            input = {x=x, y=y, w=w, h=h, value=value, edit=edit}
            return 'new text', true, true
        end },
        draw_composer_toolbar = function(_, x, y, w) toolbar = {x=x, y=y, w=w}; return false end,
        draw_text_col = function(text) placeholder = text end,
        fit_label = function(text) return text end, muted_col = function() return {} end,
        update_completion_menu = function() end, draw_completion_menu = function() end,
        submit = function() sent = true end,
    }, {__index=_G})
    assert(load(composer, '@gui-composer', 't', env))()
    return { input=input, toolbar=toolbar, placeholder=placeholder, tab=tab, sent=sent }
end

spec.describe('GUI composer while answering questions', function()
    spec.it('uses the same input and toolbar geometry in both states', function()
        local waiting, normal = frame(true, ''), frame(false, '')
        for _, key in ipairs({'x','y','w','h'}) do spec.equal(waiting.input[key], normal.input[key]) end
        for _, key in ipairs({'x','y','w'}) do spec.equal(waiting.toolbar[key], normal.toolbar[key]) end
        spec.equal(waiting.input.x, 52); spec.equal(waiting.input.y, 400)
        spec.equal(waiting.input.w, 536); spec.equal(waiting.input.h, 78)
        spec.equal(waiting.toolbar.x, 52); spec.equal(waiting.toolbar.w, 536)
        spec.contains(waiting.placeholder, '问点什么，或描述一个任务')
        spec.nil_value(waiting.sent); spec.truthy(normal.sent)
    end)
    spec.it('preserves the composer draft and leaves keyboard input to the question card', function()
        local waiting = frame(true, 'existing draft')
        spec.equal(waiting.input.value, 'existing draft')
        spec.equal(waiting.input.edit, false)
        spec.equal(waiting.tab.input, 'existing draft')
        spec.equal(waiting.tab.input_edit, true)
        spec.nil_value(waiting.sent)
        local normal = frame(false, 'existing draft')
        spec.equal(normal.input.edit, true)
        spec.equal(normal.tab.input, 'new text')
        spec.truthy(normal.sent)
    end)
end)

spec.describe('GUI display transitions', function()
    spec.it('saves zoom separately from fonts, defers application, and preserves state on save failure', function()
        local first=assert(source:find('local function set_ui_scale(value)',1,true))
        local last=assert(source:find('local function unpack_color',first,true))
        local saved, fail_write
        local state={ui_scale=1, tabs={{}}, active=1, dd_open='menu'}
        local env=setmetatable({S=state,UI_SCALE_FILE='/home/test/.xagent/ui_scale',
            surface=require('xagent.ui.surface'),fs={
                mkdirp=function(path) spec.equal(path,'/home/test/.xagent') end,
                write_file=function(path,data)
                    spec.equal(path,'/home/test/.xagent/ui_scale')
                    if fail_write then return nil,'read only' end
                    saved=data; return true
                end,
            },
        },{__index=_G})
        local set_zoom=assert(load(source:sub(first,last-1)..'\nreturn set_ui_scale','@zoom','t',env))()
        spec.truthy(set_zoom(0.8))
        spec.equal(state.ui_scale,0.8)
        spec.equal(require('xagent.ui.surface').normalize_scale(saved),0.8)
        spec.nil_value(state.display) -- native application waits for refresh_display
        spec.nil_value(state.dd_open)
        fail_write=true
        spec.equal(set_zoom(0.7),false)
        spec.equal(state.ui_scale,0.8)
        spec.contains(state.tabs[1].status,'read only')
        fail_write=false
        spec.truthy(set_zoom(1))
        spec.equal(saved,'1.00\n')
        spec.nil_value(state.scale_error)
    end)
    spec.it('invalidates transcript metrics only when scale or DPI changes', function()
        local first = assert(source:find('local function refresh_display()', 1, true))
        local last = assert(source:find('local SIDEBAR_W', first, true))
        local invalidated, display = 0, {ui_scale=1, dpi_x=1, dpi_y=1}
        local view = {invalidate=function() invalidated=invalidated+1 end}
        local state = {tabs={{view=view}, {view=view}}, log_view=view}
        local env = setmetatable({S=state, raygui={}, surface={
            adapt_display=function() return display end,
        }}, {__index=_G})
        local refresh = assert(load(source:sub(first, last-1) .. '\nreturn refresh_display', '@display', 't', env))()
        refresh()
        spec.equal(invalidated, 0)
        display={ui_scale=1, dpi_x=1, dpi_y=1}; refresh()
        spec.equal(invalidated, 0)
        display={ui_scale=1, dpi_x=2, dpi_y=2}; refresh()
        spec.equal(invalidated, 3)
        display={ui_scale=0.85, dpi_x=2, dpi_y=2}; refresh()
        spec.equal(invalidated, 6)
    end)
end)

local failed = spec.finish()
return { __init = function() if failed > 0 then os.exit(1) end; xthread.stop(0) end }
