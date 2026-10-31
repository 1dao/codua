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
        lx = 20, rx = 620, iy = 400, INPUT_H = 74, FONT_SIZE = 16,
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
    spec.it('uses the original input and toolbar geometry in both states', function()
        local waiting, normal = frame(true, ''), frame(false, '')
        for _, key in ipairs({'x','y','w','h'}) do spec.equal(waiting.input[key], normal.input[key]) end
        for _, key in ipairs({'x','y','w'}) do spec.equal(waiting.toolbar[key], normal.toolbar[key]) end
        spec.equal(waiting.input.x, 28); spec.equal(waiting.input.y, 400)
        spec.equal(waiting.input.w, 584); spec.equal(waiting.input.h, 74)
        spec.equal(waiting.toolbar.x, 28); spec.equal(waiting.toolbar.w, 584)
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

local failed = spec.finish()
return { __init = function() if failed > 0 then os.exit(1) end; xthread.stop(0) end }
