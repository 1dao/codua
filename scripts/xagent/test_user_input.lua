-- Offline, interactive smoke check: bin/xnet.exe scripts/xagent/test_user_input.lua
-- Uses the production question form without loading credentials or calling an API.
package.path = 'scripts/?.lua;tools/?.lua;' .. package.path
package.cpath = 'tools/?.dll;tools/?.so;' .. package.cpath
local rg = require('raygui')
local ui = require('xagent.ui.user_input')
local tool = require('xagent.tools.ask_user_question')
local json = require('xutils')
local tab = { sess = {} }
local result
return {
    __tick_ms = 16,
    __init = function()
        rg.init(960, 500, 'Codua - question card preview')
        local chars = {}
        for cp = 0x4e00, 0x9fff do chars[#chars + 1] = utf8.char(cp) end
        rg.load_system_font(16, table.concat(chars) .. '？·—✓○，：×‹›')
        require('styles.soft').apply(rg)
        rg.set_style(rg.DEFAULT, rg.TEXT_SIZE, 16)
        rg.set_style(rg.DEFAULT, rg.BACKGROUND_COLOR, 0xffffffff)
        rg.set_style(rg.DEFAULT, rg.TEXT_COLOR_NORMAL, 0x202124ff)
        rg.set_style(rg.TEXTBOX, rg.TEXT_COLOR_NORMAL, 0x202124ff)
        rg.set_style(rg.TEXTBOX, rg.TEXT_COLOR_FOCUSED, 0x202124ff)
        local co = coroutine.create(function()
            result = ui.bind(tab, tab.sess)(assert(tool.validate({ questions = {
                { id = 'platform', question = '你希望做桌面应用还是网页应用？', options = {
                    { label = '桌面应用' },
                    { label = '网页应用' },
                } },
                { id = 'features', question = '第一版需要哪些功能？', multi_select = true, options = {
                    { label = '搜索', description = '快速定位内容。' },
                    { label = '历史记录', description = '保存并继续之前的工作。' },
                } },
                { id = 'notes', question = '还有哪些需要补充的要求？' },
            } })))
            print(assert(json.json_pack(result)))
        end)
        assert(coroutine.resume(co))
    end,
    __update = function()
        if rg.should_close() then xthread.stop(0); return end
        rg.begin()
        local w, h = rg.screen_size()
        local colors = { bg = {255,255,255}, text = {32,33,36}, accent = {65,128,255} }
        if tab.pending_input then
            local card_h = math.min(ui.height(tab, w - 40, function(s) return rg.measure_text(s, 16) end), h - 240)
            ui.draw(tab, rg, 20, h - 205 - card_h, w - 40, card_h, colors,
                false, function(t) t.sess.cancelled = true; ui.cancel(t) end)
        else
            rg.label(20, 70, w - 40, 30, result.cancelled and '已停止' or '回答已提交，检查完成')
        end
        -- This standalone fixture previews only the question card. The app
        -- continues to use its original composer and toolbar below the card.
        rg.label(30, h - 175, w - 60, 24, '问题卡片离线预览 · 主界面下方输入框及工具栏保持原样')
        rg.finish()
    end,
    __uninit = function() tab.sess.cancelled = true; ui.cancel(tab); rg.close() end,
}
