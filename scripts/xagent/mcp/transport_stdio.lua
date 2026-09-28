-- xagent/mcp/transport_stdio.lua — MCP stdio transport.
--
-- The server is a child process; each JSON-RPC message is one line of UTF-8
-- JSON on its stdin (ours → server) or stdout (server → ours). stderr is free
-- text: we keep its tail to explain a server that dies. The child comes from
-- the native xproc binding, whose stdio ends are socket channels on the event
-- loop (real pipes to the child on every platform, Windows included), so reads
-- and writes never block the GUI.
--
-- Same shape as transport_http so client.lua can swap them:
--   open(conn) / rpc(conn, method, params) / notify(conn, method, params) / close(conn)
-- `rpc` MUST run inside a coroutine: it awaits the matching response line.
--
-- A `conn` table carries the config and, once open, the live process:
--   { command, args?, env?, cwd?, timeout_ms?, proc = { ... } }
--
-- Server → client requests: `ping` is answered; anything else gets "method not
-- found" so a server waiting on sampling/roots does not hang. Notifications
-- (logging, list_changed, progress) are ignored.

local async = dofile('scripts/core/share/xasync.lua')
local jsonrpc = require('xagent.mcp.jsonrpc')
local xutils = require('xutils')

local M = {}

local DEFAULT_TIMEOUT_MS = 120000   -- tool calls (indexing, builds) can be slow
local CLOSE_GRACE_MS = 2000         -- time to exit after stdin EOF before a kill
local MAX_LINE = 16 * 1024 * 1024   -- a runaway line is a broken server
local STDERR_TAIL = 2048

local has_xproc, xproc = pcall(require, 'xproc')
if not has_xproc then xproc = nil end

-- Can this runtime spawn a stdio server at all? Returns (true) or (false, why).
function M.available()
    if not xproc then
        return false, 'this runtime was built without the native xproc module; rebuild it with xproc'
    end
    if not xproc.supported() then
        return false, 'spawning child processes is not supported on this platform'
    end
    return true
end

-- Timeouts need the timer wheel; the runner pumps it once it is initialised.
local function add_timer(ms, fn)
    if not xtimer.inited() then xtimer.init(16) end
    xtimer.add(ms, fn, 1)
end

