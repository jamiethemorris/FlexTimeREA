-- Actual Lua -> real Python/native/Audio publication -> synthetic host import.
-- The host copy/rollback seam remains explicitly synthetic, not live REAPER.
local here,prefix,media=arg[1],assert(arg[2]),assert(arg[3]);dofile(here..'/tests/test_processing_copy.lua')
local f=copy_fixture;local M,r,take,item=f.M,f.r,f.take,f.item
f.source.path=media;f.source.length=12;item.values.D_LENGTH=4;take.values.D_STARTOFFS=1
local add=r.AddTakeToMediaItem
r.AddTakeToMediaItem=function(i)return f.init(add(i))end
local setchunk=r.SetItemStateChunk
r.SetItemStateChunk=function(i,s)
 if s==f.baseline then i.take=take;i.takes={take};return true end
 return setchunk(i,s)
end
local execute=r.ExecProcess;local counter=0;local evidence={}
local function run(rate,copy_failure,attach_failure)
 counter=counter+1;item.take=take;item.takes={take};take.values.D_PLAYRATE=rate
 take.markers={{rate,1+rate,0},{3*rate,1+3*rate,0}}
 local _,baseline=r.GetItemStateChunk(item);f.baseline=baseline
 local nonce='job-'..prefix..counter
 local g=0;r.genGuid=function()g=g+1;return '{'..prefix..counter..(g==1 and '' or 'env'..g)..'}'end
 local normalcopy=r.TakeFX_CopyToTake
 if copy_failure then r.TakeFX_CopyToTake=function()error('injected FX copy failure')end end
 f.hooks.attach_refusal=attach_failure
 local command,timeout
 r.ExecProcess=function(c,t)command=c;timeout=t;return execute(c,t)end
 local ok,path=M.run(r,here)
 r.TakeFX_CopyToTake=normalcopy;f.hooks.attach_refusal=nil
 if copy_failure or attach_failure then
  assert(not ok,tostring(path));assert(item.take==take and #item.takes==1 and f.undos()==0,'rollback/original ownership')
  if copy_failure then assert(tostring(path):find('injected FX copy failure',1,true))end
 else
  assert(ok,path);assert(path==here..'/tests/Audio/FlexTime-'..nonce..'.wav','imported diagnostic path')
  local dest=item.take;assert(dest~=take and #item.takes==2 and #dest.markers==0 and dest.values.D_PLAYRATE==1 and dest.values.D_STARTOFFS==0)
  for k,v in pairs({D_VOL=-.625,D_PAN=.375,D_PANLAW=.5})do assert(dest.values[k]==v and take.values[k]==v,'editable scalar copy')end
  assert(#dest.effects==1 and #dest.builtins.Volume.points==3 and #dest.builtins.Pan.points==3)
  assert(dest.effects[1].guid~=take.effects[1].guid and not dest.effects[1].offline and not dest.effects[1].enabled)
  local job=f.read(here..'/runs/'..nonce..'/job.json')
  assert(job:find('"crop_start":48000',1,true) and job:find('"crop_end":'..math.floor((1+4*rate)*48000),1,true),'nonunity crop')
  assert(M.json(take.markers)==M.json({{rate,1+rate,0},{3*rate,1+3*rate,0}}),'original markers changed')
  local line=assert(io.open(here..'/evidence/'..prefix..'-'..counter..'.txt','wb'))
  line:write(path,'\n',here..'/runs/'..nonce,'\n',tostring(timeout),'\n');line:close()
 end
 assert(f.undos()==0,'unbalanced undo');print('PASS real helper rate='..rate..' copy_failure='..tostring(copy_failure)..' attachment_failure='..tostring(attach_failure))
end
run(.5,false,false);run(2,false,false)
-- Reuse a real verified same-dimension output for failure injections, no extra DSP.
local verified=here..'/runs/job-'..prefix..'1/result.txt'
r.ExecProcess=function(c,t)
 local leaf=assert(c:match('"([^"]+)/job.json"$'));local name=assert(leaf:match('/([^/]+)$'))
 local text=f.read(verified);text=text:gsub('job%-'..prefix..'1',name)
 -- Publish a separate owned copy only in this explicit synthetic helper seam.
 local src=assert(io.open(here..'/tests/Audio/FlexTime-job-'..prefix..'1.wav','rb'));local data=src:read('*a');src:close()
 local dest=assert(io.open(here..'/tests/Audio/FlexTime-'..name..'.wav','wb'));dest:write(data);dest:close()
 local receipt=assert(io.open(leaf..'/result.txt','wb'));receipt:write(text);receipt:close()
 return '0\nsynthetic receipt copied from verified output\n'
end
-- execute is now the explicit receipt seam rather than the actual helper.
execute=r.ExecProcess
run(.5,true,false);run(.5,false,true)
