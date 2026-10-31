package.path = 'scripts/?.lua;' .. package.path
local spec = dofile('tests/lua/spec_helper.lua')
local json = require('xutils')
local tool = require('xagent.tools.ask_user_question')
local ui = require('xagent.ui.user_input')
local registry = require('xagent.tools.registry')
local runner = require('xagent.core.tools_run')
local session = require('xagent.session.session')
local provider = require('xagent.llm.provider')
local console = require('xagent.ui.console_input')
registry.register(tool)

local function request()
    return { questions = {
        { id = 'target', question = '选择目标平台', options = {
            { label = '桌面', description = '本机运行' }, { label = '网页' },
        } },
        { id = 'features', question = '需要哪些功能？', multi_select = true, options = {
            { label = '搜索' }, { label = '历史' },
        } },
        { id = 'details', question = '补充说明' },
    } }
end
local function answers()
    return { target = { selected = { '网页' }, text = '优先手机访问' },
        features = { selected = { '搜索', '历史' } }, details = { text = '中文界面\n保留换行' } }
end

spec.describe('AskUserQuestion contract', function()
    spec.it('returns selected labels and Unicode text as structured tool results', function()
        local res = tool.call(request(), { request_user_input = function(req)
            spec.equal(req.questions[1].options[2].description, '')
            return { answers = answers() }
        end })
        spec.nil_value(res.is_error)
        local result = assert(json.json_unpack(res.content)).answers
        spec.equal(result.target.selected[1], '网页')
        spec.equal(#result.features.selected, 2)
        spec.equal(result.details.text, '中文界面\n保留换行')
        spec.contains(res.content, '"selected":[]')
    end)
    spec.it('rejects malformed, duplicate and oversized questions before opening UI', function()
        local bad = { {}, { questions = {} }, { questions = 'bad' } }
        local r = request(); r.questions[2].id = 'target'; bad[#bad + 1] = r
        r = request(); r.questions[1].options[2].label = '桌面'; bad[#bad + 1] = r
        r = request(); r.questions[1].question = string.rep('a', 2001); bad[#bad + 1] = r
        r = request(); r.questions[1].multi_select = 'yes'; bad[#bad + 1] = r
        r = request(); r.questions[1].options = { { label = 'only' } }; bad[#bad + 1] = r
        for _, input in ipairs(bad) do
            local res = tool.call(input, { request_user_input = function() error('must not show UI') end })
            spec.truthy(res.is_error)
            spec.contains(res.content, 'Error:')
        end
    end)
    spec.it('never treats empty, missing or invalid replies as answers', function()
        for _, value in ipairs({ {}, { target = { text = '  ' } },
            { target = { selected = { 'invalid' } } },
            { target = { selected = { '桌面', '网页' } } } }) do
            local res = tool.call(request(), { request_user_input = function() return { answers = value } end })
            spec.truthy(res.is_error)
        end
        spec.truthy(tool.call(request(), {}).is_error)
        local res = tool.call(request(), { request_user_input = function() return { cancelled = true } end })
        spec.truthy(res.is_error); spec.truthy(json.json_unpack(res.content).cancelled)
    end)
    spec.it('accepts free text instead of a suggested choice and bypasses write approval', function()
        local a = answers(); a.target = { text = '命令行' }
        local res = runner.run({ { type = 'tool_use', id = 'q1', name = tool.name, input = request() } }, {
            confirm = function() error('questions must not request write permission') end,
            request_user_input = function() return { answers = a } end,
        })
        spec.nil_value(res[1].is_error); spec.equal(res[1].tool_use_id, 'q1')
        spec.contains(res[1].content, '命令行')
    end)
end)

spec.describe('question UI lifecycle and session loop', function()
    spec.it('parks each tab independently and clears before resuming consecutive questions', function()
        local first, second = { sess = {} }, { sess = {} }
        local count = 0
        local co = coroutine.create(function()
            local ask = ui.bind(first, first.sess)
            ask(assert(tool.validate(request()))); count = count + 1
            ask(assert(tool.validate(request()))); count = count + 1
        end)
        assert(coroutine.resume(co))
        local co2 = coroutine.create(function() ui.bind(second, second.sess)(assert(tool.validate(request()))) end)
        assert(coroutine.resume(co2))
        local previous = first.pending_input
        ui.resolve(first, { answers = answers() })
        spec.equal(count, 1); spec.truthy(first.pending_input ~= previous); spec.truthy(second.pending_input)
        ui.cancel(first); ui.cancel(second)
        spec.equal(count, 2); spec.equal(coroutine.status(co2), 'dead')
        spec.nil_value(first.pending_input)
        spec.truthy(ui.bind(first, {})(request()).cancelled)
        first.sess.cancelled = true
        spec.truthy(ui.bind(first, first.sess)(request()).cancelled)
    end)

    local function run_session(cancel)
        local old = provider.stream_message
        local calls, executed, res = 0, 0
        registry.register({ name = 'AfterQuestionTest', call = function() executed = executed + 1; return { content = 'ok' } end })
        local s = session.new({ cfg = { model = 'offline-test' }, tools = registry.to_api_params(), system = 'offline' })
        local tab = { sess = s }
        s.request_user_input = ui.bind(tab, s)
        s:add_user('Help me choose')
        provider.stream_message = function(_, params, cb)
            calls = calls + 1
            if calls == 1 then
                cb.on_done({ stop_reason = 'tool_use', usage = {}, message = { role = 'assistant', content = {
                    { type = 'tool_use', id = 'q1', name = tool.name, input = request() },
                    { type = 'tool_use', id = 'after', name = 'AfterQuestionTest', input = {} },
                } } })
            else
                spec.contains(params.messages[#params.messages].content[1].content, '网页')
                cb.on_done({ stop_reason = 'end_turn', usage = {}, message = { role = 'assistant', content = '收到回答' } })
            end
        end
        local ok, err = pcall(function()
            local co = coroutine.create(function() res = s:run() end)
            assert(coroutine.resume(co))
            spec.equal(coroutine.status(co), 'suspended'); spec.equal(calls, 1); spec.equal(executed, 0)
            if cancel then s.cancelled = true; ui.cancel(tab)
            else ui.resolve(tab, { answers = answers() }) end
            spec.equal(coroutine.status(co), 'dead')
            spec.equal(res.stop_reason, cancel and 'cancelled' or 'end_turn')
            spec.equal(calls, cancel and 1 or 2); spec.equal(executed, cancel and 0 or 1)
            spec.equal(s.messages[3].content[1].tool_use_id, 'q1')
            spec.equal(s.messages[3].content[2].tool_use_id, 'after')
            local path = assert(s:save('.'))
            local restored = assert(session.load(path, { cfg = s.cfg })); os.remove(path)
            spec.equal(restored.transcript[3].content[1].tool_use_id, 'q1')
            if not cancel then spec.contains(restored.transcript[3].content[1].content, '中文界面') end
        end)
        provider.stream_message = old; registry.unregister('AfterQuestionTest')
        assert(ok, err)
    end
    spec.it('waits for submission, continues the model and persists the answer', function() run_session(false) end)
    spec.it('cancels while waiting and pairs later tool results without running them', function() run_session(true) end)
end)

spec.describe('question card controls', function()
    local function form(input, width, height)
        local req = assert(tool.validate(input or request()))
        local tab, result = { sess = {} }
        local co = coroutine.create(function() result = ui.bind(tab, tab.sess)(req) end)
        assert(coroutine.resume(co))
        local mx, my, down, typed, enter, locked = 0, 0, false
        local texts = {}
        local rg = {
            draw_rectangle = function(...)
                local values = {...}
                for _, value in ipairs(values) do assert(value % 1 == 0, 'native rectangles require integers') end
                assert(values[3] >= 0 and values[4] >= 0, 'rectangle size must be positive')
            end,
            draw_text = function(label, x, y) texts[label] = {x=x,y=y} end,
            measure_text = function(s) return utf8.len(s) * 8 end,
            get_mouse = function() return mx, my end, get_wheel = function() return 0 end,
            mouse_down = function() return down end,
            begin_scissor = function() end, end_scissor = function() end,
            textbox_multi = function(_, _, _, _, value, edit) return typed or value, edit, enter end,
        }
        local function draw()
            texts = {}
            ui.draw(tab, rg, 0, 0, width or 600, height or 380,
                { bg = {255,255,255}, text = {32,33,36}, accent = {65,128,255} }, locked,
                function(t) t.sess.cancelled = true; ui.cancel(t) end)
        end
        local f = {tab=tab, result=function() return result end}
        function f.frame(value, submitted, blocked)
            typed, enter, locked = value, submitted, blocked; draw()
        end
        function f.click(label, blocked)
            typed, enter, locked = nil, false, blocked
            draw()
            local location = assert(texts[label], 'missing control: ' .. label)
            mx, my = location.x + 3, location.y + 3
            down = true; draw(); down = false; draw()
        end
        f.frame()
        return f
    end
    spec.it('advances on clicks and Enter, preserves navigation and completes the final input', function()
        local f = form()
        f.click('下一步'); spec.equal(f.tab.pending_input.index, 1)
        f.frame('', true); spec.truthy(f.tab.pending_input.error)
        f.click('桌面', true); spec.equal(f.tab.pending_input.index, 1)
        f.frame('草稿'); spec.equal(f.tab.pending_input.index, 1)
        f.click('桌面'); spec.equal(f.tab.pending_input.index, 2)
        spec.equal(f.tab.pending_input.answers.target.text, '')
        spec.equal(#f.tab.pending_input.answers.features.selected, 0)
        f.click('‹'); spec.equal(f.tab.pending_input.index, 1)
        f.frame('命令行', true); spec.equal(f.tab.pending_input.index, 2)
        spec.equal(#f.tab.pending_input.answers.target.selected, 0)
        f.click('搜索'); f.click('历史')
        spec.equal(f.tab.pending_input.index, 2)
        spec.equal(#f.tab.pending_input.answers.features.selected, 2)
        f.click('下一步'); spec.equal(f.tab.pending_input.index, 3)
        f.click('‹'); spec.equal(f.tab.pending_input.index, 2)
        f.frame(nil, true); spec.equal(f.tab.pending_input.index, 3)
        f.frame('自由输入'); spec.truthy(f.tab.pending_input)
        f.frame('自由输入', true)
        spec.nil_value(f.tab.pending_input)
        spec.equal(f.result().answers.details.text, '自由输入')
        spec.equal(#f.result().answers.features.selected, 2)
    end)
    spec.it('auto-submits a final single choice and supports the input-row next button', function()
        local input = { questions = { request().questions[1] } }
        local f = form(input)
        f.click('网页')
        spec.nil_value(f.tab.pending_input)
        spec.equal(f.result().answers.target.selected[1], '网页')
        f = form(input); f.frame('自定义'); f.click('下一步')
        spec.equal(f.result().answers.target.text, '自定义')
    end)
    spec.it('records skips explicitly and redirects header navigation to unanswered questions', function()
        local f = form()
        f.click('›'); spec.equal(f.tab.pending_input.index, 2)
        f.click('›'); spec.equal(f.tab.pending_input.index, 3)
        f.frame('notes', true)
        spec.equal(f.tab.pending_input.index, 1)
        f.click('跳过'); spec.equal(f.tab.pending_input.index, 2)
        f.click('跳过'); spec.equal(f.tab.pending_input.index, 3)
        f.click('下一步')
        spec.nil_value(f.tab.pending_input)
        spec.truthy(f.result().answers.target.skipped)
        spec.truthy(f.result().answers.features.skipped)
        spec.equal(f.result().answers.details.text, 'notes')
    end)
    spec.it('closes the card by cancelling and renders within a narrow viewport', function()
        local f = form(nil, 344, 200)
        f.click('×')
        spec.nil_value(f.tab.pending_input); spec.truthy(f.tab.sess.cancelled)
        spec.truthy(f.result().cancelled)
    end)
end)
spec.describe('interactive console', function()
    spec.it('retries invalid choices, handles multiple selections and free text', function()
        local lines, i = { '9', '2', '1,2', 'text:123' }, 0
        local reply = console.request(assert(tool.validate(request())), function() i = i + 1; return lines[i] end, function() end)
        spec.equal(reply.answers.target.selected[1], '网页')
        spec.equal(#reply.answers.features.selected, 2); spec.equal(reply.answers.details.text, '123')
    end)
    spec.it('cancels on EOF or explicit cancellation', function()
        spec.truthy(console.request(assert(tool.validate(request())), function() end, function() end).cancelled)
        spec.truthy(console.request(assert(tool.validate(request())), function() return '/cancel' end, function() end).cancelled)
    end)
end)

local failed = spec.finish()
return { __init = function() if failed > 0 then os.exit(1) end; xthread.stop(0) end }
