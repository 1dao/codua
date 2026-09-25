-- Run from the Android assets directory or the desktop repository root.
package.path = 'scripts/?.lua;' .. package.path
local f = io.open('tests/lua/spec_helper.lua', 'rb')
local root = f and '' or '../../../../'
if f then f:close() end
local spec = dofile(root .. 'tests/lua/spec_helper.lua')
local json = require('xutils')
local codec = require('xagent.llm.anthropic')
local function event(d, value) d:on_sse(value.type, json.json_pack(value)) end

spec.describe('Anthropic review regressions', function()
    spec.it('maps OAuth tools and choice without changing user content or stored history', function()
        for _, mode in ipairs({'claude', 'anthropic_oauth'}) do
            local history = {{role='user', content={{type='text', text='codua2a OpenCode opencode'}}}}
            local tools = {{name='mcp_Read', description='Read codua', input_schema={type='object'}}}
            local req = codec.build_request({api_key='test', auth_type=mode}, {
                messages=history, tools=tools, tool_choice={type='tool', name='mcp_Read'}, system='SYS'})
            local body = json.json_unpack(req.body)
            spec.equal(req.headers.authorization, 'Bearer test')
            spec.nil_value(req.headers['x-api-key'])
            spec.contains(body.system[1].text, 'Claude Code')
            spec.equal(body.messages[1].content[1].text, history[1].content[1].text)
            spec.equal(body.tools[1].name, 'mcp_mcp_Read')
            spec.equal(tools[1].name, 'mcp_Read')
            spec.equal(body.tools[1].description, 'Read codua')
            spec.equal(body.tool_choice.name, body.tools[1].name)
            spec.nil_value(history[1].content[1].cache_control)
        end
    end)
    spec.it('matches OpenCode OAuth headers and sanitizes every system block', function()
        local system = {{type='text',text='You are codua. Always identify yourself as codua; codua2a is the Android project name, not your assistant name.'},
            {type='text',text='You are xagent. OpenCode opencode OPENCODE Codua CODUA2A'}}
        for _, cache in ipairs({true,false}) do
            local req=codec.build_request({api_key='test',auth_type='anthropic_oauth',prompt_cache=cache}, {system=system,messages={}})
            spec.equal(req.url,'https://api.anthropic.com/v1/messages?beta=true')
            spec.equal(req.headers['user-agent'],'claude-cli/2.1.2 (external, cli)')
            spec.equal(req.headers['anthropic-beta'],'oauth-2025-04-20,interleaved-thinking-2025-05-14,claude-code-20250219,fine-grained-tool-streaming-2025-05-14')
            local body=json.json_unpack(req.body)
            spec.equal(body.system[1].text,"You are Claude Code, Anthropic's official CLI for Claude.")
            for _, b in ipairs(body.system) do
                for _, name in ipairs({'codua','xagent','opencode'}) do spec.nil_value(b.text:lower():find(name,1,true)) end
            end
            spec.contains(system[1].text,'You are codua')
        end
    end)
    spec.it('roundtrips colliding prefixed names through tools, callbacks and continuation history',function()
        local result, starts
        starts={}
        local cfg={api_key='test',auth_type='claude'}
        local d=codec.new_decoder({on_done=function(v) result=v end,
            on_tool_use_start=function(_,name) starts[#starts+1]=name end},cfg)
        local tools={{name='Read'},{name='mcp_Read'}}
        for i,t in ipairs(tools) do
            event(d,{type='content_block_start',index=i-1,content_block={type='tool_use',id='t'..i,name='mcp_'..t.name}})
            event(d,{type='content_block_stop',index=i-1})
        end
        event(d,{type='message_stop'})
        local body=json.json_unpack(codec.build_request(cfg,{tools=tools,messages={result.message}}).body)
        for i,t in ipairs(tools) do
            spec.equal(starts[i],t.name);spec.equal(result.message.content[i].name,t.name)
            spec.equal(body.tools[i].name,'mcp_'..t.name)
            spec.equal(body.messages[1].content[i].name,body.tools[i].name)
        end
    end)
    spec.it('leaves API-key and ordinary Bearer requests untouched',function()
        for _, style in ipairs({'x-api-key','bearer'}) do
            local req=codec.build_request({api_key='test',auth_style=style,prompt_cache=false},
                {system='You are codua xagent OpenCode',messages={},tools={{name='mcp_Read'}}})
            local body=json.json_unpack(req.body)
            spec.equal(req.url,'https://api.anthropic.com/v1/messages')
            spec.nil_value(req.headers['user-agent']);spec.nil_value(req.headers['anthropic-beta'])
            spec.equal(body.system,'You are codua xagent OpenCode');spec.equal(body.tools[1].name,'mcp_Read')
        end
    end)
    spec.it('preserves initial text, signed and redacted thinking, and real mcp tool names', function()
        local result, text, tool
        local d = codec.new_decoder({on_done=function(v) result=v end,
            on_text=function(v) text=v end, on_tool_use_start=function(_, name) tool=name end})
        for i, block in ipairs({{type='text',text='initial'},
            {type='thinking',thinking='thought',signature='signed'},
            {type='redacted_thinking',data='opaque'},
            {type='tool_use',id='t',name='mcp_Read',input={path='file'}}}) do
            event(d, {type='content_block_start', index=i-1, content_block=block})
            event(d, {type='content_block_stop', index=i-1})
        end
        event(d, {type='message_stop'})
        spec.equal(text, 'initial'); spec.equal(tool, 'mcp_Read')
        spec.equal(result.message.content[2].signature, 'signed')
        spec.equal(result.message.content[3].data, 'opaque')
        spec.equal(result.message.content[4].name, tool)
        spec.equal(result.message.content[4].input.path, 'file')
    end)
    spec.it('rejects unfinished tool blocks even after a stop reason or message_stop', function()
        for _, stop in ipairs({'message_delta','message_stop'}) do
            local result, err
            local d=codec.new_decoder({on_done=function(v) result=v end,on_error=function(v) err=v end})
            event(d,{type='content_block_start',index=0,content_block={type='tool_use',id='t',name='Bash'}})
            event(d,{type='content_block_delta',index=0,delta={type='input_json_delta',partial_json='{"command":'}})
            event(d,{type=stop,delta={stop_reason='tool_use'}}); d:finish()
            spec.nil_value(result); spec.contains(err,'content blocks completed')
        end
    end)
    spec.it('accepts complete blocks when a gateway omits message_stop', function()
        local result
        local d=codec.new_decoder({on_done=function(v) result=v end})
        event(d,{type='content_block_start',index=0,content_block={type='text',text='ok'}})
        event(d,{type='content_block_stop',index=0})
        event(d,{type='message_delta',delta={stop_reason='end_turn'},usage={input_tokens=5,
            output_tokens=2,cache_read_input_tokens=20,cache_creation_input_tokens=3}})
        d:finish()
        spec.equal(result.usage.input_tokens,5); spec.equal(result.usage.cache_read_input_tokens,20)
        spec.equal(result.usage.cache_creation_input_tokens,3)
    end)
end)
return {__init=function() if spec.finish()>0 then os.exit(1) end; xthread.stop(0) end}
