-- xagent/mcp/client.lua — one MCP server connection + the protocol calls.
--
-- A Client wraps a transport and performs the MCP handshake (initialize +
-- notifications/initialized), then exposes tools/resources requests. All methods
-- that touch the network (`connect`, `request`, and the typed helpers) MUST run
-- inside the agent coroutine — they await the transport.
--
-- Transports: `http` and `sse` configs use the Streamable HTTP transport
-- (transport_http); `stdio` spawns the server as a child process and speaks
-- line-delimited JSON-RPC over its stdin/stdout (transport_stdio, native xproc).
-- A runtime without xproc marks a stdio server `unsupported` with an actionable
-- message instead of crashing the bootstrap. close() stops a stdio server.
--
-- Reference: ../easy-agent/src/services/mcp/client.ts + fetchTools.ts.

local http = require('xagent.mcp.transport_http')
local stdio = require('xagent.mcp.transport_stdio')

local M = {}

local Client = {}
Client.__index = Client
M.Client = Client

local CLIENT_INFO = { name = 'xagent', version = '0.1.0' }
-- Advertise the latest spec we target; we then adopt whatever version the server
-- echoes back for the MCP-Protocol-Version header on subsequent requests.
local CLIENT_PROTOCOL_VERSION = '2025-06-18'

-- new(name, config) — config from mcp/config.lua (carries an explicit `type`).
function M.new(name, config)
    return setmetatable({
        name = name,
        config = config,
        status = 'pending',      -- pending | connected | failed | unsupported
        error = nil,
        capabilities = nil,
        server_info = nil,
        instructions = nil,      -- initialize result.instructions, if any
        transport = nil,
    }, Client)
end

-- Run the initialize handshake. Returns (true) on success, or (false, err).
function Client:connect()
    local cfg = self.config

    if cfg.type == 'stdio' then
        local ok, why = stdio.available()
        if not ok then
            self.status = 'unsupported'
            self.error = 'stdio transport unavailable: ' .. why
            return false, self.error
        end
        self.io = stdio
        self.transport = {
            command = cfg.command, args = cfg.args, env = cfg.env, cwd = cfg.cwd,
            timeout_ms = cfg.timeout_ms,
        }
        local opened, oerr = stdio.open(self.transport)
        if not opened then
            self.status = 'failed'
            self.error = oerr
            return false, oerr
        end
    else
        self.io = http
        self.transport = {
            url = cfg.url,
            headers = cfg.headers,
            verify = cfg.verify,
            ca_file = cfg.ca_file,
            timeout_ms = cfg.timeout_ms,
            session_id = nil,
            protocol_version = nil,
        }
    end

    local result, err = self.io.rpc(self.transport, 'initialize', {
        protocolVersion = CLIENT_PROTOCOL_VERSION,
        capabilities = {},               -- we expose no client capabilities yet
        clientInfo = CLIENT_INFO,
    })
    if not result then
        self:close()
        self.status = 'failed'
        self.error = err
        return false, err
    end

    self.capabilities = (type(result.capabilities) == 'table') and result.capabilities or {}
    self.server_info = result.serverInfo
    -- The server's own guidance on when to use its tools (Context7: "use this
    -- whenever the user asks about a library..."). Tool descriptions alone do
    -- not say when to reach for a docs server, so it goes into the system prompt.
    local instr = result.instructions
    self.instructions = (type(instr) == 'string' and instr:match('%S')) and instr or nil
    self.transport.protocol_version = result.protocolVersion or CLIENT_PROTOCOL_VERSION

    -- Tell the server we're ready. Best-effort: a notify failure here doesn't
    -- invalidate an otherwise-good session (some servers don't require it).
    self.io.notify(self.transport, 'notifications/initialized', nil)

    self.status = 'connected'
    return true
end

-- Raw request passthrough (used by the resource tools). Returns (result, err).
function Client:request(method, params)
    if self.status ~= 'connected' then return nil, 'MCP server "' .. self.name .. '" not connected' end
    return self.io.rpc(self.transport, method, params)
end

-- Release the connection. A stdio server is asked to exit (stdin EOF) and is
-- killed if it lingers; `now` kills it at once (process shutdown). HTTP holds
-- no resources between requests. Safe to call more than once.
function Client:close(now)
    if self.io and self.io.close and self.transport then self.io.close(self.transport, now) end
    if self.status == 'connected' then self.status = 'closed' end
end

-- tools/list. Returns ({tool, ...}, nil), or ({}, nil) if no tools capability,
-- or (nil, err) on failure.
function Client:list_tools()
    if not (self.capabilities and self.capabilities.tools) then return {} end
    local list, cursor, seen = {}, nil, {}
    for _ = 1, 100 do
        local result, err = self:request('tools/list', cursor and { cursor = cursor } or {})
        if not result then return nil, err end
        for _, tool in ipairs(result.tools or {}) do list[#list + 1] = tool end
        cursor = result.nextCursor
        if cursor == nil then return list end
        if type(cursor) ~= 'string' or seen[cursor] then return nil, 'Invalid/repeated tools pagination cursor' end
        seen[cursor] = true
    end
    return nil, 'Too many tools pages'
end

-- tools/call. Returns (result, err); result = { content = {...}, isError? }.
function Client:call_tool(tool_name, args)
    return self:request('tools/call', { name = tool_name, arguments = args or {} })
end

function Client:list_resources()
    if not (self.capabilities and self.capabilities.resources) then return {} end
    local result, err = self:request('resources/list', {})
    if not result then return nil, err end
    return result.resources or {}
end

function Client:read_resource(uri)
    return self:request('resources/read', { uri = uri })
end

return M
