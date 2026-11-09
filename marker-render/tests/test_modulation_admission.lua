-- Synthetic named-config boundary, based on measured native ordinary-envelope flags.
-- No DAW, rendering, or modulation support is claimed.
local here=arg[1];dofile(here..'/tests/test_processing_copy.lua')
local f=copy_fixture;local M,r,take,item=f.M,f.r,f.take,f.item
local native=r.TakeFX_GetNamedConfigParm
local replies={mod={true,'1'},lfo={true,'0'},acs={true,'0'},plink={true,'0'}}
function r.TakeFX_GetNamedConfigParm(t,i,k)
 local p,kind=k:match('^param%.(%d+)%.(%w+)%.active$')
 if p then
  if p~='0' then return false,'' end -- measured ordinary/offline and absent defaults
  return table.unpack(replies[kind])
 end
 return native(t,i,k)
end
local function capture(label)
 local ok,s=pcall(M.capture,r);assert(ok,label..': '..tostring(s));return s
end
local snapshot=capture('ordinary global mod=1 with every source disabled')
local dest=f.init({values={},markers={},source={}});item.takes={take,dest}
assert(M.copy_processing(r,item,take,dest,snapshot.processing)==dest,'ordinary copy refused')
item.takes={take};item.take=take
replies.mod={true,'0'};capture('known global mod=0 with every source disabled')
for _,kind in ipairs({'mod','lfo','acs','plink'})do replies[kind]={false,''}end
capture('all four absent, including existing ordinary FX envelope')
print('PASS measured ordinary global 0/1 + disabled sources and all-absent admission/copy')
-- Whole-FX copy must preserve known global state, including after envelope transfer.
replies={mod={true,'1'},lfo={true,'0'},acs={true,'0'},plink={true,'0'}}
snapshot=capture('post-copy baseline')
local getter=r.TakeFX_GetNamedConfigParm
local bad=f.init({values={},markers={},source={}});item.takes={take,bad}
r.TakeFX_GetNamedConfigParm=function(t,i,k)
 if t==bad and k=='param.0.mod.active' then return true,'0' end
 return getter(t,i,k)
end
local accepted,why=pcall(M.copy_processing,r,item,take,bad,snapshot.processing)
r.TakeFX_GetNamedConfigParm=getter;item.takes={take};item.take=take
assert(not accepted and tostring(why):find('modulation',1,true),'Copied global modulation state changed without refusal: '..tostring(why))
print('PASS copied global modulation state mismatch refused')
local kinds={'mod','lfo','acs','plink'}
local function known(global)
 replies={mod={true,global or '1'},lfo={true,'0'},acs={true,'0'},plink={true,'0'}}
end
local refused=0
local function reject(label)
 local ok,err=pcall(M.capture,r)
 assert(not ok and tostring(err):find('modulation',1,true),label..' accepted: '..tostring(err));refused=refused+1
end
for _,global in ipairs({'0','1'})do for _,kind in ipairs({'lfo','acs','plink'})do
 known(global);replies[kind]={true,'1'};reject(global..' global with enabled '..kind)
end end
for _,kind in ipairs(kinds)do
 for _,value in ipairs({'','2','-1','false','disabled','0.0','00',' 0','0 ',0,false,{}})do
  known();replies[kind]={true,value};reject(kind..' unknown value '..tostring(value))
 end
 for _,reply in ipairs({{false,'0'},{false,'1'},{true},{},{1,'0'},{'true','0'},{false,false}})do
  known();replies[kind]=reply;reject(kind..' malformed return')
 end
end
-- Every nonempty proper subset of known flags must fail closed.
for mask=1,14 do
 known();for i,kind in ipairs(kinds)do if (mask & (1 << (i-1)))==0 then replies[kind]={false,''}end end
 reject('partial named-config state '..mask)
end
known();snapshot=capture('post-copy matrix baseline')
for _,target in ipairs({'source','destination'})do
 for _,kind in ipairs(kinds)do
  local dst=f.init({values={},markers={},source={}});item.takes={take,dst}
  local mutate=r.SetEnvelopeStateChunk;local transferred=false
  r.SetEnvelopeStateChunk=function(e,s)transferred=true;return mutate(e,s)end
  r.TakeFX_GetNamedConfigParm=function(t,i,k)
   if transferred and t==(target=='source' and take or dst) and k=='param.0.'..kind..'.active' then return true,kind=='mod' and '0' or '1' end
   return getter(t,i,k)
  end
  local ok,err=pcall(M.copy_processing,r,item,take,dst,snapshot.processing)
  r.TakeFX_GetNamedConfigParm=getter;r.SetEnvelopeStateChunk=mutate;item.takes={take};item.take=take
  assert(transferred and not ok and tostring(err):find('modulation',1,true),target..' '..kind..' drift accepted: '..tostring(err))
 end
end
-- Consistent ordinary, global-off and all-absent native copies stay admissible.
for _,global in ipairs({'1','0',false})do
 known(global)
 if global==false then for _,kind in ipairs(kinds)do replies[kind]={false,''}end end
 snapshot=capture('copy control '..tostring(global))
 local dst=f.init({values={},markers={},source={}});item.takes={take,dst}
 assert(M.copy_processing(r,item,take,dst,snapshot.processing)==dst)
 item.takes={take};item.take=take
end
print('PASS '..refused..' source-enabled/unknown/malformed/incomplete refusals; post-envelope source/destination drift and consistent-copy controls')
