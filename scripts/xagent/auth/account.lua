-- Shared OAuth account lifecycle: PKCE login, persistence and one refresh per
-- process. Provider modules (chatgpt, claude) supply endpoints and the mapping
-- from token responses to stored credentials. Hosts can replace storage.
local oauth = dofile('scripts/core/share/xoauth.lua')
local async = dofile('scripts/core/share/xasync.lua')
local http = dofile('scripts/core/share/xhttp_client.lua')
local M = {}

local function http_call(opts)
    return async.await(function(resolve) http.request(opts, resolve) end)
end

-- spec = { label, store_name, provider(proxy), port, callback_path,
--          credentials(tokens, previous, now), send_state? }
function M.new(spec)
    local A = { label = spec.label, port = spec.port, callback_path = spec.callback_path, manual = spec.manual }
    local label = spec.label
    local storage, account, pending, refreshing
    local waiters = {}
    local generation = 0

    function A.set_storage(value) storage = value; account = nil end
    local function store()
        if not storage then storage = require('xagent.auth.file_store').new(spec.store_name) end
        return storage
    end
    function A.account()
        if not account then account = store().load() end
        return account
    end
    local function save(value)
        local ok, err = store().save(value)
        assert(ok, err or ('Cannot save ' .. label .. ' credentials'))
        account = value
    end
    function A.logout()
        assert(not refreshing, label .. ' refresh in progress')
        A.cancel()
        save(nil)
    end
    A.provider = spec.provider
    A.credentials = spec.credentials
    function A.begin(proxy, now)
        assert(not pending, 'A ' .. label .. ' login is already running')
        assert(not refreshing, label .. ' refresh in progress')
        local verifier, challenge, err = oauth.pkce_pair()
        assert(verifier, err)
        local state = spec.manual and verifier or assert(oauth.random_urlsafe(43))
        pending = { verifier = verifier, state = state, expires = (now or os.time()) + 300,
            provider = spec.provider(proxy),
            redirect_uri = spec.redirect_uri or ('http://localhost:' .. spec.port .. spec.callback_path) }
        return assert(oauth.build_authorize_url(pending.provider, { redirect_uri = pending.redirect_uri,
            state = state, code_challenge = challenge }))
    end
    function A.cancel() pending = nil; generation = generation + 1 end
    function A.finish(query, transport, now)
        local p = pending
        local login_generation = generation
        assert(p, 'No ' .. label .. ' login pending')
        if spec.manual and type(query) == 'string' then
            local code, state = query:match('^%s*([^#%s]+)#([^%s]+)%s*$')
            assert(code and state, '请粘贴完整授权码（code#state）')
            query = { code = code, state = state }
        end
        assert((now or os.time()) < p.expires, label .. ' login expired')
        assert(type(query.state) == 'string' and query.state == p.state, 'Invalid OAuth state')
        pending = nil -- one-time callback, including errors
        assert(not query.error, label .. ' authorization rejected: ' .. tostring(query.error))
        assert(type(query.code) == 'string' and query.code ~= '', 'Missing authorization code')
        local tokens, err = oauth.exchange_code(p.provider, { code = query.code, redirect_uri = p.redirect_uri,
            code_verifier = p.verifier, state = spec.send_state and p.state or nil }, transport or http_call)
        assert(tokens, err and err.message or 'Token exchange failed')
        assert(generation == login_generation, label .. ' login cancelled')
        local value = spec.credentials(tokens)
        save(value)
        return value
    end

    -- All tabs in this process share one refresh and the rotated credential.
    function A.ensure(proxy, transport, now)
        local value = A.account()
        assert(value, '请先登录 ' .. label)
        if value.access_token and (tonumber(value.expires_at) or 0) > (now or os.time()) + 60 then return value end
        if refreshing then
            local result, err = async.await(function(resolve) waiters[#waiters + 1] = resolve end)
            assert(result, err); return result
        end
        refreshing = true
        local ok, result = pcall(function()
            local tokens, err = oauth.refresh_token(spec.provider(proxy), { refresh_token = value.refresh_token }, transport or http_call)
            assert(tokens, err and (label .. ' 刷新失败，请重新登录：' .. tostring(err.oauth_error or err.message)) or 'Token refresh failed')
            local updated = spec.credentials(tokens, value, now)
            save(updated)
            return updated
        end)
        refreshing = false
        local listeners = waiters; waiters = {}
        for _, resolve in ipairs(listeners) do resolve(ok and result or nil, not ok and result or nil) end
        assert(ok, result)
        return result
    end
    return A
end
return M
