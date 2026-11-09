-- Native-action ownership boundary, synthetic only; never dispatches a DAW.
local here=arg[1];dofile(here..'/tests/test_processing_copy.lua')
local f=copy_fixture;local M,r,take,item=f.M,f.r,f.take,f.item
local snapshot=M.capture(r)
for _,mode in ipairs({'multiple selected','different selected','foreign project','activation refused','native creation missing'})do
 local dest=f.init({values={},markers={},source=f.source});item.takes={take,dest};item.take=take
 local commands,activations=0,0
 local proxy=setmetatable({
  Main_OnCommandEx=function()commands=commands+1 end,
  SetActiveTake=function(t)activations=activations+1;if mode~='activation refused' then r.SetActiveTake(t)end end,
 },{__index=r})
 if mode=='multiple selected' then proxy.CountSelectedMediaItems=function()return 2 end end
 if mode=='different selected' then proxy.GetSelectedMediaItem=function()return {}end end
 if mode=='foreign project' then proxy.GetItemProjectContext=function()return {}end end
 local ok,why=pcall(M.copy_processing,proxy,item,take,dest,snapshot.processing)
 assert(not ok,tostring(why))
 if mode=='native creation missing' then assert(commands==1 and tostring(why):find('Native built-in envelope creation failed',1,true))
 elseif mode=='activation refused' then assert(commands==0 and activations==1 and tostring(why):find('Cannot activate',1,true))
 else assert(commands==0 and activations==0 and tostring(why):find('sole selected item',1,true))end
 assert(take.builtins.Volume.points[1][2]==.2,'original mutated')
 print('PASS native envelope scope refusal: '..mode)
end
