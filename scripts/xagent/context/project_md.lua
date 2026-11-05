-- Project instructions and learned memory are stored and loaded separately.
-- Legacy instruction filenames remain supported; none can hide AGENTS.md.

local fs   = dofile('scripts/core/share/xfs.lua')
local text = dofile('scripts/core/share/xtext.lua')

local M = {}

local NAMES = { 'AGENTS.md', 'CLAUDE.md', 'AGENT.md' }
local MAX_BYTES = 16000
local MAX_LEVELS = 6
local MEMORY_FILE = '.xagent/memory/lessons_learned.md'

function M.memory_path(cwd)
    return (cwd or '.'):gsub('[/\\]+$', '') .. '/' .. MEMORY_FILE
end

-- Learned memory belongs to this workspace, independently of instruction files.
function M.load_memory(cwd)
    local p = M.memory_path(cwd)
    local data = fs.read_file(p)
    if data and data:find('%S') then
        return text.valid_utf8(text.truncate(data, 8000, '\n...[learned memory truncated]')), p
    end
    return nil
end

-- Nearest file for each supported name, in canonical-first order. Each gets a
-- bounded share so a large legacy file cannot crowd out canonical instructions.
-- Returns (combined content, first path) or nil (preserves the existing API).
function M.load(cwd)
    local dir = cwd or '.'
    local found = {}
    for _ = 1, MAX_LEVELS do
        for _, name in ipairs(NAMES) do
            local p = dir .. '/' .. name
            local data = not found[name] and fs.read_file(p)
            if data and data:find('%S') then
                found[name] = { path = p, content = data }
            end
        end
        local parent = dir:gsub('[/\\]+$', ''):match('^(.*)[/\\][^/\\]+$')
        if not parent or parent == dir then break end
        dir = parent
    end
    local parts, first, count = {}, nil, 0
    for _, name in ipairs(NAMES) do
        if found[name] then count = count + 1 end
    end
    for _, name in ipairs(NAMES) do
        local item = found[name]
        if item then
            first = first or item.path
            parts[#parts + 1] = '## Source: ' .. item.path .. '\n' ..
                text.valid_utf8(text.truncate(item.content, math.floor(MAX_BYTES / count), '\n...[project instructions truncated]'))
        end
    end
    if #parts > 0 then return table.concat(parts, '\n\n'), first end
    return nil
end

return M
