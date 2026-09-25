-- Exercise the actual modal with a headless raygui adapter; no account or file writes.
package.path = 'scripts/?.lua;' .. package.path
local spec = dofile('tests/lua/spec_helper.lua')
local file = assert(io.open('scripts/xagent/gui.lua', 'rb'))
local source = file:read('*a'); file:close()
assert(load(source, '@gui.lua'))
local modal = assert(source:match('(local function open_add_model%(%)\n.-)local function __init%(%)'))
local S = { sidebar_bg = {20,20,20} }
local clicked, buttons, fields, saved, active
local accounts = {
    chatgpt = {endpoint='https://chatgpt.com/backend-api/codex/responses', label='ChatGPT'},
    claude = {endpoint='https://api.anthropic.com', label='Claude'},
}
for _, a in pairs(accounts) do a.account=function() return {} end; a.logout=function() end end
local login = {
    cancel=function() active=nil end,
    running=function(a) return active ~= nil and (not a or a == active) end,
    start=function(opts) active=opts.auth; return 'https://example.invalid' end,
}
local config = require('xagent.config')
local cfg = setmetatable({
    add_user_model=function(m) saved=m; return true end,
}, {__index=config})
local env = setmetatable({
    S=S, config=cfg, markdown={}, sanitize_label=function(s) return s end,
    xproxy=dofile('scripts/core/share/xproxy.lua'),
    xutils={get_config=function() end}, open_url={open=function() return true end},
    reload_profiles=function() S.profiles={saved} end, T=function() end,
    require=function(name)
        if name == 'xagent.auth.login' then return login end
        if name == 'xagent.auth.chatgpt' then return accounts.chatgpt end
        if name == 'xagent.auth.claude' then return accounts.claude end
        return require(name)
    end,
    raygui={
        draw_rectangle=function() end,
        label=function(_,_,_,_,text) fields[text]=true end,
        textbox=function(_,_,_,_,text,edit) return text,edit end,
        button=function(_,_,_,_,label) buttons[label]=true; return label == clicked end,
    },
}, {__index=_G})
local ui = assert(load(modal .. '\nreturn {open=open_add_model,draw=draw_add_model_modal}', '@gui-modal', 't', env))()
local function frame(click)
    clicked=click; buttons={}; fields={}; ui.draw(960,700)
end
spec.describe('GUI authentication form',function()
    spec.it('defaults to token and reveals account choices only after authorization',function()
        ui.open(); frame()
        spec.equal(S.add_model.auth,'token'); spec.truthy(fields.Token)
        spec.nil_value(buttons.Claude); spec.nil_value(buttons.ChatGPT)
        frame('授权')
        spec.truthy(buttons.Claude); spec.truthy(buttons.ChatGPT)
        spec.equal(S.add_model.url,accounts.claude.endpoint)
        spec.equal(S.add_model.proxy,'socks5://127.0.0.1:1080')
        spec.nil_value(fields.Token)
    end)
    spec.it('restores token settings and preserves a custom authorization proxy',function()
        ui.open(); S.add_model.url='https://example.invalid/v1'; S.add_model.proxy='http://127.0.0.1:8080'
        frame('授权'); frame('ChatGPT')
        spec.equal(S.add_model.proxy,'http://127.0.0.1:8080')
        frame('Token')
        spec.equal(S.add_model.url,'https://example.invalid/v1')
        spec.equal(S.add_model.proxy,'http://127.0.0.1:8080')
        spec.nil_value(buttons.Claude)
    end)
    spec.it('saves the Claude account marker and displays manual code controls',function()
        ui.open(); frame('授权'); frame('登录 Claude'); frame()
        spec.truthy(fields['授权码'])
        spec.truthy(buttons['提交浏览器返回的完整授权码'])
        login.cancel(); S.add_model.model='claude-test'; frame('保存')
        spec.equal(saved.auth_type,'claude')
        spec.equal(saved.proxy,'socks5://127.0.0.1:1080')
        spec.equal(saved.base_url,accounts.claude.endpoint)
        spec.nil_value(S.add_model)
    end)
end)
local failures=spec.finish()
return {__init=function() if failures>0 then os.exit(1) end; xthread.stop(0) end}
