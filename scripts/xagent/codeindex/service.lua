-- service.lua — one long-lived index + graph per project root, refreshed
-- before every query so answers never lag behind edits.
--
--   local svc = require('xagent.codeindex.service')
--   local text, info = svc.explore('C:/src/proj', 'xtimer_poll xtimer_add')

local index = require('xagent.codeindex.index')
local graph = require('xagent.codeindex.graph')
local explore = require('xagent.codeindex.explore')

local M = {}

local projects = {}     -- root -> { idx, G }

-- Index + graph for root, refreshed. Saves the cache when anything changed.
function M.get(root, opts)
    local key = root:gsub('\\', '/'):gsub('/+$', '')
    local p = projects[key]
    if not p then
        p = { idx = index.open(key, opts) }
        projects[key] = p
    end
    local t0 = os.clock()
    local stats = p.idx:refresh()
    if not p.G or p.G.generation ~= p.idx.generation then
        p.G = graph.build(p.idx)
        p.idx:save()
    end
    stats.seconds = os.clock() - t0
    return p.idx, p.G, stats
end

function M.explore(root, query, opts)
    local idx, G, stats = M.get(root, opts)
    local text, info = explore.run(G, idx, query, opts)
    info.refresh = stats
    return text, info
end

-- Drop the in-memory state for a root (the on-disk cache stays).
function M.forget(root)
    projects[root:gsub('\\', '/'):gsub('/+$', '')] = nil
end

return M
