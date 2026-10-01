-- xagent/context/system_prompt.lua — build the system prompt.
--
-- One file for every host (the desktop GUI / headless runner here, the Android
-- app in codua2a): the coding rules, the project memory and the MCP server
-- instructions are shared. A host that needs its own identity or platform
-- rules registers hooks (set_hooks) instead of assembling a prompt of its own,
-- so a rule added here reaches every host. Without hooks, build() is the
-- desktop prompt.

local text = dofile('scripts/core/share/xtext.lua')

local M = {}

-- Docs questions must not turn into a workspace search: "list the C standard
-- library headers" once got an LS of the repo instead of the reference.
M.DOCS_LOOKUP = 'For questions about a programming language standard, a standard library, or a third-party ' ..
    'library, framework or API, consult its documentation (a documentation MCP server such as Context7, or ' ..
    'WebFetch on the official docs) instead of searching the workspace, unless the user means code in this project.'

-- Per-server cap: the text is resent with every request.
local MAX_MCP_INSTRUCTIONS = 4000

local IDENTITY = {
    'You are xagent, a terminal-native local coding assistant running inside the user\'s workspace.',
    'Treat the current working directory as the primary workspace boundary.',
}

local CODING = {
    'Operate directly, be concise, and take concrete actions with tools when useful.',
    'When solving a task: first understand the relevant files, then make focused changes, then verify with the least expensive effective command.',
    'Prefer the Read tool to read files and the Bash tool only when shell execution is actually needed.',
    -- Every round-trip resends the whole conversation, so fewer turns and
    -- smaller tool results are the main lever on token cost.
    'When several tool calls do not depend on each other (reading multiple files, unrelated searches), issue them together in one response instead of one per turn.',
    -- Tool descriptions lose to "search" wording in the prompt, so the prompt
    -- names CodeExplore as the first step itself.
    'When the CodeExplore tool is available, use it first to locate or understand code: name the functions, classes or files involved and it returns their source, callers and callees in one call. Use Grep for text that is not a symbol (strings, config keys, log messages) or when CodeExplore finds nothing.',
    'For large files, locate the relevant part first (CodeExplore, else Grep), then Read only that range with offset/limit instead of the whole file; do not re-read content already in the conversation.',
    M.DOCS_LOOKUP,
    'When you have finished the task, stop and give a short summary of what you did or found.',
}

-- Host hooks, each `function(opts) -> string` (opts as passed to build):
--   identity    replaces IDENTITY (who the assistant is, workspace boundary)
--   environment replaces the Environment section
--   append      extra platform rules, after the coding rules and project
--               memory and before the MCP section, so it can override them
local hooks = {}

function M.set_hooks(h)
    hooks = h or {}
end

local function env_section(opts)
    local lines = {
        'Environment:',
        '- Current working directory: ' .. tostring(opts.cwd or '.'),
        '- Current date: ' .. os.date('%Y-%m-%d'),
        '- Operating system: ' .. (opts.os or (package.config:sub(1, 1) == '\\' and 'Windows' or 'POSIX')),
    }
    return table.concat(lines, '\n')
end

-- The usage instructions MCP servers sent at initialize (mcp/registry
-- .instructions()) as one section, laid out the way Claude Code does; '' when
-- there are none. Tool descriptions say what a tool does, these say when to
-- use it — without them a docs server is never chosen over a workspace search.
function M.mcp_section(list)
    if type(list) ~= 'table' or #list == 0 then return '' end
    local parts = { '# MCP Server Instructions\n\n' ..
        'The following MCP servers have provided instructions for how to use their tools and resources:' }
    for _, it in ipairs(list) do
        local body = tostring(it.text or '')
        if #body > MAX_MCP_INSTRUCTIONS then body = body:sub(1, MAX_MCP_INSTRUCTIONS) .. '\n...[truncated]' end
        parts[#parts + 1] = '## ' .. tostring(it.name) .. '\n' .. body
    end
    return text.valid_utf8(table.concat(parts, '\n\n'))
end

-- opts: { cwd, os?, project_md?, mcp_instructions?, ... } — extra fields are
-- passed through to the hooks (Android passes skill_id).
function M.build(opts)
    opts = opts or {}
    local parts = {}
    local function add(s)
        if s and s ~= '' then parts[#parts + 1] = s end
    end
    if hooks.identity then
        add(hooks.identity(opts))
    else
        for _, s in ipairs(IDENTITY) do add(s) end
    end
    for _, s in ipairs(CODING) do add(s) end
    add(hooks.environment and hooks.environment(opts) or env_section(opts))
    if opts.project_md and opts.project_md ~= '' then
        add('Project memory (from AGENT.md / CLAUDE.md — follow it):\n' .. opts.project_md)
    end
    if hooks.append then add(hooks.append(opts)) end
    add(M.mcp_section(opts.mcp_instructions))
    return table.concat(parts, '\n\n')
end

return M
