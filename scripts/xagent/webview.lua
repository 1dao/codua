-- Run from the repository root: bin/xnet scripts/xagent/webview.lua
package.path = 'scripts/?.lua;' .. package.path

local http = dofile('scripts/core/share/xhttp_codec.lua')
local oauth = dofile('scripts/core/share/xoauth.lua')
local process = dofile('scripts/core/server/xproc.lua')
local fs = dofile('scripts/core/share/xfs.lua')
local xutils = require('xutils')
local surface = require('xagent.ui.webview_surface')
local gui = assert(loadfile('scripts/xagent/gui.lua'))('webview')

local host = '127.0.0.1'
local max_request = 20 * 1024 * 1024
local is_win = package.config:sub(1, 1) == '\\'
local executable = is_win and 'tmp\\webview\\codua-webview.exe' or 'tmp/webview/codua-webview'
local assets = {
    [''] = { 'chat.html', 'text/html; charset=utf-8' },
    ['surface.js'] = { 'surface.js', 'text/javascript; charset=utf-8' },
}
local server, authority, route, gui_started

local function reply(conn, req, status, body, content_type, reuse)
    req.keep_alive = reuse and req.keep_alive or false
    http.send_response(conn, req, {
        status = status,
        body = body,
        headers = {
            ['Content-Type'] = content_type or 'text/plain; charset=utf-8',
            ['Cache-Control'] = 'no-store',
            ['Content-Security-Policy'] = "default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; " ..
                "img-src data:; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
            ['Referrer-Policy'] = 'no-referrer',
            ['X-Content-Type-Options'] = 'nosniff',
        },
    })
    if not req.keep_alive then conn:close('response sent') end
    return req.keep_alive
end

local function handle(conn, req)
    -- The window receives a random route at launch. State changes also require
    -- the exact loopback origin, including the listener port.
    if req.headers.host ~= authority or req.path:sub(1, #route) ~= route then
        return reply(conn, req, 404, 'Not found')
    end
    local path = req.path:sub(#route + 1)
    local asset = req.method == 'GET' and assets[path]
    if asset then return reply(conn, req, 200, asset.body, asset[2]) end
    if path ~= 'frame' or req.method ~= 'POST' or req.headers.origin ~= 'http://' .. authority then
        return reply(conn, req, 404, 'Not found')
    end

    local decoded, state = pcall(xutils.json_unpack, req.body)
    if not decoded or type(state) ~= 'table' then return reply(conn, req, 400, 'Invalid UI data') end
    local ok, result = pcall(function()
        surface.prepare(state)
        gui.__update()
        return xutils.json_pack(surface.response())
    end)
    if not ok then
        io.stderr:write('Codua WebView frame: ', tostring(result), '\n')
        return reply(conn, req, 500, '绘制界面失败，请查看 Codua 日志。')
    end
    return reply(conn, req, 200, result, 'application/json; charset=utf-8', true)
end

local function listen()
    local buffers = {}
    local handlers = {}
    function handlers.on_connect(conn)
        conn:set_framing({ type = 'raw', max_packet = max_request })
        buffers[conn] = ''
    end
    function handlers.on_packet(conn, data)
        local pending = buffers[conn]
        if not pending then return #data end
        local buffer = pending .. data
        if #buffer > max_request then conn:close('request too large'); return #data end
        while buffer ~= '' do
            local req, next_pos, err = http.parse_request(buffer, 1, { max_request_size = max_request })
            if err == 'incomplete' then break end
            buffers[conn] = nil
            if not req then conn:close('bad request'); return #data end
            if not handle(conn, req) then return #data end
            buffer = buffer:sub(next_pos)
        end
        buffers[conn] = buffer
        return #data
    end
    function handlers.on_close(conn) buffers[conn] = nil end
    for _ = 1, 32 do
        local port = math.random(38000, 58000)
        local listener = xnet.listen(host, port, handlers)
        if listener then return listener, host .. ':' .. port end
    end
    error('Could not listen for the local WebView')
end

local function init()
    local binary = assert(io.open(executable, 'rb'), 'Build the Codua WebView host in tmp/webview first.')
    binary:close()
    for _, asset in pairs(assets) do
        asset.body = assert(fs.read_file('tools/webview/' .. asset[1]))
    end

    gui.__init()
    gui_started = true
    route = '/' .. assert(oauth.random_urlsafe(24)) .. '/'
    server, authority = listen()
    assert(process.setup({ workers = 1, base_tid = xthread.WORKER_GRP5, name = 'codua-webview', tmp_dir = 'tmp' }))
    local started, err = coroutine.resume(coroutine.create(function()
        local result = process.exec({
            argv = { executable, 'http://' .. authority .. route },
            capture_stdout = true,
            max_capture = 4096,
        })
        local ok = result.ok and result.exit_code == 0
        if not ok then
            io.stderr:write('Codua WebView exited with an error.\n', result.err or '', '\n', result.stderr or '')
        end
        xthread.stop(ok and 0 or 1)
    end))
    assert(started, err)
end

return {
    __tick_ms = gui.__tick_ms,
    __thread_handle = gui.__thread_handle,
    __init = init,
    __uninit = function()
        if server then server:close('window closed') end
        process.shutdown()
        if gui_started then gui.__uninit() end
    end,
}
