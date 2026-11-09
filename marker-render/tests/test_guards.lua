-- Portable admission/failure regression cases after the successful tracer bullet.
local here,phase=arg[1],arg[2]
dofile(here..'/tests/test_action.lua')
local f=fixture;local M,r,item,take,source,hooks=f.M,f.r,f.item,f.take,f.source,f.hooks
item.take=take;item.takes={take}
r.TakeFX_GetOffline=function()return false end -- container fixture is online
local passed=0
local function rejects(name,edit,undo,needle)
 edit();local ok,err=pcall(M.capture,r);undo();assert(not ok and tostring(err):find(needle,1,true),name..': '..tostring(err));passed=passed+1
end
rejects('base rate',function()take.values.D_PLAYRATE=0 end,function()take.values.D_PLAYRATE=1 end,'playrate')
rejects('pitch',function()take.values.D_PITCH=1 end,function()take.values.D_PITCH=0 end,'pitch')
rejects('preserve pitch',function()take.values.B_PPITCH=0 end,function()take.values.B_PPITCH=1 end,'pitch')
rejects('nonzero slope',function()take.markers[2][3]=.2 end,function()take.markers[2][3]=0 end,'slope')
rejects('duplicate source',function()take.markers[2][2]=.5 end,function()take.markers[2][2]=1.5 end,'increase')
rejects('ratio',function()take.markers[2][1]=2.9 end,function()take.markers[2][1]=1.5 end,'ratio')
rejects('nonfinite',function()take.markers[2][1]=0/0 end,function()take.markers[2][1]=1.5 end,'Invalid')
rejects('all takes play',function()item.values.B_ALLTAKESPLAY=1 end,function()item.values.B_ALLTAKESPLAY=0 end,'all-takes')
rejects('FX container',function()take.fx=1 end,function()take.fx=0 end,'containers')
rejects('unknown automation',function()take.envelopes=1 end,function()take.envelopes=0 end,'Unsupported take envelope')
rejects('spectral',function()take.values['IP_SPECEDIT:CNT']=1 end,function()take.values['IP_SPECEDIT:CNT']=0 end,'Spectral')
rejects('channel',function()take.values.I_CHANMODE=2 end,function()take.values.I_CHANMODE=0 end,'Channel')
rejects('source topology',function()r.GetMediaSourceParent=function()return {}end end,function()r.GetMediaSourceParent=function()return nil end end,'Bare WAV')
rejects('source extent',function()source.length=0 end,function()source.length=4 end,'mono/stereo')
if phase=='capture-only' then print('PASS portable capture admission cases: '..passed);return end
local original_exec=r.ExecProcess
local counter=0
local function attempt(name,hook,needle)
 counter=counter+1;r.genGuid=function()return '{'..phase..counter..'}' end
 local before=f.imports();hooks.exec=hook
 local ok,why=M.run(r,here);hooks.exec=nil
 assert(not ok and tostring(why):find(needle,1,true),name..': '..tostring(why))
 assert(f.imports()==before and item.take==take and #take.markers==3 and f.undos()==0,name..' mutated original')
 passed=passed+1
end
attempt('helper failure',function()return '1\nnative failure'end,'Helper failed')
attempt('helper timeout',function()return '-1\ntimeout'end,'Helper failed')
attempt('no verified receipt',function()return '0\n'end,'verified success')
attempt('project edited',function(command)hooks.exec=nil;local result=original_exec(command);f.change();return result end,'Project/selection/source changed')
attempt('item edited without revision',function(command)hooks.exec=nil;local result=original_exec(command);item.chunk='edited after snapshot';return result end,'Item/take edited')
item.chunk='original markers and take state'
local old=f.read(source.path)
attempt('source edited',function(command)hooks.exec=nil;local result=original_exec(command);local out=assert(io.open(source.path,'ab'));out:write('changed');out:close();return result end,'Source file edited')
local out=assert(io.open(source.path,'wb'));out:write(old);out:close()
attempt('receipt trailing garbage',function(command)hooks.exec=nil;local result=original_exec(command);local leaf=assert(command:match('"([^"]+)/job.json"$'));local out=assert(io.open(leaf..'/result.txt','ab'));out:write('trailing garbage');out:close();return result end,'Invalid helper success receipt')
attempt('rendered file edited',function(command)hooks.exec=nil;local result=original_exec(command);local leaf=assert(command:match('"([^"]+)/job.json"$'));local output=assert(f.read(leaf..'/result.txt'):match('\n([^\n]+)\n$'));local out=assert(io.open(output,'ab'));out:write('x');out:close();return result end,'Rendered WAV identity mismatch')
attempt('source decoder failure',function(command)hooks.exec=nil;local result=original_exec(command);hooks.create=true;return result end,'could not open')
hooks.create=nil
-- Track explicit destruction: attached sources belong to the host, including rollback.
local created,destroyed=0,0;local attached={}
local create,destroy,attach=r.PCM_Source_CreateFromFile,r.PCM_Source_Destroy,r.SetMediaItemTake_Source
r.PCM_Source_CreateFromFile=function(path)local pcm=create(path);if pcm then created=created+1 end;return pcm end
r.PCM_Source_Destroy=function(pcm)assert(not attached[pcm],'Attached PCM source double-freed');destroyed=destroyed+1;destroy(pcm)end
r.SetMediaItemTake_Source=function(t,pcm)local ok=attach(t,pcm);if ok then attached[pcm]=true end;return ok end
counter=counter+1;r.genGuid=function()return '{'..phase..counter..'}' end;hooks.attach_refusal=true
local ok,why=M.run(r,here);hooks.attach_refusal=nil
assert(not ok,'Failed attachment accepted: '..tostring(why))
assert(item.take==take and #item.takes==1 and #take.markers==3 and item.chunk=='original markers and take state' and f.undos()==0,'Attachment refusal rollback/original/Undo regression')
print('Attachment refusal: created='..created..' destroyed='..destroyed..' original_retained=true undo_balanced=true')
assert(created==1 and destroyed==1,'UNATTACHED SOURCE LEAK: failed SetMediaItemTake_Source was recorded as attached')
passed=passed+1
-- Rollback is fake-API evidence, not proof of native SetItemStateChunk ownership.
counter=counter+1;r.genGuid=function()return '{'..phase..counter..'}' end;hooks.setter=true
local ok,why=M.run(r,here);hooks.setter=nil
assert(not ok and tostring(why):find('injected setter failure',1,true));assert(item.take==take and #item.takes==1 and f.undos()==0)
passed=passed+1
counter=counter+1;r.genGuid=function()return '{'..phase..counter..'}' end;hooks.ignore_pitch=true
local ok,why=M.run(r,here);hooks.ignore_pitch=nil
assert(not ok and tostring(why):find('readback',1,true),'Unverified take pitch accepted: '..tostring(why));assert(item.take==take and #item.takes==1 and f.undos()==0)
passed=passed+1
local restore=r.SetItemStateChunk
for _,mode in ipairs({'mismatch','throw'})do
 counter=counter+1;r.genGuid=function()return '{'..phase..counter..'}' end;hooks.setter=true
 r.SetItemStateChunk=function(i,s)if mode=='throw' then error('injected restore error')end;i.chunk='unverified restoration';i.take=take;i.takes={take};take.values.D_PLAYRATE=7;return true end
 local ok,why=M.run(r,here);hooks.setter=nil;r.SetItemStateChunk=restore
 assert(not ok and tostring(why):find('ROLLBACK FAILED',1,true),'Rollback was not verified: '..tostring(why));assert(f.undos()==0,'Undo block leaked on rollback failure')
 item.take=take;item.takes={take};take.values.D_PLAYRATE=1;item.chunk='original markers and take state';passed=passed+1
end
print('PASS portable admission/failure cases: '..passed)
