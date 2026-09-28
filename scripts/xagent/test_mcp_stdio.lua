-- xagent/test_mcp_stdio.lua — end-to-end MCP over the stdio transport. Spawns
-- this runtime's own binary running test_mcp_stdio_server.lua as the server,
-- then drives the real MCP client (mcp/client.lua) + tool adapter
-- (mcp/fetch_tools.lua): handshake → tools/list → tools/call, a server-initiated
-- ping, a JSON-RPC error, a crashing server, close(), and a missing command.
-- Exits 0 on success, 1 on the first failure. Skips (exit 0) without xproc.
--
-- Run: bin/xnet scripts/xagent/test_mcp_stdio.lua

package.path = 'scripts/?.lua;' .. package.path

local mcp_client  = require('xagent.mcp.client')
local fetch_tools = require('xagent.mcp.fetch_tools')
local stdio       = require('xagent.mcp.transport_stdio')

local IS_WIN = package.config:sub(1, 1) == '\\'
local EXE = IS_WIN and 'bin/xnet.exe' or 'bin/xnet'
local SERVER = { type = 'stdio', command = EXE, args = { 'scripts/xagent/test_mcp_stdio_server.lua', 'STDIO=1' } }

local function out(s) io.write(s); io.flush() end
local fails, finished = 0, false
local function check(name, cond, detail)
    if cond then out('PASS ' .. name .. '\n')
    else fails = fails + 1; out('FAIL ' .. name .. ' :: ' .. tostring(detail) .. '\n') end
end
local function finish()
    if finished then return end
    finished = true
    out(string.format('[mcp-stdio] %s (%d failure(s))\n', fails == 0 and 'ALL PASS' or 'FAILED', fails))
    xthread.stop(fails == 0 and 0 or 1)
end

local function run()
    local c = mcp_client.new('fx', SERVER)
    local ok, err = c:connect()
    check('connect over stdio', ok and c.status == 'connected', err)
    if not ok then return finish() end
    check('serverInfo from the child', c.server_info and c.server_info.name == 'stdio-fixture',
        c.server_info and c.server_info.name)

    local tools, terr = fetch_tools.fetch(c)
    check('tools/list', tools and #tools == 3, terr or (tools and #tools))
    local by = {}
    for _, t in ipairs(tools or {}) do by[t.name] = t end

    local r = by.mcp__fx__echo.call({ text = '你好 stdio' })
    check('tools/call round-trips UTF-8', not r.is_error and r.content == 'echo: 你好 stdio', r.content)

    r = by.mcp__fx__pinged.call({})
    check('server-initiated ping was answered', r.content == 'true', r.content)

    local res, rerr = c:request('no/such/method', {})
    check('JSON-RPC error surfaces', res == nil and tostring(rerr):find('-32601', 1, true), rerr)

    r = by.mcp__fx__crash.call({})
    check('crashing server fails the pending call', r.is_error and r.content:find('exited', 1, true), r.content)
    check('crash error carries stderr', r.content:find('crashing on purpose', 1, true), r.content)
    res, rerr = c:request('tools/list', {})
    check('later calls fail fast', res == nil and tostring(rerr):find('not running', 1, true), rerr)
    c:close()

    local c2 = mcp_client.new('fx2', SERVER)
    ok, err = c2:connect()
    check('second server connects', ok, err)
    local pid = c2.transport.proc and c2.transport.proc.pid
    c2:close(true)
    check('close(true) reaps the child', pid and select(1, require('xproc').wait(pid, true)) == nil, pid)

    local c3 = mcp_client.new('missing', { type = 'stdio', command = 'definitely-not-an-mcp-server-xyz' })
    ok, err = c3:connect()
    check('missing command fails with its name', not ok and c3.status == 'failed'
        and tostring(err):find('definitely-not-an-mcp-server-xyz', 1, true), err)
    finish()
end

return {
    __tick_ms = 5,
    __thread_handle = function() end,
    __init = function()
        assert(xnet.init())
        local ok, why = stdio.available()
        if not ok then out('SKIP ' .. why .. '\n'); return xthread.stop(0) end
        if not xtimer.inited() then xtimer.init(16) end
        xtimer.add(60000, function() out('FAIL watchdog: no result within 60s\n'); fails = fails + 1; finish() end, 1)
        local co = coroutine.create(run)
        local rok, rerr = coroutine.resume(co)
        if not rok then check('test coroutine', false, rerr); finish() end
    end,
    __uninit = function() xnet.uninit() end,
}
