-- Exercise the actual modal with a headless raygui adapter; no account or file writes.
package.path = 'scripts/?.lua;' .. package.path
local spec = dofile('tests/lua/spec_helper.lua')
local file = assert(io.open('scripts/xagent/gui.lua', 'rb'))
local source = file:read('*a'); file:close()
assert(load(source, '@gui.lua'))
local modal = assert(source:match('(local function open_add_model%(%)\n.-)local function __init%(%)'))
local S = { sidebar_bg = {20,20,20} }
local clicked, buttons, fields, saved, active, opened_url, open_ok
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
    surface=setmetatable({
        icon_button=function(rg,x,y,w,h,kind) return rg.button(x,y,w,h,kind == 'save' and '#2#' or '') end,
    }, {__index=require('xagent.ui.surface')}),
    xproxy=dofile('scripts/core/share/xproxy.lua'),
    xutils={get_config=function() end}, open_url={open=function(url) opened_url=url; return open_ok ~= false end},
    reload_profiles=function() S.profiles={saved} end, T=function() end,
    require=function(name)
        if name == 'xagent.auth.login' then return login end
        if name == 'xagent.auth.chatgpt' then return accounts.chatgpt end
        if name == 'xagent.auth.claude' then return accounts.claude end
        return require(name)
    end,
    raygui={
        get_mouse=function() return -1,-1 end,
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
    spec.it('imports a NVIDIA key and saves the prefilled OpenAI profile only after confirmation',function()
        saved=nil; opened_url=nil
        ui.open(); frame('免费模型'); frame()
        spec.truthy(S.add_model.free_setup)
        spec.nil_value(saved)
        frame('打开官网注册 / 登录')
        spec.equal(opened_url,'https://build.nvidia.com/settings/api-keys')
        frame('打开创建 Token 页面')
        spec.equal(opened_url,'https://build.nvidia.com/settings/api-keys')
        frame('下一步：模型配置')
        spec.truthy(S.add_model.free_setup)
        spec.truthy(S.add_model.err)
        S.add_model.token='  offline-test-key  '
        frame('下一步：模型配置'); frame()
        spec.nil_value(S.add_model.free_setup)
        spec.nil_value(saved)
        spec.equal(S.add_model.token,'offline-test-key')
        frame('#2#')
        spec.equal(saved.base_url,'https://integrate.api.nvidia.com/v1')
        spec.equal(saved.model,'nvidia/nemotron-3-ultra-550b-a55b')
        spec.equal(saved.api_format,'openai')
        spec.equal(saved.api_key,'offline-test-key')
        spec.nil_value(S.add_model)
    end)
    spec.it('keeps NVIDIA onboarding open on browser failure and discards cancelled credentials',function()
        saved=nil; open_ok=false
        ui.open(); frame('免费模型')
        frame('打开创建 Token 页面')
        spec.equal(S.add_model.err,'无法打开浏览器，请稍后重试')
        S.add_model.token='not a key'; frame('下一步：模型配置')
        spec.truthy(S.add_model.free_setup)
        spec.contains(S.add_model.err,'空白')
        frame('#113#')
        spec.nil_value(S.add_model); spec.nil_value(saved)
        open_ok=true
    end)
    spec.it('defaults the free-model dropdown to NVIDIA and resets keys when switching providers',function()
        saved=nil
        ui.open(); frame('免费模型'); frame()
        spec.equal(S.add_model.free_provider,1)
        spec.truthy(buttons['NVIDIA ▼'])
        S.add_model.token='provider-specific-test-key'
        frame('NVIDIA ▼')
        spec.truthy(buttons.NVIDIA)
        spec.truthy(buttons['智谱'])
        spec.truthy(buttons['Cohere North Mini Code (OpenRouter)'])
        frame('Cohere North Mini Code (OpenRouter)'); frame()
        spec.equal(S.add_model.token,'')
        spec.equal(S.add_model.free_provider,3)
        spec.equal(S.add_model.model,'cohere/north-mini-code:free')
        spec.equal(S.add_model.url,'https://openrouter.ai/api/v1')
        spec.equal(S.add_model.name,'Cohere North Mini Code (OpenRouter)')
        frame('打开创建 Token 页面')
        spec.equal(opened_url,'https://openrouter.ai/keys')
        frame('Cohere North Mini Code (OpenRouter) ▼'); frame('智谱'); frame()
        spec.equal(S.add_model.model,'glm-4.7-flash')
        spec.equal(S.add_model.api_format,'openai')
        spec.nil_value(saved)
        frame('#113#')
    end)
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
        login.cancel(); S.add_model.model='claude-test'; frame('#2#')
        spec.equal(saved.auth_type,'claude')
        spec.equal(saved.proxy,'socks5://127.0.0.1:1080')
        spec.equal(saved.base_url,accounts.claude.endpoint)
        spec.nil_value(S.add_model)
    end)
end)
local failures=spec.finish()
return {__init=function() if failures>0 then os.exit(1) end; xthread.stop(0) end}
