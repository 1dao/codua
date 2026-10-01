-- Shared OAuth account lifecycle: PKCE login, multi-account persistence and one
-- refresh per account per process. Provider modules (chatgpt, anthropic) supply
-- endpoints and the mapping from token responses to stored credentials. Hosts
-- can replace storage (Android uses its Keystore-backed bridge).
local oauth = dofile('scripts/core/share/xoauth.lua')
local async = dofile('scripts/core/share/xasync.lua')
local http = dofile('scripts/core/share/xhttp_client.lua')
local M = {}

local function http_call(opts)
    return async.await(function(resolve) http.request(opts, resolve) end)
end

-- spec = { label, store_name, provider(proxy, mode), credentials(tokens, previous, now),
--          port?, callback_path?   -- loopback callback (auth.login)
--          redirect_uri?, manual?  -- manual flow: the user pastes `code#state`
--          send_state?, login_hint? }
-- Stored value: { default = key, accounts = { [key] = credentials } }. A bare
-- credential table from older versions loads as the only account.
function M.new(spec)
    local label = spec.label
    local A = { label = label, port = spec.port, callback_path = spec.callback_path, manual = spec.manual }
    local storage, state, pending
    local refreshing, waiters = {}, {}
    local generation = 0

    function A.set_storage(value) storage = value; state = nil end
    local function store()
        if not storage then storage = require('xagent.auth.file_store').new(spec.store_name) end
        return storage
    end
    function A.key(value)
        return (value.account_id or '') .. ':' .. (value.email or '')
    end
    local function load()
        if state then return state end
        local value = store().load()
        -- Logged out is not cached: the host may restore credentials later.
        if type(value) ~= 'table' then return { accounts = {} }
        elseif type(value.accounts) == 'table' then state = value
        else
            local key = value.key or A.key(value)
            value.key = key
            state = { default = key, accounts = { [key] = value } }
        end
        return state
    end
    local function save(value)
        local ok, err = store().save(next(value.accounts) and value or nil)
        assert(ok, err or ('Cannot save ' .. label .. ' credentials'))
        state = value
    end
    local function copy(value)
        local result = { default = value.default, accounts = {} }
        for k, v in pairs(value.accounts) do result.accounts[k] = v end
        return result
    end
    -- Without a key (older profiles) the default account is used; a removed key
    -- stays logged out rather than silently switching accounts.
    function A.account(key)
        local s = load()
        return s.accounts[key or s.default] or (key == nil and select(2, next(s.accounts))) or nil
    end
    function A.accounts()
        local s, list = load(), {}
        for key, value in pairs(s.accounts) do
            list[#list + 1] = { key = key, label = value.email or value.account_id or label, default = key == s.default }
        end
        table.sort(list, function(a, b) return a.label < b.label or (a.label == b.label and a.key < b.key) end)
        return list
    end
    local function put(value)
        local s = copy(load())
        s.accounts[value.key] = value
        if not s.accounts[s.default or ''] then s.default = value.key end
        save(s)
    end
    -- Without a key every account is removed.
    function A.logout(key)
        assert(not next(refreshing), label .. ' refresh in progress')
        A.cancel()
        local s = copy(load())
        if key then s.accounts[key] = nil else s.accounts = {} end
        if not s.accounts[s.default or ''] then s.default = next(s.accounts) end
        save(s)
    end

    A.provider = spec.provider
    -- The key survives refreshes so profiles that name an account keep it.
    function A.credentials(tokens, previous, now)
        local result = spec.credentials(tokens, previous, now)
        result.key = (previous and previous.key) or A.key(result)
        return result
    end

    function A.begin(proxy, now, mode)
        assert(not pending, 'A ' .. label .. ' login is already running')
        assert(not next(refreshing), label .. ' refresh in progress')
        local verifier, challenge, err = oauth.pkce_pair()
        assert(verifier, err)
        local login_state = spec.manual and verifier or assert(oauth.random_urlsafe(43))
        pending = { verifier = verifier, state = login_state, expires = (now or os.time()) + 300,
            provider = spec.provider(proxy, mode),
            redirect_uri = spec.redirect_uri or ('http://localhost:' .. spec.port .. spec.callback_path) }
        return assert(oauth.build_authorize_url(pending.provider, { redirect_uri = pending.redirect_uri,
            state = login_state, code_challenge = challenge }))
    end
    function A.cancel() pending = nil; generation = generation + 1 end
    -- query: the loopback callback's parameters, or (manual flow) the pasted
    -- `code#state` string.
    function A.finish(query, transport, now)
        local p = pending
        local login_generation = generation
        assert(p, 'No ' .. label .. ' login pending')
        if spec.manual and type(query) == 'string' then
            local code, code_state = query:match('^%s*([^#%s]+)#([^%s]+)%s*$')
            assert(code and code_state, '请粘贴完整授权码（code#state）')
            query = { code = code, state = code_state }
        end
        assert(type(query) == 'table', 'Missing authorization code')
        assert((now or os.time()) < p.expires, label .. ' login expired')
        assert(type(query.state) == 'string' and query.state == p.state, 'Invalid OAuth state')
        pending = nil -- one-time callback, including errors
        assert(not query.error, label .. ' authorization rejected: ' .. tostring(query.error))
        assert(type(query.code) == 'string' and query.code ~= '', 'Missing authorization code')
        local tokens, err = oauth.exchange_code(p.provider, { code = query.code, redirect_uri = p.redirect_uri,
            code_verifier = p.verifier, state = spec.send_state and p.state or nil }, transport or http_call)
        assert(tokens, err and err.message or 'Token exchange failed')
        assert(generation == login_generation, label .. ' login cancelled')
        local value = A.credentials(tokens)
        put(value)
        return value
    end

    -- All tabs in this process share one refresh per account and the rotated
    -- credential. `rejected` is an access token the server refused (401) before
    -- it expired; it is refreshed unless another request already replaced it.
    function A.ensure(proxy, transport, now, key, rejected)
        local value = A.account(key)
        assert(value, spec.login_hint or ('请先登录 ' .. label))
        key = value.key
        if value.access_token and value.access_token ~= '' and value.access_token ~= rejected
            and (tonumber(value.expires_at) or 0) > (now or os.time()) + 60 then return value end
        if refreshing[key] then
            local list = waiters[key]
            local result, err = async.await(function(resolve) list[#list + 1] = resolve end)
            assert(result, err); return result
        end
        refreshing[key] = true; waiters[key] = {}
        local ok, result = pcall(function()
            local tokens, err = oauth.refresh_token(spec.provider(proxy), { refresh_token = value.refresh_token }, transport or http_call)
            assert(tokens, err and (label .. ' 刷新失败，请重新登录：' .. tostring(err.oauth_error or err.message)) or 'Token refresh failed')
            local updated = A.credentials(tokens, value, now)
            put(updated)
            return updated
        end)
        local listeners = waiters[key]
        refreshing[key] = nil; waiters[key] = nil
        for _, resolve in ipairs(listeners) do resolve(ok and result or nil, not ok and result or nil) end
        assert(ok, result)
        return result
    end
    return A
end
return M
