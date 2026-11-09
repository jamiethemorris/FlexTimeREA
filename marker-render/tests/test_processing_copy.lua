-- Fake native boundary for editable copy, NOT host chunk/API acceptance.
local here=arg[1];arg[2]='fixture-only';dofile(here..'/tests/test_action.lua')
local f=fixture;local M,r,take,item=f.M,f.r,f.take,f.item
local serial=0;local function guid()serial=serial+1;return '{FIXTURE-'..serial..'}'end
r.EnumProjects=function()return f.project,here..'/tests/fixture.wav'end
local function env(tag,values)
 return {guid=guid(),tag=tag,points=values or {{0,.2,1,0,false},{1.25,.3,5,.35,true},{2.5,.8,0,0,false}},ai=0}
end
local function state(e)
 return '<'..e.tag..'\nEGUID '..e.guid..'\nACT 1 -1\nVIS 1 1 1\nARM 0\nDEFSHAPE 0 -1 -1\n'..(e.tag=='VOLENV' and 'VOLTYPE 1\n' or '')..'>\n'
end
local function fx()
 return {guid=guid(),params={.37,.61},enabled=false,offline=false,env=env('PARMENV 0:test 0 1 .5')}
end
local function init(t)t.guid=guid();t.builtins={};t.effects={};return t end
init(take);take.builtins.Volume=env('VOLENV');take.builtins.Pan=env('PANENV');take.effects={fx()}
take.values.D_VOL=-.625;take.values.D_PAN=.375;take.values.D_PANLAW=.5
function r.GetSetMediaItemTakeInfo_String(t,k)return true,k=='GUID' and t.guid or ''end
function r.CountTakes(i)return #i.takes end
function r.GetTake(i,n)return i.takes[n+1]end
function r.TakeFX_GetCount(t)return #t.effects end
function r.TakeFX_GetNamedConfigParm(t,i,k)
 if k=='fx_ident' then return true,'fixture:reaeq' end
 if k=='container_count' then return t.effects[i+1].container or false,'0' end
 if k:find('active',1,true) then return true,t.effects[i+1].mod and '1' or '0' end
 return false,''