local function tail(p)
    local t = (p.stderr or ''):gsub('%s+$', '')
    if t == '' then return '' end
    local last = {}
    for line in t:gmatch('[^\r\n]+') do
        last[#last + 1] = line
        if #last > 3 then table.remove(last, 1) end
    end
    return ' — stderr: ' .. table.concat(last, ' | ')
end

-- Fail every pending request (the process is gone or we are closing).
local function fail_all(p, why)
    local pending = p.pending
    p.pending = {}
    for _, resolve in pairs(pending) do resolve(nil, why) end
end

local function reap(p, block)
    if p.reaped or not p.pid then return true end
    local exited, code = xproc.wait(p.pid, not block)
    if exited then p.reaped, p.exit_code = true, code end
    return p.reaped
end

local function send_line(p, msg)
    local line, err = jsonrpc.encode(msg)
    if not line then return nil, err end
    if p.closed or not p.stdin then return nil, 'MCP server process is not running' .. tail(p) end
    local ok, serr = p.stdin:send_raw(line .. '\n')
    if not ok then return nil, 'write to MCP server failed: ' .. tostring(serr) end
    return true
end

local function on_message(p, msg)
    if type(msg) ~= 'table' then return end
    if msg.method ~= nil then
        if msg.id ~= nil then        -- a request from the server
            if msg.method == 'ping' then
                send_line(p, { jsonrpc = '2.0', id = msg.id, result = {} })
            else
                send_line(p, { jsonrpc = '2.0', id = msg.id,
                    error = { code = -32601, message = 'Method not found: ' .. tostring(msg.method) } })
            end
        end
        return
    end
    local resolve = msg.id ~= nil and p.pending[msg.id]
    if resolve then
        p.pending[msg.id] = nil
        resolve(msg)
    end
end

local function on_stdout(p, data)
    p.buf = p.buf .. data
    while true do
        local nl = p.buf:find('\n', 1, true)
        if not nl then break end
        local line = p.buf:sub(1, nl - 1):gsub('\r$', '')
        p.buf = p.buf:sub(nl + 1)
        if line:find('%S') then
            local ok, msg = pcall(xutils.json_unpack, line)
            if ok then
                on_message(p, msg)
            else
                -- Not protocol: a server that logs to stdout. Keep it for errors.
                p.stderr = (p.stderr .. line .. '\n'):sub(-STDERR_TAIL)
            end
        end
    end
    if #p.buf > MAX_LINE then
        p.buf = ''
        fail_all(p, 'MCP server sent an oversized message')
    end
end

-- Spawn the server. Returns (true) or (nil, err).
function M.open(conn)
    local ok, why = M.available()
    if not ok then return nil, why end
    if conn.proc and not conn.proc.closed then return true end

    local argv = { conn.command }
    for _, a in ipairs(conn.args or {}) do argv[#argv + 1] = a end
    local h, err = xproc.spawn({ argv = argv, cwd = conn.cwd, env = conn.env })
    if not h then return nil, 'cannot start MCP server: ' .. tostring(err) end

    local p = { pid = h.pid, buf = '', stderr = '', pending = {}, closed = false }
    conn.proc = p
    local out = xnet.attach(h.stdout_fd, {
        on_packet = function(_, data) on_stdout(p, data); return #data end,
        on_close = function()
            if p.closed then return end
            p.closed = true
            reap(p, false)
            local code = p.exit_code and (' (exit ' .. tostring(p.exit_code) .. ')') or ''
            fail_all(p, 'MCP server exited' .. code .. tail(p))
            if p.stdin then pcall(p.stdin.close, p.stdin, 'eof') end
        end,
    })
    xnet.attach(h.stderr_fd, {
        on_packet = function(_, data)
            p.stderr = (p.stderr .. data):sub(-STDERR_TAIL)
            return #data
        end,
        on_close = function() end,
    })
    p.stdin = xnet.attach(h.stdin_fd, {
        on_packet = function(_, data) return #data end,
        on_close = function() p.stdin = nil end,
    })
    if not out or not p.stdin then
        M.close(conn, true)
        return nil, 'cannot attach MCP server stdio'
    end
    return true
end

-- Send a request and await the matching response. Returns (result) or (nil, err).
function M.rpc(conn, method, params)
    local p = conn.proc
    if not p or p.closed then return nil, 'MCP server process is not running' .. (p and tail(p) or '') end
    local id = jsonrpc.next_id()
    local timeout = conn.timeout_ms or DEFAULT_TIMEOUT_MS
    local msg, err = async.await(function(resolve)
        p.pending[id] = resolve
        local sent, serr = send_line(p, jsonrpc.request(id, method, params))
        if not sent then
            p.pending[id] = nil
            return resolve(nil, serr)
        end
        add_timer(timeout, function()
            if p.pending[id] then
                p.pending[id] = nil
                resolve(nil, string.format('MCP request %s timed out after %d ms', method, timeout))
            end
        end)
    end)
    if not msg then return nil, err end
    return jsonrpc.parse_response(msg)
end

-- Fire a notification. Returns (true) or (nil, err).
function M.notify(conn, method, params)
    local p = conn.proc
    if not p or p.closed then return nil, 'MCP server process is not running' end
    return send_line(p, jsonrpc.notification(method, params))
end

-- Stop the server: close stdin so it can exit cleanly, then kill it if it is
-- still running after a grace period. `now` kills and reaps immediately (use
-- when the event loop is about to stop and timers will not fire).
function M.close(conn, now)
    local p = conn.proc
    if not p then return end
    conn.proc = nil
    local was_open = not p.closed
    p.closed = true
    fail_all(p, 'MCP server closed')
    if p.stdin then pcall(p.stdin.close_after_flush, p.stdin, 'eof') end
    if not p.pid or reap(p, false) then return end
    if now or not was_open then
        xproc.kill(p.pid, true)
        reap(p, true)
        return
    end
    add_timer(CLOSE_GRACE_MS, function()
        if not reap(p, false) then
            xproc.kill(p.pid, true)
            reap(p, true)
        end
    end)
end

return M
