-- Claude account (Pro/Max subscription): the public Claude Code OAuth client.
-- Tokens are sent as Bearer to the Messages API with the OAuth beta header;
-- see llm/anthropic.lua for the request-side requirements.
local M = require('xagent.auth.account').new({
    label = 'Claude', store_name = 'claude', manual = true,
    redirect_uri = 'https://console.anthropic.com/oauth/code/callback',
    -- Anthropic's token endpoint validates the state it issued with the code.
    send_state = true,
    provider = function(proxy)
        return { auth_url = 'https://claude.ai/oauth/authorize', token_url = 'https://console.anthropic.com/v1/oauth/token',
            client_id = '9d1c250a-e61b-44d9-88ed-5944d1962f5e', client_auth = 'none', token_encoding = 'json',
            scope = 'org:create_api_key user:profile user:inference', proxy = proxy, token_timeout_ms = 30000,
            authorize_params = { code = 'true' } }
    end,
    credentials = function(tokens, previous, now)
        assert(type(tokens.access_token) == 'string' and tokens.access_token ~= '', 'Missing access token')
        previous = previous or {}
        local acct = type(tokens.account) == 'table' and tokens.account or {}
        local result = { access_token = tokens.access_token,
            refresh_token = tokens.refresh_token or previous.refresh_token,
            account_id = acct.uuid or previous.account_id,
            email = acct.email_address or previous.email,
            expires_at = (now or os.time()) + (tonumber(tokens.expires_in) or 3600) }
        assert(type(result.refresh_token) == 'string' and result.refresh_token ~= '', 'Missing refresh token')
        return result
    end,
})
M.endpoint = 'https://api.anthropic.com'
return M
