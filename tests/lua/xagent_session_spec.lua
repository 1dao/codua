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
end)

return {
    __init = function()
        local failed = spec.finish()
        if failed > 0 then os.exit(1) end
        xthread.stop(0)
    end,
}
