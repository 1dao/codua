-- Tick-driven loopback login shared by desktop and Android hosts. One login
-- runs at a time; opts.auth picks the account (default ChatGPT).
local codec = dofile('scripts/core/share/xhttp_codec.lua')
local M = {}
local active
local function active_label() return active and active.auth.label or 'OAuth' end
function M.cancel()
    local a = active; active = nil
    if a then
        a.auth.cancel()
        if a.server then a.server:close('OAuth finished') end
    end
end
function M.start(opts)
    opts = opts or {}
    local auth = opts.auth or require('xagent.auth.chatgpt')
    assert(not active, 'A ' .. active_label() .. ' login is already running')
    local a = { auth = auth, clients = {}, expires = os.time() + 300, on_done = opts.on_done }
    if auth.manual then
        active = a
        local ok, url = pcall(auth.begin, opts.proxy)
        if not ok then M.cancel(); error(url) end
        return url
    end
    local handler = {}
    function handler.on_connect(conn)
        conn:set_framing({ type = 'raw', max_packet = 16384 }); a.clients[conn] = ''
    end
    function handler.on_close(conn) a.clients[conn] = nil end
    function handler.on_packet(conn, data)
        local buffer = (a.clients[conn] or '') .. data
        if #buffer > 16384 then conn:close('request too large'); return #data end
        a.clients[conn] = buffer
        if not buffer:find('\r\n\r\n', 1, true) then return #data end
        local target = buffer:match('^GET ([^ ]+) HTTP/1%.[01]\r\n')
        local path, query
        if target then path, query = target:match('^([^?]+)%??(.*)$') end
        local function reply(status, text)
            conn:send_raw('HTTP/1.1 ' .. status .. '\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: ' .. #text .. '\r\nConnection: close\r\n\r\n' .. text)
            conn:close('OAuth callback')
        end
        if path ~= auth.callback_path or a.exchanging then reply('404 Not Found', 'Not found'); return #data end
        local q = codec.parse_query(query or '')
        if q.state ~= a.state then reply('400 Bad Request', 'Invalid OAuth state'); return #data end
        a.exchanging = true
        -- The UI reports success only after exchange and durable storage succeed.
        local co = coroutine.create(function()
            local ok, result = pcall(auth.finish, q)
            if active == a then
                local callback = a.on_done
                M.cancel()
                if callback then callback(ok, ok and nil or tostring(result)) end
            end
        end)
        local ok, err = coroutine.resume(co)
        -- Start token exchange before closing the callback socket. Some native
        -- event-loop backends defer new socket registration during close.
        reply('200 OK', 'Return to Codua to see the login result.')
        if not ok then
            local callback = a.on_done
            M.cancel()
            if callback then callback(false, tostring(err)) end
        end
        return #data
    end
    local server, err = xnet.listen('127.0.0.1', auth.port, handler)
    assert(server, 'Cannot listen on localhost:' .. auth.port .. ': ' .. tostring(err))
    a.server = server; active = a
    local ok, url = pcall(auth.begin, opts.proxy)
    if not ok then M.cancel(); error(url) end
    a.state = codec.parse_query(url:match('%?(.*)$')).state
    return url
end
function M.tick()
    if active and os.time() >= active.expires then
        local cb, label = active.on_done, active_label(); M.cancel(); if cb then cb(false, label .. ' login timed out') end
    end
end
function M.finish(code)
    local a = active
    assert(a and a.auth.manual and not a.exchanging, 'No manual login pending')
    a.exchanging = true
    local co = coroutine.create(function()
        local ok, result = pcall(a.auth.finish, code)
        if active == a then
            local cb = a.on_done
            M.cancel()
            if cb then cb(ok, ok and nil or tostring(result)) end
        end
    end)
    local ok, err = coroutine.resume(co)
    if not ok then M.cancel(); if a.on_done then a.on_done(false, tostring(err)) end end
end
-- running(auth?) -> whether a login (for that account, if given) is active.
function M.running(auth) return active ~= nil and (auth == nil or active.auth == auth) end
return M
