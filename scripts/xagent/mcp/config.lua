-- xagent/mcp/config.lua — load + validate `mcpServers` declarations.
--
-- Two scopes, project overriding user on a name clash (same precedence model as
-- the rest of xagent's config):
--   user:    ~/.xagent/mcp.json
--   project: <cwd>/.mcp.json          (the de-facto Claude Code project file)
-- Both use the standard shape:  { "mcpServers": { "<name>": { ...config } } }.
--
-- Each server is one of three transport types (validated here, connected by
-- client.lua):
--   stdio:  { "command": "...", "args": [...], "env": { ... } }   (type optional)
--   http:   { "type": "http", "url": "https://...", "headers": { ... } }
--   sse:    { "type": "sse",  "url": "https://...", "headers": { ... } }
--
-- Loading is best-effort: a malformed entry is dropped with an error string, it
-- never throws (one bad server must not take the whole agent down).
--
-- Reference: ../easy-agent/src/services/mcp/config.ts.

local fs = dofile('scripts/core/share/xfs.lua')
local xutils = require('xutils')

local M = {}

-- Validate a single raw server table. Returns (config, nil) or (nil, err).
-- The returned config always carries an explicit `type`.
function M.validate(name, raw)
    if type(raw) ~= 'table' then
        return nil, 'mcpServers.' .. name .. ' must be an object'
    end
    local t = raw.type
    if t == nil then
        -- Infer: a `url` means a remote server, otherwise stdio (the common
        -- ecosystem shape omits `type` for stdio).
        t = (type(raw.url) == 'string') and 'http' or 'stdio'
    end
    if t ~= 'stdio' and t ~= 'http' and t ~= 'sse' then
        return nil, 'mcpServers.' .. name .. ": unsupported transport '" ..
            tostring(t) .. "' (use stdio|http|sse)"
    end

    if t == 'http' or t == 'sse' then
        if type(raw.url) ~= 'string' or raw.url == '' then
            return nil, 'mcpServers.' .. name .. ": '" .. t .. "' transport requires a 'url' string"
        end
        local headers
        if raw.headers ~= nil then
            if type(raw.headers) ~= 'table' then
                return nil, 'mcpServers.' .. name .. ": 'headers' must be an object"
            end
            headers = {}
            for k, v in pairs(raw.headers) do
                if type(v) ~= 'string' then
                    return nil, 'mcpServers.' .. name .. ': headers.' .. tostring(k) .. ' must be a string'
                end
                headers[k] = v
            end
        end
        return { type = t, url = raw.url, headers = headers }
    end

    -- stdio
    if type(raw.command) ~= 'string' or raw.command == '' then
        return nil, 'mcpServers.' .. name .. ": 'command' is required for the stdio transport"
    end
    local args = {}
    if raw.args ~= nil then
        if type(raw.args) ~= 'table' then
            return nil, 'mcpServers.' .. name .. ": 'args' must be an array of strings"
        end
        for i, a in ipairs(raw.args) do
            if type(a) ~= 'string' then
                return nil, 'mcpServers.' .. name .. ": 'args' must contain only strings"
            end
            args[i] = a
        end
    end
    local env
    if raw.env ~= nil then
        if type(raw.env) ~= 'table' then
            return nil, 'mcpServers.' .. name .. ": 'env' must be a string->string map"
        end
        env = {}
        for k, v in pairs(raw.env) do
            if type(v) ~= 'string' then
                return nil, 'mcpServers.' .. name .. ': env.' .. tostring(k) .. ' must be a string'
            end
            env[k] = v
        end
    end
    return { type = 'stdio', command = raw.command, args = args, env = env }
end

-- Extract { name -> config } from a decoded settings blob, appending any
-- per-server errors to `errors`. `scope` is stamped onto each config.
function M.extract(raw, scope, errors)
    local out = {}
    if type(raw) ~= 'table' or raw.mcpServers == nil then return out end
    if type(raw.mcpServers) ~= 'table' then
        errors[#errors + 1] = tostring(scope) .. ": 'mcpServers' must be an object"
        return out
    end
    for name, rc in pairs(raw.mcpServers) do
        local cfg, err = M.validate(name, rc)
        if cfg then
            cfg.scope = scope
            out[name] = cfg
        else
            errors[#errors + 1] = err
        end
    end
    return out
end

local function read_json(path)
    local data = fs.read_file(path)
    if not data then return nil end                  -- absent file: not an error
    data = data:gsub('^\239\187\191', '')            -- strip UTF-8 BOM
    local ok, t = pcall(xutils.json_unpack, data)
    if not ok or type(t) ~= 'table' then
        return nil, 'invalid JSON in ' .. path
    end
    return t
end

-- The user-scope file; the GUI and `/mcp add|remove` edit only this one.
function M.user_file()
    return (fs.home():gsub('[/\\]+$', '')) .. '/.xagent/mcp.json'
end

-- Load all configured servers for `cwd`. Returns (servers, errors) where
-- servers = { name -> config } (project entries override user entries).
-- `user_file` overrides the user-scope path (tests).
function M.load(cwd, user_file)
    local errors = {}
    local servers = {}

    local ut, uerr = read_json(user_file or M.user_file())
    if uerr then errors[#errors + 1] = uerr end
    if ut then
        for k, v in pairs(M.extract(ut, 'user', errors)) do servers[k] = v end
    end

    if cwd and cwd ~= '' then
        local pt, perr = read_json((cwd:gsub('[/\\]+$', '')) .. '/.mcp.json')
        if perr then errors[#errors + 1] = perr end
        if pt then
            for k, v in pairs(M.extract(pt, 'project', errors)) do servers[k] = v end
        end
    end

    return servers, errors
end

-- ── user-scope editing ──────────────────────────────────────────────────────
-- Entries are written back as raw tables, so fields this module does not model
-- (and other top-level keys) survive an edit. The file is pretty-printed with
-- sorted keys, since people also edit it by hand.

local json_array_mt = xutils.json_array_mt

local function encode(v, indent, out)
    if type(v) ~= 'table' then
        local s = xutils.json_pack(v)
        if not s then error('cannot encode ' .. type(v)) end
        out[#out + 1] = s
        return
    end
    local n, count = #v, 0
    for _ in pairs(v) do count = count + 1 end
    local inner = indent .. '  '
    if count == n and (n > 0 or (json_array_mt and getmetatable(v) == json_array_mt)) then
        if n == 0 then out[#out + 1] = '[]'; return end
        out[#out + 1] = '[\n'
        for i = 1, n do
            out[#out + 1] = inner
            encode(v[i], inner, out)
            out[#out + 1] = i < n and ',\n' or '\n'
        end
        out[#out + 1] = indent .. ']'
        return
    end
    local keys = {}
    for k in pairs(v) do
        if type(k) ~= 'string' then error('object keys must be strings') end
        keys[#keys + 1] = k
    end
    if #keys == 0 then out[#out + 1] = '{}'; return end
    table.sort(keys)
    out[#out + 1] = '{\n'
    for i, k in ipairs(keys) do
        out[#out + 1] = inner .. xutils.json_pack(k) .. ': '
        encode(v[k], inner, out)
        out[#out + 1] = i < #keys and ',\n' or '\n'
    end
    out[#out + 1] = indent .. '}'
end

function M.encode_pretty(v)
    local out = {}
    encode(v, '', out)
    return table.concat(out) .. '\n'
end

-- Read the user file for editing. Returns (doc, servers) where servers is the
-- doc's raw `mcpServers` table; an absent file yields an empty doc. A file that
-- does not parse is an error, never silently replaced.
function M.read_user(path)
    path = path or M.user_file()
    local doc, err = read_json(path)
    if err then return nil, err end
    doc = doc or {}
    if doc.mcpServers == nil then doc.mcpServers = {} end
    if type(doc.mcpServers) ~= 'table' then
        return nil, path .. ": 'mcpServers' must be an object"
    end
    return doc, doc.mcpServers
end

-- Names become part of `mcp__<name>__<tool>`; keep them in that charset so a
-- rename by normalization cannot collide with another server.
function M.check_name(name)
    if type(name) ~= 'string' or not name:match('^[%w_-]+$') or #name > 64 then
        return false, 'name must be 1-64 letters, digits, _ or -'
    end
    return true
end

local function write_user(doc, path)
    local data = M.encode_pretty(doc)
    fs.mkdirp(path:match('^(.*)[/\\][^/\\]*$') or '.')
    if xutils.temp_file and xutils.replace_file then
        local dir = path:match('^(.*)[/\\][^/\\]*$') or '.'
        local tmp = xutils.temp_file(dir)
        if tmp then
            local ok, err = fs.write_file(tmp, data)
            if ok then
                ok, err = xutils.replace_file(tmp, path)
                if ok then return true end
            end
            os.remove(tmp)
            return nil, err
        end
    end
    return fs.write_file(path, data)
end

-- Add or replace user server `name` with raw entry `raw`. `old_name` (optional)
-- renames an existing entry. Returns true or (nil, err); nothing is written
-- when the entry does not validate.
function M.save_user_server(name, raw, old_name, path)
    path = path or M.user_file()
    local ok, err = M.check_name(name)
    if not ok then return nil, err end
    local _, verr = M.validate(name, raw)
    if verr then return nil, verr end
    local doc, servers = M.read_user(path)
    if not doc then return nil, servers end
    if old_name and old_name ~= name then
        if servers[name] ~= nil then return nil, "server '" .. name .. "' already exists" end
        servers[old_name] = nil
    end
    servers[name] = raw
    return write_user(doc, path)
end

-- Remove user server `name`. Returns true, (false) when absent, or (nil, err).
function M.remove_user_server(name, path)
    path = path or M.user_file()
    local doc, servers = M.read_user(path)
    if not doc then return nil, servers end
    if servers[name] == nil then return false end
    servers[name] = nil
    return write_user(doc, path)
end

return M
