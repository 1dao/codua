-- ChatGPT account: OpenAI's public Codex client against the Responses backend.
local oauth = dofile('scripts/core/share/xoauth.lua')
local json = require('xutils')

local function claims(token)
    if type(token) ~= 'string' then return {} end
    local encoded = token:match('^[^.]+%.([^.]+)%.')
    if not encoded then return {} end
    local ok, value = pcall(function() return json.json_unpack(oauth.b64url_decode(encoded)) end)
    return ok and type(value) == 'table' and value or {}
end

local M = require('xagent.auth.account').new({
    label = 'ChatGPT', store_name = 'chatgpt', port = 1455, callback_path = '/auth/callback',
    provider = function(proxy)
        return { auth_url = 'https://auth.openai.com/oauth/authorize', token_url = 'https://auth.openai.com/oauth/token',
            client_id = 'app_EMoamEEZ73f0CkXaXp7hrann', client_auth = 'none', token_encoding = 'form',
            scope = 'openid profile email offline_access', proxy = proxy, token_timeout_ms = 30000,
            authorize_params = { id_token_add_organizations = 'true', codex_cli_simplified_flow = 'true', originator = 'codua' } }
    end,
    credentials = function(tokens, previous, now)
        assert(type(tokens.access_token) == 'string' and tokens.access_token ~= '', 'Missing access token')
        previous = previous or {}
        local id, access = claims(tokens.id_token), claims(tokens.access_token)
        local function account_id(c)
            return c.chatgpt_account_id or (c['https://api.openai.com/auth'] or {}).chatgpt_account_id
                or (c.organizations and c.organizations[1] and c.organizations[1].id)
        end
        local result = { access_token = tokens.access_token,
            refresh_token = tokens.refresh_token or previous.refresh_token,
            account_id = account_id(id) or account_id(access) or previous.account_id,
            email = id.email or access.email or previous.email,
            expires_at = (now or os.time()) + (tonumber(tokens.expires_in) or 3600) }
        assert(type(result.refresh_token) == 'string' and result.refresh_token ~= '', 'Missing refresh token')
        return result
    end,
})
M.endpoint = 'https://chatgpt.com/backend-api/codex/responses'
return M
