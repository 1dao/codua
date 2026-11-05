-- Offline specs for M2: session JSON round-trip (incl. tool blocks) and project
-- memory loading. No network. Run via: bin/xnet tests/lua/xagent_session_spec.lua

package.path = 'scripts/?.lua;' .. package.path

local spec = dofile('tests/lua/spec_helper.lua')
local session = require('xagent.session.session')
local project_md = require('xagent.context.project_md')
local fs = dofile('scripts/core/share/xfs.lua')

spec.describe('session persistence', function()
    spec.it('round-trips messages with tool_use/tool_result through JSON', function()
        local s = session.new({ cfg = { model = 'mdl' }, cwd = '/work' })
        s:add_user('hello')
        s.messages[#s.messages + 1] = {
            role = 'assistant',
            content = {
                { type = 'text', text = 'hi' },
                { type = 'tool_use', id = 't1', name = 'Read', input = { file_path = 'a.lua' } },
            },
        }
        s.messages[#s.messages + 1] = {
            role = 'user',
            content = { { type = 'tool_result', tool_use_id = 't1', content = 'data', is_error = true } },
        }
        s.usage.input_tokens = 123

        local path = assert(s:save('.'))           -- writes ./<id>.json
        local s2 = assert(session.load(path, { cfg = { model = 'mdl' } }))
        os.remove(path)

        spec.equal(s2.id, s.id)
        spec.equal(#s2.messages, 3)
        spec.equal(s2.messages[1].content, 'hello')
        spec.equal(s2.messages[2].content[2].name, 'Read')
        spec.equal(s2.messages[2].content[2].input.file_path, 'a.lua')
        spec.equal(s2.messages[3].content[1].is_error, true)
        spec.equal(s2.usage.input_tokens, 123)
    end)
end)

spec.describe('session skills listing', function()
    local skills = require('xagent.skills')
    local listing = '<system-reminder>\nskills A\n</system-reminder>'
    local function with_listing(text, fn)
        local saved = skills.reminder
        skills.reminder = function() return text end
        local ok, err = pcall(fn)
        skills.reminder = saved
        assert(ok, err)
    end

    spec.it('rides on the turn\'s user message, not the system prompt', function()
        with_listing(listing, function()
            local s = session.new({ cfg = {}, cwd = '/w', system = 'SYS' })
            s:add_user('hello')
            s:inject_skills_listing()
            spec.equal(s.system, 'SYS')
            spec.equal(s.messages[1].content[1].text, 'hello')
            spec.equal(s.messages[1].content[2].text, listing)
            s:ensure_title()
            spec.equal(s.title, 'hello')
            spec.equal(s.transcript[1].content, 'hello', 'the UI transcript must not show the listing')
        end)
    end)

    spec.it('is not repeated while the history already carries it', function()
        with_listing(listing, function()
            local s = session.new({ cfg = {}, cwd = '/w', system = 'SYS' })
            s:add_user('one'); s:inject_skills_listing()
            s.messages[#s.messages + 1] = { role = 'assistant', content = 'ok' }
            s:add_user('two'); s:inject_skills_listing()
            spec.equal(s.messages[3].content, 'two')
        end)
    end)

    spec.it('is appended again once the listing changes', function()
        local s = session.new({ cfg = {}, cwd = '/w', system = 'SYS' })
        with_listing(listing, function() s:add_user('one'); s:inject_skills_listing() end)
        s.messages[#s.messages + 1] = { role = 'assistant', content = 'ok' }
        local newer = listing:gsub('skills A', 'skills A, B')
        with_listing(newer, function() s:add_user('two'); s:inject_skills_listing() end)
        spec.equal(s.messages[3].content[2].text, newer)
    end)
end)

spec.describe('project_md', function()
    spec.it('loads AGENT.md from a directory', function()
        local dir = '_xa_pmtest'
        fs.mkdirp(dir)
        assert(fs.write_file(dir .. '/AGENT.md', '# memory\nrule-alpha\n'))

        local content, found = project_md.load(dir)
        spec.truthy(found, 'found a memory file')
        spec.contains(content or '', 'rule-alpha')

        os.remove(dir .. '/AGENT.md')
        if package.config:sub(1, 1) == '\\' then os.execute('rmdir "' .. dir .. '" >nul 2>nul')
        else os.execute('rmdir "' .. dir .. '" >/dev/null 2>&1') end
    end)

    spec.it('returns nil when no memory file exists', function()
        local content = project_md.load('_xa_definitely_missing_dir_zzz')
        spec.nil_value(content)
    end)
end)

spec.describe('separate instructions and learned memory', function()
    local memory_write = require('xagent.tools.memory_write')
    local system_prompt = require('xagent.context.system_prompt')
    local dir = '_xa_memory_separation_test'
    local files = { 'AGENTS.md', 'AGENT.md', 'CLAUDE.md', 'child/AGENT.md',
        '.xagent/memory/lessons_learned.md' }
    local function with_workspace(fn)
        fs.mkdirp(dir .. '/child')
        local ok, err = pcall(fn)
        for _, file in ipairs(files) do os.remove(dir .. '/' .. file) end
        -- Only remove these known empty fixture directories, never recursively.
        for _, suffix in ipairs({ '/.xagent/memory', '/.xagent', '/child', '' }) do
            local p = dir .. suffix
            if package.config:sub(1, 1) == '\\' then os.execute('rmdir "' .. p .. '" >nul 2>nul')
            else os.execute('rmdir "' .. p .. '" >/dev/null 2>&1') end
        end
        assert(ok, err)
    end

    spec.it('loads canonical and legacy instructions without hiding AGENTS.md', function()
        with_workspace(function()
            assert(fs.write_file(dir .. '/AGENTS.md', 'canonical-rule'))
            assert(fs.write_file(dir .. '/AGENT.md', 'legacy-agent-rule'))
            assert(fs.write_file(dir .. '/CLAUDE.md', 'legacy-claude-rule'))
            local content, first = project_md.load(dir)
            spec.equal(first, dir .. '/AGENTS.md')
            spec.contains(content, 'canonical-rule')
            spec.contains(content, 'legacy-agent-rule')
            spec.contains(content, 'legacy-claude-rule')
            spec.contains(content, 'Source: ' .. dir .. '/AGENTS.md')
        end)
    end)

    spec.it('finds parent AGENTS.md despite a nearer legacy file', function()
        with_workspace(function()
            assert(fs.write_file(dir .. '/AGENTS.md', 'parent-canonical'))
            assert(fs.write_file(dir .. '/AGENT.md', 'parent-legacy'))
            assert(fs.write_file(dir .. '/child/AGENT.md', 'nearest-legacy'))
            local content = project_md.load(dir .. '/child')
            spec.contains(content, 'parent-canonical')
            spec.contains(content, 'nearest-legacy')
            spec.nil_value(content:find('parent-legacy', 1, true))
        end)
    end)

    spec.it('appends memory independently and loads it in a separate prompt section', function()
        with_workspace(function()
            assert(fs.write_file(dir .. '/AGENTS.md', 'canonical-rule'))
            assert(fs.write_file(dir .. '/AGENT.md', 'legacy-rule'))
            for _, note in ipairs({ 'first-lesson', 'second-lesson' }) do
                local result = memory_write.call({ name = note, content = note }, { cwd = dir })
                spec.truthy(not result.is_error, result.content)
            end
            spec.equal(fs.read_file(dir .. '/AGENTS.md'), 'canonical-rule')
            spec.equal(fs.read_file(dir .. '/AGENT.md'), 'legacy-rule')
            local instructions = project_md.load(dir)
            local memory, file = project_md.load_memory(dir)
            spec.equal(file, dir .. '/.xagent/memory/lessons_learned.md')
            spec.contains(memory, 'first-lesson')
            spec.contains(memory, 'second-lesson')
            spec.nil_value(instructions:find('first-lesson', 1, true))
            local prompt = system_prompt.build({ cwd = dir, project_md = instructions, learned_memory = memory })
            spec.contains(prompt, 'canonical-rule')
            spec.contains(prompt, 'Learned project memory')
            spec.contains(prompt, 'first-lesson')
        end)
    end)

    spec.it('creates only learned memory when no instructions exist', function()
        with_workspace(function()
            spec.nil_value(project_md.load_memory(dir))
            local result = memory_write.call({ name = 'lesson', content = 'saved-lesson' }, { cwd = dir })
            spec.truthy(not result.is_error, result.content)
            spec.nil_value(fs.read_file(dir .. '/AGENT.md'))
            spec.nil_value(project_md.load(dir))
            spec.contains(project_md.load_memory(dir), 'saved-lesson')
        end)
    end)

    spec.it('bounds both sources without dropping canonical instructions', function()
        with_workspace(function()
            assert(fs.write_file(dir .. '/AGENTS.md', 'canonical-rule'))
            assert(fs.write_file(dir .. '/AGENT.md', string.rep('x', 30000)))
            fs.mkdirp(dir .. '/.xagent/memory')
            assert(fs.write_file(dir .. '/.xagent/memory/lessons_learned.md', string.rep('y', 20000)))
            local instructions = project_md.load(dir)
            local memory = project_md.load_memory(dir)
            spec.contains(instructions, 'canonical-rule')
            spec.truthy(#instructions < 17000)
            spec.contains(instructions, '[project instructions truncated]')
            spec.truthy(#memory < 8100)
            spec.contains(memory, '[learned memory truncated]')
        end)
    end)

    spec.it('refreshes retrieved notes across sessions without retaining old request context', function()
        with_workspace(function()
            local memory = require('xagent.context.memory')
            local provider = require('xagent.llm.provider')
            local compaction = require('xagent.context.compaction')
            local stream, compact = provider.stream_message, compaction.auto_compact_if_needed
            local requests, budgets = {}, {}
            provider.stream_message = function(_, params, cb)
                requests[#requests + 1] = params.system
                cb.on_done({message={role='assistant',content={{type='text',text='done'}}},
                    stop_reason='end_turn',usage={input_tokens=100,output_tokens=2}})
            end
            compaction.auto_compact_if_needed = function(opts)
                budgets[#budgets + 1] = {system=opts.system, usage=opts.usage}
                return {messages=opts.force and {{role='user',content='This session is being continued: fixture summary.'}} or opts.messages,
                    did_compact=opts.force or false}
            end
            local ok, err = pcall(function()
                assert(not memory_write.call({name='Rust resolution',content='Rust uses concrete impl scope.'},{cwd=dir}).is_error)
                assert(not memory_write.call({name='SQLite locking',content='SQLite uses a busy timeout.'},{cwd=dir}).is_error)
                local s = session.new({cfg={model='fixture'},cwd=dir,system='BASE RULES',tools={}})
                local function run(value)
                    value:run()
                end
                local function turn(value, query)
                    value:add_user(query)
                    local co = coroutine.create(function() run(value) end)
                    local resumed, failure = coroutine.resume(co)
                    assert(resumed, failure)
                    spec.equal(coroutine.status(co), 'dead')
                end
                turn(s, 'Rust resolution')
                spec.contains(requests[1], 'concrete impl scope')
                spec.nil_value(requests[1]:find('busy timeout',1,true))
                spec.equal(s.system, 'BASE RULES', 'the base system must not accumulate selected notes')
                turn(s, 'Rust resolution')
                spec.truthy(budgets[2].usage, 'unchanged memory retains the usage anchor')
                turn(s, 'SQLite locking')
                spec.contains(requests[3], 'busy timeout')
                spec.nil_value(requests[3]:find('concrete impl scope',1,true))
                spec.nil_value(budgets[3].usage, 'changed memory invalidates the usage anchor')
                s:compact()
                spec.equal(budgets[4].system, requests[3], 'manual compaction uses the effective request system')
                spec.contains(s.messages[1].content,'fixture summary','the old message history was replaced')
                turn(s, 'Rust resolution')
                spec.contains(requests[4], 'concrete impl scope', 'retrieval still runs after compaction')
                local saved = assert(s:save(dir))
                local persisted = assert(fs.read_file(saved))
                spec.nil_value(persisted:find('concrete impl scope',1,true), 'retrieved text must not be persisted')
                local loaded = assert(session.load(saved,{cfg=s.cfg,system='BASE RULES',tools={}}))
                os.remove(saved)
                assert(not memory_write.call({name='Rust diagnostics',content='Rust reports the fresh diagnostic marker.'},{cwd=dir}).is_error)
                turn(loaded, 'Rust diagnostics')
                spec.contains(requests[5], 'fresh diagnostic marker', 'resumed sessions read current disk memory')
                local fresh = session.new({cfg=s.cfg,cwd=dir,system='BASE RULES',tools={}})
                turn(fresh, 'Rust diagnostics')
                spec.contains(requests[6], 'fresh diagnostic marker', 'new sessions retrieve the same persisted knowledge')
                spec.equal(memory.prepare('BASE',dir,'unrelated zebra telescope'), 'BASE')
            end)
            provider.stream_message, compaction.auto_compact_if_needed = stream, compact
            assert(ok, err)
        end)
    end)

    spec.it('searches recent notes beyond the scan limit instead of loading an old file prefix', function()
        with_workspace(function()
            fs.mkdirp(dir .. '/.xagent/memory')
            assert(fs.write_file(project_md.memory_path(dir), '## Rust old\n' .. string.rep('padding ',150000) ..
                '\n## Rust recent\nRecent concrete impl guidance.\n'))
            local context = require('xagent.context.memory').retrieve(dir,'Rust')
            spec.contains(context,'Rust recent')
            spec.nil_value(context:find('Rust old',1,true))
            spec.truthy(#context <= 4096)
        end)
    end)
end)

spec.describe('offline learned memory retrieval', function()
    local memory = require('xagent.context.memory')

    spec.it('ranks matching titles ahead of body-only matches and omits unrelated lessons', function()
        local context, selected = memory.select('## SQLite\nDatabase busy timeout.\n## Rust\nUse impl scope.\n' ..
            '## Miscellaneous\nA Rust diagnostic.','Rust')
        spec.equal(selected[1].title,'Rust')
        spec.equal(#selected,2)
        spec.contains(context,'source: .xagent/memory/lessons_learned.md')
        spec.contains(context,'line 3')
        spec.nil_value(context:find('Database busy timeout',1,true))
    end)

    spec.it('matches Chinese phrases and code identifiers without a provider', function()
        local context = memory.select('## 流式响应\n工具参数截断后需要重新发送。\n## 数据库\n配置连接池。',
            '修复工具参数截断')
        spec.contains(context,'流式响应')
        spec.nil_value(context:find('配置连接池',1,true))
        context = memory.select('## Runtime\nCall parse_response before dispatch.\n## CSS\nUse a grid.',
            'scripts/llm/parse_response.lua')
        spec.contains(context,'parse_response')
        spec.nil_value(context:find('Use a grid',1,true))
    end)

    spec.it('omits no-match and generic queries rather than injecting a fallback dump', function()
        local raw = '## Rust\nUse impl scope.'
        spec.nil_value(memory.select(raw,'SQLite database'))
        spec.nil_value(memory.select(raw,'please help fix this project'))
        spec.nil_value(memory.select(raw,''))
        spec.nil_value(memory.select('', 'Rust'))
    end)

    spec.it('searches later entries beyond the old 8000-byte loading cap', function()
        local context = memory.select('## Other\n' .. string.rep('padding ',2000) .. '\n## Rust\nLate Rust lesson.', 'Rust')
        spec.contains(context,'Late Rust lesson')
        spec.truthy(#context < 4096)
    end)

    spec.it('deduplicates exact lessons, limits entries and breaks ties by recency', function()
        local raw = '## Rust duplicate\nSame Rust lesson.\n## Rust duplicate\nSame Rust lesson.\n'
        for i=1,6 do raw=raw..'## Rust '..i..'\nUnique lesson '..i..'.\n' end
        local first, selected = memory.select(raw,'Rust')
        local second = memory.select(raw,'Rust')
        spec.equal(first,second)
        spec.equal(#selected,4)
        spec.equal(selected[1].title,'Rust 6')
        local _, duplicate = memory.select('## Rust\nSame lesson.\n## Rust\nSame lesson.','Rust')
        spec.equal(#duplicate,1)
        spec.equal(duplicate[1].line,3)
    end)

    spec.it('keeps a matching passage within the total UTF-8 byte budget', function()
        local raw='## 运行时\n'..string.rep('无关介绍。',200)..'Rust 关键经验：保留具体实现作用域。'..string.rep('结束。',100)
        local context = memory.select(raw,'Rust',{max_bytes=700})
        spec.truthy(#context<=700)
        spec.truthy(utf8.len(context),'truncation must preserve UTF-8')
        spec.contains(context,'Rust 关键经验')
        spec.contains(context,'must not override explicit user requests')
        spec.nil_value(memory.select(raw,'Rust',{max_bytes=100}))
    end)

    spec.it('does not treat headings inside fenced examples as separate lessons', function()
        local _, selected = memory.select('## Markdown\n```md\n## Rust example\n```\nRust documentation.','Rust')
        spec.equal(#selected,1)
        spec.equal(selected[1].title,'Markdown')
    end)

    spec.it('builds queries from actual user text, excluding tool output and reminders', function()
        local query = memory.query({{role='user',content='old SQLite task'},
            {role='user',content={{type='text',text='Rust scope'}, {type='image',source={}},
                {type='text',text='<system-reminder>SQLite skills</system-reminder>'}}},
            {role='user',content={{type='tool_result',content='SQLite result'}}}})
        spec.equal(query,'Rust scope')
    end)

    spec.it('omits memory gracefully when reading fails or the context window is too small', function()
        local retrieve=memory.retrieve
        memory.retrieve=function() error('fixture read failure') end
        local ok, system=pcall(memory.prepare,'BASE','.','Rust',{})
        memory.retrieve=retrieve
        assert(ok,system)
        spec.equal(system,'BASE')
        memory.retrieve=function(_,query,opts) return memory.select('## Rust\nUse concrete scope.',query,opts) end
        ok, system=pcall(memory.prepare,'BASE','.','Rust',{context_window=1000})
        memory.retrieve=retrieve
        assert(ok,system)
        spec.equal(system,'BASE','small windows must not be filled with optional memory')
    end)
end)

return {
    __init = function()
        local failed = spec.finish()
        if failed > 0 then os.exit(1) end
        xthread.stop(0)
    end,
}
