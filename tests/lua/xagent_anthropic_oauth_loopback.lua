-- Real HTTP/SSE transport, synthetic credentials only. Run from desktop root
-- or Android assets. Covers OAuth prefix mapping through common.stream_message.
package.path = 'scripts/?.lua;' .. package.path
local json = require('xutils')
local anthropic = require('xagent.llm.anthropic')
local server, finished, started, run_case
local buffers = {}
local port = 18239
local function finish(ok, err)
    if finished then return end
    finished = true
    print((ok and 'PASS ' or 'FAIL ') .. tostring(err))
    if server then server:close('done'); server=nil end
    xthread.stop(ok and 0 or 1)
end
local function ev(value) return 'data: ' .. json.json_pack(value) .. '\n\n' end
local function respond(conn, raw)
    local split = assert(raw:find('\r\n\r\n',1,true))
    local head, body = raw:sub(1,split-1), json.json_unpack(raw:sub(split+4))
    local oauth = head:find('?beta=true',1,true) ~= nil
    if oauth then
        assert(head:lower():find('user-agent: claude-cli/2.1.2 (external, cli)',1,true))
        assert(head:lower():find('authorization: bearer test-token',1,true))
        assert(not head:lower():find('x-api-key:',1,true))
        for _, block in ipairs(body.system) do
            assert(not block.text:lower():find('codua',1,true))
            assert(not block.text:lower():find('xagent',1,true))
            assert(not block.text:lower():find('opencode',1,true))
        end
        assert(body.system[1].text=="You are Claude Code, Anthropic's official CLI for Claude.")
    else
        assert(head:lower():find('x-api-key: test-token',1,true))
        assert(not head:lower():find('claude-cli',1,true))
    end
    assert(body.messages[1].content[1].text=='user code: codua OpenCode')
    local prefix=oauth and 'mcp_' or ''
    assert(body.tools[1].name==prefix..'Read' and body.tools[2].name==prefix..'mcp_Read')
    assert(body.tool_choice.name==body.tools[2].name)
    if #body.messages>1 then
        assert(body.messages[2].content[1].name==prefix..'mcp_Read')
        assert(body.messages[2].content[1].input.path=='codua/file')
        assert(body.messages[3].content[1].content=='codua tool result')
    end
    local data=ev({type='message_start',message={id='m',usage={input_tokens=1}}}) ..
        ev({type='content_block_start',index=0,content_block={type='tool_use',id='t',name=prefix..'mcp_Read'}}) ..
        ev({type='content_block_delta',index=0,delta={type='input_json_delta',partial_json='{"path":"codua/file"}'}}) ..
        ev({type='content_block_stop',index=0}) ..
        ev({type='message_delta',delta={stop_reason='tool_use'},usage={output_tokens=2}}) .. ev({type='message_stop'})
    conn:send_raw('HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n')
    -- Three-byte HTTP chunks split names and JSON tokens across body callbacks.
    for i=1,#data,3 do
        local part=data:sub(i,i+2);conn:send_raw(string.format('%x\r\n%s\r\n',#part,part))
    end
    conn:send_raw('0\r\n\r\n');conn:close('done')
end
run_case=function(i, history)
    if i>3 then return finish(true,'OAuth request identity, tool continuation and API-key isolation over real sockets') end
    local cfg={api_key='test-token',base_url='http://127.0.0.1:'..port,model='test',max_retries=0,
        auth_type=i<3 and 'anthropic_oauth' or nil}
    local callback_name
    local messages={{role='user',content={{type='text',text='user code: codua OpenCode'}}}}
    if history then
        messages[2]=history; messages[3]={role='user',content={{type='tool_result',tool_use_id='t',content='codua tool result'}}}
    end
    anthropic.stream_message(cfg,{system='You are codua. xagent OpenCode',messages=messages,
        tools={{name='Read',input_schema={type='object'}},{name='mcp_Read',input_schema={type='object'}}},
        tool_choice={type='tool',name='mcp_Read'}},{
        on_tool_use_start=function(_,name) callback_name=name end,
        on_error=function(err) finish(false,err) end,
        on_done=function(result)
            local ok,err=pcall(function()
                assert(callback_name=='mcp_Read')
                assert(result.message.content[1].name=='mcp_Read')
                assert(result.message.content[1].input.path=='codua/file')
            end)
            if not ok then return finish(false,err) end
            run_case(i+1,i==1 and result.message or nil)
        end,
    })
end
return {
    __tick_ms=5, __thread_handle=function() end,
    __init=function()
        assert(xnet.init());started=os.time()
        server=assert(xnet.listen('127.0.0.1',port,{
            on_connect=function(conn) conn:set_framing({type='raw',max_packet=1024*1024});buffers[conn]='' end,
            on_close=function(conn) buffers[conn]=nil end,
            on_packet=function(conn,data)
                local raw=(buffers[conn] or '')..data;buffers[conn]=raw
                local split=raw:find('\r\n\r\n',1,true)
                local length=split and tonumber(raw:sub(1,split):lower():match('content%-length:%s*(%d+)'))
                if length and #raw>=split+3+length then
                    buffers[conn]=nil
                    local ok,err=pcall(respond,conn,raw)
                    if not ok then finish(false,err) end
                end
                return #data
            end,
        }))
        run_case(1)
    end,
    __update=function() if os.time()-started>10 then finish(false,'loopback timed out') end end,
    __uninit=function() if server then server:close('uninit') end;xnet.uninit() end,
}
