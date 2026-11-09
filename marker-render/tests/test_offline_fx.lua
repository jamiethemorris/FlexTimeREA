-- Explicit unsupported-state refusal; synthetic native boundary, no DSP/DAW.
local root=assert(arg[1]);dofile(root..'/tests/test_processing_copy.lua')
local f=copy_fixture;local r,M,take,item=f.r,f.M,f.take,f.item
local named=r.TakeFX_GetNamedConfigParm
local helper,mutations,offline_identity_reads=0,0,0
r.ExecProcess=function()helper=helper+1;error('Unexpected helper')end
for _,key in ipairs({'SetItemStateChunk','AddTakeToMediaItem','TakeFX_CopyToTake','TakeFX_SetOffline','Undo_BeginBlock2'})do
 r[key]=function()mutations=mutations+1;error('Unexpected mutation '..key)end
end
r.TakeFX_GetNamedConfigParm=function(t,i,k)
 if t.effects[i+1].offline then
  offline_identity_reads=offline_identity_reads+1
  return false,'' -- settled native offline state cannot expose canonical identity
 end
 return named(t,i,k)
end
local function refuse(label)
 local accepted,detail=M.run(r,root)
 assert(not accepted and tostring(detail):find('Offline take FX unsupported',1,true),label..': '..tostring(detail))
 assert(helper==0 and mutations==0 and offline_identity_reads==0,'Must refuse before introspection/helper/mutation')
 print('PASS '..label..' explicit offline refusal before FX introspection/helper/mutation')
end
take.effects[1].offline=true
refuse('active take')
assert(take.effects[1].offline,'Offline FX was toggled')
take.effects[1].offline=false
local inactive=f.init({values={D_VOL=.4,D_PAN=-.25,D_PANLAW=.5},markers={},source=f.source})
inactive.effects={f.fx()};inactive.effects[1].offline=true
item.takes={take,inactive};item.take=take
refuse('inactive original take')
assert(inactive.effects[1].offline and item.take==take and #item.takes==2,'Original state changed')
print('PASS offline-FX support explicitly deferred; original FX never loaded/toggled')
