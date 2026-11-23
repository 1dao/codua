-- Regression: submitting a new question must re-arm tail-follow, so the answer
-- streams into view even if the user had scrolled up to read earlier history.
package.path = 'scripts/?.lua;' .. package.path
local spec = dofile('tests/lua/spec_helper.lua')
local transcript = require('xagent.ui.transcript')

-- Extract the production add() from gui.lua and run it without a window
-- (same source-slice technique as xagent_gui_user_input_spec.lua).
local file = assert(io.open('scripts/xagent/gui.lua', 'rb'))
local source = file:read('*a'); file:close()
local first = assert(source:find('local function add(tab, role, text)', 1, true))
local last = assert(source:find('\nend\n', first, true))
local add = assert(load(source:sub(first, last + 4) .. '\nreturn add',
    '@gui-add', 't', setmetatable({}, { __index = _G })))()

spec.describe('GUI add() re-arms tail-follow on a new question', function()
    spec.it('sets follow when a user message is appended', function()
        local tab = { entries = {}, view = { follow = false } }
        local e = add(tab, 'user', '新问题')
        spec.equal(#tab.entries, 1)
        spec.equal(e.role, 'user')
        spec.truthy(tab.view.follow, 'a new question must snap the view back to the tail')
    end)
    spec.it('leaves follow alone for streaming roles (scrolled-up reader stays put)', function()
        local tab = { entries = {}, view = { follow = false } }
        add(tab, 'assistant', 'hi')
        add(tab, 'tool', '> read')
        add(tab, 'tool_result', 'ok')
        add(tab, 'system', 'notice')
        spec.equal(tab.view.follow, false)
    end)
end)

-- Offline raygui double: width = 8px per byte; pointer/wheel are controllable.
-- Style/button stubs cover the hover copy-button path (surface.button).
local function adapter(wheel, over)
    local calls = {}
    local rg = {
        measure_text = function(s) return #s * 8 end,
        get_mouse = function() if over then return 100, 100 else return -1, -1 end end,
        get_wheel = function() return wheel or 0 end,
        draw_rectangle = function() end,
        begin_scissor = function() end,
        end_scissor = function() end,
        draw_text = function(text, x, y) calls[#calls + 1] = { text = text, y = y } end,
        BUTTON = 1, BORDER_WIDTH = 2, BASE_COLOR_NORMAL = 3, BASE_COLOR_FOCUSED = 4,
        BASE_COLOR_PRESSED = 5, TEXT_COLOR_NORMAL = 6, TEXT_COLOR_FOCUSED = 7,
        TEXT_COLOR_PRESSED = 8,
        get_style = function() return 0 end,
        set_style = function() end,
        button = function() return false end,
    }
    return rg, calls
end

local function tail_drawn(calls, text)
    for _, c in ipairs(calls) do
        if c.text == text and c.y >= 0 and c.y <= 300 then return true end
    end
    return false
end

spec.describe('transcript tail-follow mechanics', function()
    spec.it('wheel-up stops following; re-arming follow shows the streaming tail again', function()
        local entries = {}
        for i = 1, 6 do
            entries[#entries + 1] = { role = 'assistant',
                text = string.rep('line ' .. i .. ' word word word word\n', 12) }
        end
        local tail = 'line 6 word word word word'

        local rg = adapter(0, false)
        local view = transcript.new_view({ raygui = rg, font_size = 16 })
        view:draw(entries, 0, 0, 400, 300)
        spec.truthy(view.follow, 'chat views follow the tail by default')
        spec.truthy(view.scroll > 0, 'content overflows the viewport')

        -- Wheel up over the view (10 notches): follow breaks and the tail
        -- leaves the viewport.
        local rg2, calls2 = adapter(10, true)
        view.rg = rg2
        view:draw(entries, 0, 0, 400, 300)
        spec.equal(view.follow, false)
        spec.equal(tail_drawn(calls2, tail), false, 'scrolled-up view must not chase the tail')

        -- What add() now does on submit: re-arm follow -> next frame snaps back.
        local rg3, calls3 = adapter(0, false)
        view.rg = rg3
        view.follow = true
        view:draw(entries, 0, 0, 400, 300)
        spec.truthy(view.follow)
        spec.truthy(tail_drawn(calls3, tail), 're-armed follow must bring the tail back into view')
    end)
end)

local failed = spec.finish()
return { __init = function() if failed > 0 then os.exit(1) end; xthread.stop(0) end }