-- xagent/llm/provider.lua — pick the wire-protocol codec for a profile.
--
-- cfg.api_format selects it: 'anthropic' (default, Messages API) or 'openai'
-- (Chat Completions). Both codecs report the same Anthropic-shaped result, so
-- callers (loop, compaction) stay protocol-agnostic.

local M = {}

local CODECS = {
    anthropic = 'xagent.llm.anthropic',
    openai = 'xagent.llm.openai',
    responses = 'xagent.llm.responses',
}

M.FORMATS = { 'anthropic', 'openai', 'responses' }

-- Subscription accounts: cfg.auth_type names the OAuth account whose (possibly
-- refreshed) access token replaces api_key for each request. `key` is the
-- profile field naming one of several logged-in accounts (default otherwise).
local ACCOUNTS = {
    chatgpt = { auth = 'xagent.auth.chatgpt', key = 'chatgpt_account' },
    claude = { auth = 'xagent.auth.claude', key = 'claude_account' },
}

function M.codec(cfg)
    local fmt = (cfg and cfg.api_format) or 'anthropic'
    local mod = CODECS[fmt]
    if not mod then error('unknown api_format: ' .. tostring(fmt)) end
    return require(mod)
end

-- The server can revoke an unexpired token (e.g. after a login on another
-- device); a 401 arrives before any output, so refresh once and resend.
local function stream_with_account(account, codec, cfg, params, cb)
    local send
    send = function(rejected)
        local co = coroutine.create(function()
            local success, err = pcall(function()
                local credentials = require(account.auth).ensure(cfg.proxy, nil, nil, cfg[account.key], rejected)
                local request_cfg = {}; for k, v in pairs(cfg) do request_cfg[k] = v end
                request_cfg.api_key = credentials.access_token
                request_cfg.account_id = credentials.account_id
                request_cfg.auth_style = 'bearer'
                local request_cb = cb
                if not rejected then
                    request_cb = setmetatable({ on_error = function(msg)
                        if tostring(msg):match('^HTTP 401:') then return send(credentials.access_token) end
                        if cb and cb.on_error then cb.on_error(msg) end
                    end }, { __index = cb })
                end
                codec.stream_message(request_cfg, params, request_cb)
            end)
            if not success and cb and cb.on_error then cb.on_error(tostring(err)) end
        end)
        local started, err = coroutine.resume(co)
        if not started and cb and cb.on_error then cb.on_error(tostring(err)) end
    end
    send(nil)
end

-- stream_message(cfg, params, cb) — dispatches to the profile's codec.
function M.stream_message(cfg, params, cb)
    local ok, codec = pcall(M.codec, cfg)
    if not ok then
        if cb and cb.on_error then cb.on_error(tostring(codec)) end
        return
    end
    local account = ACCOUNTS[cfg.auth_type]
    if account then return stream_with_account(account, codec, cfg, params, cb) end
    return codec.stream_message(cfg, params, cb)
end

return M
