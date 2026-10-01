-- Unit specs for the shared system prompt builder: the desktop default, the
-- host hooks (identity / environment / append) that the Android app sets, and
-- the section order the hooks rely on.
-- Run via: bin/xnet tests/lua/xagent_system_prompt_spec.lua

package.path = 'scripts/?.lua;' .. package.path

local spec = dofile('tests/lua/spec_helper.lua')
local sp = require('xagent.context.system_prompt')

local function pos(s, needle) return s:find(needle, 1, true) end

spec.describe('system_prompt.build without hooks (desktop)', function()
    sp.set_hooks(nil)
    local sys = sp.build({ cwd = 'C:/w', project_md = 'Use tabs.' })

    spec.it('uses the desktop identity and environment', function()
        spec.truthy(sys:find('^You are xagent'), 'identity first')
        spec.contains(sys, '- Current working directory: C:/w')
    end)

    spec.it('carries every shared coding rule', function()
        spec.contains(sys, 'use it first to locate or understand code')
        spec.contains(sys, sp.DOCS_LOOKUP)
        spec.contains(sys, 'issue them together in one response')
        spec.contains(sys, 'Read only that range with offset/limit')
    end)

    spec.it('orders rules, environment, project memory', function()
        spec.truthy(pos(sys, 'When you have finished') < pos(sys, 'Environment:'), 'rules before environment')
        spec.truthy(pos(sys, 'Environment:') < pos(sys, 'Project memory'), 'environment before memory')
    end)
end)

spec.describe('system_prompt.build with host hooks', function()
    local seen
    sp.set_hooks({
        identity = function() return 'You are codua on Android.' end,
        environment = function() return 'Workspace: /workspace' end,
        append = function(opts) seen = opts.skill_id; return 'Execution mode: Ask.' end,
    })
    local sys = sp.build({ cwd = '/workspace', skill_id = 'stock',
        mcp_instructions = { { name = 'context7', text = 'Use for docs.' } } })
    sp.set_hooks(nil)

    spec.it('replaces identity and environment, keeps the shared rules', function()
        spec.truthy(sys:find('^You are codua on Android%.'), 'host identity first')
        spec.equal(pos(sys, 'You are xagent'), nil)
        spec.equal(pos(sys, 'Current working directory'), nil)
        spec.contains(sys, 'Workspace: /workspace')
        spec.contains(sys, sp.DOCS_LOOKUP)
    end)

    spec.it('appends after the rules and before the MCP section', function()
        spec.truthy(pos(sys, 'When you have finished') < pos(sys, 'Execution mode: Ask.'), 'append after rules')
        spec.truthy(pos(sys, 'Execution mode: Ask.') < pos(sys, '# MCP Server Instructions'), 'MCP last')
    end)

    spec.it('passes build opts through to the hooks', function()
        spec.equal(seen, 'stock')
    end)

    spec.it('set_hooks(nil) restores the desktop prompt', function()
        spec.truthy(sp.build({ cwd = '.' }):find('^You are xagent'), 'desktop again')
    end)
end)

return {
    __init = function()
        local failed = spec.finish()
        if failed > 0 then os.exit(1) end
        xthread.stop(0)
    end,
}