end
function r.TakeFX_GetNumParams(t,i)return #t.effects[i+1].params end
function r.TakeFX_GetParamNormalized(t,i,p)return t.effects[i+1].params[p+1]end
function r.TakeFX_GetEnabled(t,i)return t.effects[i+1].enabled end
function r.TakeFX_GetOffline(t,i)return t.effects[i+1].offline end
function r.TakeFX_GetFXGUID(t,i)return t.effects[i+1].guid end
function r.TakeFX_GetEnvelope(t,i,p,create)if p==0 then return t.effects[i+1].env end end
function r.GetTakeEnvelopeByName(t,n)return t.builtins[n] end
local function list(t)local a={};for _,n in ipairs({'Volume','Pan','Pitch','Mute'})do if t.builtins[n] then a[#a+1]=t.builtins[n]end end;for _,x in ipairs(t.effects)do if x.env then a[#a+1]=x.env end end;return a end
function r.CountTakeEnvelopes(t)return #list(t)end
function r.GetTakeEnvelope(t,i)return list(t)[i+1]end
function r.CountAutomationItems(e)return e.ai end
function r.GetEnvelopeStateChunk(e)return true,state(e)end
function r.GetSetEnvelopeInfo_String(e,k)return true,e.guid end
function r.CountEnvelopePoints(e)return #e.points end
function r.GetEnvelopePoint(e,i)return true,table.unpack(e.points[i+1])end
function r.SetEnvelopeStateChunk(e,s)e.guid=assert(s:match('EGUID ({[^}]+})'));return true end
function r.DeleteEnvelopePointRange(e)e.points={};return true end
function r.DeleteEnvelopePointEx(e,ai,i)assert(ai==-1);table.remove(e.points,i+1);return true end
function r.InsertEnvelopePoint(e,...)local p={...};p[6]=nil;e.points[#e.points+1]=p;return true end
function r.Envelope_SortPoints()return true end
function r.TakeFX_CopyToTake(src,i,dst,j,move)
 assert(not move);local original=src.effects[i+1];local x=fx();x.params={table.unpack(original.params)};x.enabled=original.enabled;x.offline=original.offline
 x.env.points={};for _,p in ipairs(original.env.points)do x.env.points[#x.env.points+1]={table.unpack(p)}end
 dst.effects[j+1]=x
end
local chunks=r.GetItemStateChunk
function r.GetItemStateChunk(i)
 local s='<ITEM\n';for _,t in ipairs(i.takes)do s=s..'GUID '..t.guid..'\n<SOURCE WAVE\n>\n'end
 return true,s..'>\n'
end
local item_chunk_writes,toggles=0,0
function r.SetItemStateChunk(i,s)
 item_chunk_writes=item_chunk_writes+1
 -- Measured 7.84 boundary: empty built-in shells disappear, and reloading
 -- VOLTYPE 1 serialized small values destroys original API values.
 for _,t in ipairs(i.takes)do
  local e=t.builtins.Volume;if e then for _,p in ipairs(e.points)do p[2]=0 end end
 end
 local dst=i.takes[#i.takes]
 for tag,g,body in s:gmatch('<([A-Z]+ENV)\nEGUID ({[^}]+})(.-)\n>')do
  if body:find('\nPT ',1,true) then
   dst.builtins[tag=='VOLENV' and 'Volume' or 'Pan']={tag=tag,guid=g,points={{0,1,0,0,false}},ai=0}
  end
 end
 return true
end
function r.GetItemProjectContext(i)assert(i==item);return f.project end
function r.Main_OnCommandEx(command,flag,project)
 assert(project==f.project and flag==0 and r.CountSelectedMediaItems(project)==1 and r.GetSelectedMediaItem(project,0)==item,'unscoped envelope toggle')
 local dst=r.GetActiveTake(item);assert(dst~=take,'toggle touched original')
 local name=assert(({[40693]='Volume',[40694]='Pan'})[command],'unexpected native action')
 assert(not dst.builtins[name],'toggle would hide existing envelope')
 dst.builtins[name]=env(name=='Volume' and 'VOLENV' or 'PANENV',{{0,name=='Volume' and 1 or 0,0,0,false}})
 toggles=toggles+1
end
r.genGuid=guid
local snapshot=M.capture(r)
assert(snapshot.processing.scalars.D_VOL==-.625,'signed gain snapshot')
local dest=init({values={},markers={},source={}});item.takes[2]=dest
local copied=M.copy_processing(r,item,take,dest,snapshot.processing)
assert(copied==dest and #dest.effects==1 and dest.effects[1].guid~=take.effects[1].guid)
local function same(a,b)assert(#a==#b);for i,p in ipairs(a)do for k,v in ipairs(p)do assert(v==b[i][k],'point differs')end end;return true end
for _,n in ipairs({'Volume','Pan'})do local a,b=take.builtins[n],dest.builtins[n];assert(a.guid~=b.guid and same(a.points,b.points),'built-in item-time copy')end
assert(same(take.effects[1].env.points,dest.effects[1].env.points) and take.effects[1].env.guid~=dest.effects[1].env.guid,'FX point/GUID copy')
assert(not dest.effects[1].offline and not dest.effects[1].enabled)
assert(take.values.D_VOL==-.625 and take.values.D_PAN==.375)
local function refuses(edit,undo,needle)
 edit();local ok,why=pcall(M.capture,r);undo();assert(not ok and tostring(why):find(needle,1,true),tostring(why))
end
assert(item_chunk_writes==0 and toggles==2,'success must not roundtrip original take chunks')
item.takes={take};item.take=take
refuses(function()take.effects[1].container=true end,function()take.effects[1].container=false end,'containers')
refuses(function()take.effects[1].mod=true end,function()take.effects[1].mod=false end,'modulation')
refuses(function()take.builtins.Volume.ai=1 end,function()take.builtins.Volume.ai=0 end,'automation items')
for _,n in ipairs({'Pitch','Mute'})do refuses(function()take.builtins[n]=env(n=='Pitch' and 'PITCHENV' or 'MUTEENV')end,function()take.builtins[n]=nil end,'Unsupported take envelope')end
local count=r.CountTakeEnvelopes
refuses(function()r.CountTakeEnvelopes=function(t)return count(t)-1 end end,function()r.CountTakeEnvelopes=count end,'enumeration')
local saved_chunk=r.GetEnvelopeStateChunk
r.GetEnvelopeStateChunk=function(e)local ok,s=saved_chunk(e);if e.tag=='VOLENV' and e~=take.builtins.Volume then s=s:gsub('ARM 0','ARM 1')end;return ok,s end
local bad=init({values={},markers={},source={}});item.takes={take,bad}
local accepted,detail=pcall(M.copy_processing,r,item,take,bad,snapshot.processing)
r.GetEnvelopeStateChunk=saved_chunk;item.takes={take};item.take=take
assert(not accepted and tostring(detail):find('metadata',1,true),'Ignored envelope metadata was accepted: '..tostring(detail))
print('PASS editable signed gain/pan snapshot, whole FX + ordinary Volume/Pan/FX points, unique GUIDs, container/modulation/AI/pitch/mute/enumeration/metadata refusals')
_G.copy_fixture=f;f.init=init;f.env=env;f.fx=fx
