-- xagent/test_mcp_stdio_server.lua — a tiny MCP server on stdin/stdout, used by
-- test_mcp_stdio.lua. Run with STDIO=1 so the runtime logs go to stderr and
-- stdout carries only protocol lines.
--
-- Tools: echo(text), pinged() -> whether the client answered our ping,
-- crash() -> exits without answering, after a line on stderr.

local xutils = require('xutils')

local input, pinged = '', false

local function send(msg)
    io.stdout:write(xutils.json_pack(msg), '\n')
    io.stdout:flush()
end

local function text(s) return { content = { { type = 'text', text = s } } } end

local function handle(msg)
    local id, method, params = msg.id, msg.method, msg.params or {}
    if method == nil then                         -- a response to our ping
        if id == 'server-ping' and msg.result then pinged = true end
        return
    end
    if id == nil then return end                  -- notifications
    if method == 'initialize' then
        send({ jsonrpc = '2.0', id = id, result = {
            protocolVersion = params.protocolVersion or '2025-06-18',
            capabilities = { tools = {} },
            serverInfo = { name = 'stdio-fixture', version = '0.0.1' },
        } })
        -- A server-initiated request; the client must answer it.
        send({ jsonrpc = '2.0', id = 'server-ping', method = 'ping' })
    elseif method == 'tools/list' then
        send({ jsonrpc = '2.0', id = id, result = { tools = {
            { name = 'echo', description = 'Echo text back',
              inputSchema = { type = 'object', properties = { text = { type = 'string' } } } },
            { name = 'pinged', description = 'Whether the client answered ping',
              inputSchema = { type = 'object', properties = {} } },
            { name = 'crash', description = 'Exit without answering',
              inputSchema = { type = 'object', properties = {} } },
        } } })
    elseif method == 'tools/call' then
        local name, args = params.name, params.arguments or {}
        if name == 'echo' then
            send({ jsonrpc = '2.0', id = id, result = text('echo: ' .. tostring(args.text)) })
        elseif name == 'pinged' then
            send({ jsonrpc = '2.0', id = id, result = text(tostring(pinged)) })
        elseif name == 'crash' then
            io.stderr:write('fixture: crashing on purpose\n')
            io.stderr:flush()
            os.exit(3)
        else
            send({ jsonrpc = '2.0', id = id, error = { code = -32602, message = 'unknown tool ' .. tostring(name) } })
        end
    else
        send({ jsonrpc = '2.0', id = id, error = { code = -32601, message = 'Method not found' } })
    end
end

return {
    __tick_ms = 5,
    __init = function() assert(xutils.read_stdin, 'runtime lacks xutils.read_stdin') end,
    __update = function()
        local data, err = xutils.read_stdin(65536)
        if not data then
            xthread.stop(err == 'eof' and 0 or 1)
            return
        end
        input = input .. data
        while true do
            local nl = input:find('\n', 1, true)
            if not nl then break end
            local line = input:sub(1, nl - 1)
            input = input:sub(nl + 1)
            local ok, msg = pcall(xutils.json_unpack, line)
            if ok and type(msg) == 'table' then handle(msg) end
        end
    end,
}
