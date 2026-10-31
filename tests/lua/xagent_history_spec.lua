-- Offline: the UI transcript survives compaction; forks and turn deletion.
-- Run: bin/xnet tests/lua/xagent_history_spec.lua
package.path = 'scripts/?.lua;' .. package.path
local utils = require('xutils')
local session = require('xagent.session.session')
local loop = require('xagent.core.loop')
local compaction = require('xagent.context.compaction')
local function test_history_groups()
    local spec = dofile('tests/lua/spec_helper.lua')
    local file = assert(io.open('scripts/xagent/gui.lua', 'rb'))
    local source = file:read('*a'); file:close()
    local first = assert(source:find('local function build_history_groups(', 1, true))
    local last = assert(source:find('local function draw_history_sidebar(', first, true))
    local build_history_groups = assert(load(source:sub(first, last - 1) .. '\nreturn build_history_groups', '@gui-history-groups'))()
    local items = {
        { id = 'a1', cwd = 'C:/work/alpha', title = 'Investigate parser' },
        { id = 'b1', cwd = 'C:/work/beta', title = 'Update settings' },
        { id = 'a2', cwd = 'c:\\work\\ALPHA\\', title = 'Improve tests' },
        { id = 'c1', cwd = 'C:/work/gamma', title = 'Fix parser' },
    }
    local function key(dir) return dir:gsub('\\', '/'):gsub('/+$', ''):lower() end

    spec.describe('history project overview', function()
        spec.it('retains every project and session count when collapsed', function()
            local groups, shown = build_history_groups(items, '', true, {}, key)
            spec.equal(#groups, 3); spec.equal(shown, 4)
            spec.equal(groups[1].key, 'c:/work/alpha')
            spec.equal(groups[2].key, 'c:/work/beta')
            spec.equal(groups[3].key, 'c:/work/gamma')
            spec.equal(#groups[1].items, 2)
            for _, group in ipairs(groups) do spec.equal(group.expanded, false) end
        end)
        spec.it('expands one project without hiding the others', function()
            local groups = build_history_groups(items, '', true, { ['c:/work/beta'] = true }, key)
            spec.equal(#groups, 3)
            spec.equal(groups[1].expanded, false)
            spec.equal(groups[2].expanded, true)
            spec.equal(groups[3].expanded, false)
            spec.equal(groups[2].items[1].id, 'b1')
        end)
        spec.it('supports individual folding and expand-all reset', function()
            local groups = build_history_groups(items, '', false, { ['c:/work/alpha'] = false }, key)
            spec.equal(groups[1].expanded, false); spec.equal(groups[2].expanded, true)
            groups = build_history_groups(items, '', false, {}, key)
            for _, group in ipairs(groups) do spec.equal(group.expanded, true) end
        end)
        spec.it('finds conversation titles across projects while folded', function()
            local groups, shown = build_history_groups(items, ' PARSER ', true, {}, key)
            spec.equal(#groups, 2); spec.equal(shown, 2)
            spec.equal(groups[1].items[1].id, 'a1')
            spec.equal(groups[2].items[1].id, 'c1')
            for _, group in ipairs(groups) do spec.equal(group.expanded, true) end
        end)
        spec.it('finds a project by directory and preserves its conversation order', function()
            local groups, shown = build_history_groups(items, 'alpha', true, {}, key)
            spec.equal(#groups, 1); spec.equal(shown, 2)
            spec.equal(groups[1].items[1].id, 'a1'); spec.equal(groups[1].items[2].id, 'a2')
        end)
        spec.it('handles empty and unmatched history', function()
            local groups, shown = build_history_groups({}, '', true, {}, key)
            spec.equal(#groups, 0); spec.equal(shown, 0)
            groups, shown = build_history_groups(items, 'missing', false, {}, key)
            spec.equal(#groups, 0); spec.equal(shown, 0)
        end)
    end)

    assert(spec.finish() == 0, "History grouping tests failed")
end

local function run()
    local dir = utils.cwd():gsub('\\', '/') .. '/tmp/history-test'
    assert(utils.mkdir_p(dir))
    local blank = session.new({id='empty',title='New workspace'})
    assert(not blank:has_user_input())
    assert(not blank:save(dir))
    assert(not io.open(dir .. '/empty.json','rb'))
    blank:add_user(' \t\n')
    blank.messages[#blank.messages+1] = {role='user',content={{type='tool_result',content='background probe'}}}
    assert(not blank:save(dir))
    local empty_file = assert(io.open(dir .. '/empty.json','wb'))
    empty_file:write(assert(utils.json_pack(blank:to_table()))); empty_file:close()
    for _, item in ipairs(session.list(dir)) do assert(item.id ~= 'empty', 'Legacy blank session leaked into history') end
    assert(session.delete(dir .. '/empty.json'))
    local image = session.new({id='image'})
    image:add_user({{type='image',source={data='test'}}})
    assert(image:has_user_input()); assert(image:save(dir)); assert(session.delete(dir .. '/image.json'))
    print('PASS blank sessions never save, legacy blanks stay hidden, attachments count as input')
    local s = session.new({ system = 'test', cwd = dir })
    s:add_user('原始问题：保留这段历史')
    loop.run = function(opts)
        local answer = { role = 'assistant', content = { { type = 'text', text = '压缩前的原始回答' } } }
        opts.messages[#opts.messages + 1] = answer
        opts.on_event({ type = 'assistant', message = answer })
        local result = { content = '完整工具结果，不应被压缩清除' }
        opts.on_event({ type = 'tool_result', id = 't1', result = result })
        answer.content[1].text = 'mutated'; result.content = 'cleared'
        compaction.replace_in_place(opts.messages, { { role = 'user', content = '压缩摘要' } })
        return { usage = { input_tokens = 1, output_tokens = 1 } }
    end
    s:run()
    assert(#s.messages == 1 and #s.transcript == 3)
    assert(s.transcript[1].content == '原始问题：保留这段历史')
    assert(s.transcript[2].content[1].text == '压缩前的原始回答')
    assert(s.transcript[3].content[1].content == '完整工具结果，不应被压缩清除')
    s:add_user('继续对话')
    local path = assert(s:save(dir))
    local loaded = assert(session.load(path, { system = 'test' }))
    assert(#loaded.messages == 2 and #loaded.transcript == 4)
    assert(loaded.transcript[1].content == '原始问题：保留这段历史')
    loaded.messages[1].content = 'again'; assert(loaded.transcript[1].content ~= 'again')
    print('PASS full transcript survives compaction, mutation, save and reload')
    local branch = loaded:fork()
    assert(branch.id ~= loaded.id and branch.parent_id == loaded.id)
    assert(branch.skill_id == loaded.skill_id and #branch.transcript == #loaded.transcript)
    local original_dir = session.dir
    session.dir = function() return dir end
    local numbered = loaded:fork()
    assert(numbered.title == loaded.title .. ' · 分叉 1')
    local numbered_path = assert(numbered:save())
    local next_branch = loaded:fork()
    assert(next_branch.title == loaded.title .. ' · 分叉 2')
    local next_path = assert(next_branch:save())
    assert(numbered:fork().title == loaded.title .. ' · 分叉 3')
    assert(session.delete(numbered_path)); assert(session.delete(next_path))
    session.dir = original_dir
    print('PASS sibling forks and nested forks receive distinct numbered titles')
    branch.transcript[1].content = 'branch change'
    assert(loaded.transcript[1].content ~= 'branch change')
    local shortened = loaded:without_last_turn()
    assert(#shortened.transcript == 3 and #shortened.messages == 3 and shortened:turn_count() == 1)
    assert(shortened.messages[1].content == '原始问题：保留这段历史')
    assert(#loaded.transcript == 4 and loaded:turn_count() == 2)
    assert(not shortened:without_last_turn():has_user_input())
    local paired = session.new()
    paired:add_user('first')
    paired.transcript[#paired.transcript+1] = {role='assistant',content={{type='tool_use',id='one',name='Write',input={}}}}
    paired.transcript[#paired.transcript+1] = {role='user',content={{type='tool_result',tool_use_id='one',content='ok'}}}
    paired:add_user('second')
    paired.transcript[#paired.transcript+1] = {role='assistant',content={{type='tool_use',id='two',name='Write',input={}}}}
    paired.transcript[#paired.transcript+1] = {role='user',content={{type='tool_result',tool_use_id='two',content='ok'}}}
    local kept = paired:without_last_turn()
    assert(#kept.messages == 3 and kept.messages[2].content[1].id == kept.messages[3].content[1].tool_use_id)
    print('PASS independent forks and tail turn removal preserve retained tool pairs and discard compacted summaries')
    paired:add_user('third')
    local middle = paired:without_turn(2)
    assert(middle:turn_count() == 2 and #middle.messages == 4 and middle.messages[4].content == 'third')
    assert(middle.messages[2].content[1].id == 'one' and middle.messages[3].content[1].tool_use_id == 'one')
    local prefix = paired:fork(1)
    assert(prefix:turn_count() == 1 and #prefix.messages == 3 and paired:turn_count() == 3)
    local first_removed = paired:without_turn(1)
    assert(first_removed:turn_count() == 2 and first_removed.messages[1].content == 'second')
    assert(first_removed.title == 'second')
    print('PASS selected-round deletion preserves later turns and selected-round fork excludes later turns')
    local legacy = s:to_table(); legacy.transcript = nil; legacy.version = 1
    local file = assert(io.open(dir .. '/legacy.json', 'wb')); file:write(assert(utils.json_pack(legacy))); file:close()
    local old = assert(session.load(dir .. '/legacy.json'))
    assert(#old.transcript == #old.messages)
    print('PASS legacy sessions remain readable')
    assert(session.delete(path)); assert(not io.open(path, 'rb'))
    assert(session.delete(dir .. '/legacy.json'))
    print('PASS session deletion removes persisted transcript')
end
return { __init = function()
    local ok, err = xpcall(function() test_history_groups(); run() end, debug.traceback)
    if not ok then print(err) end
    xthread.stop(ok and 0 or 1)
end }
