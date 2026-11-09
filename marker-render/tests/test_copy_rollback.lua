-- Explicit synthetic helper/host seams exercise action rollback, not native DSP.
local here,prefix=arg[1],assert(arg[2]);dofile(here..'/tests/test_processing_copy.lua')
local f=copy_fixture;local M,r,take,item=f.M,f.r,f.take,f.item
local inactive=f.init({values={D_VOL=.4,D_PAN=-.25},markers={},source=f.source})
inactive.builtins.Volume=f.env('VOLENV',{{.4,.123,5,-.2,true}})
inactive.builtins.Pan=f.env('PANENV',{{.7,-.3,0,0,false}})
local add=r.AddTakeToMediaItem;r.AddTakeToMediaItem=function(i)return f.init(add(i))end
local setchunk=r.SetItemStateChunk;local baseline
r.SetItemStateChunk=function(i,s)
 if s==baseline then
  i.take=take;i.takes={take,inactive}
  -- Same serialized chunk, different original API values: measured VOLTYPE 1.
  for _,t in ipairs(i.takes)do for _,p in ipairs(t.builtins.Volume.points)do p[2]=0 end end
  return true
 end
 return setchunk(i,s)
end
local function write(p,s)local out=assert(io.open(p,'wb'));assert(out:write(s));assert(out:close())end
local pcm=string.rep('\0',144000*4)
local wav=string.pack('<c4I4c4c4I4I2I2I4I4I2I2c4I4','RIFF',#pcm+36,'WAVE','fmt ',16,3,1,48000,192000,4,32,'data',#pcm)..pcm
local current,sequence=0,0
r.genGuid=function()sequence=sequence+1;return '{'..prefix..current..'guid'..sequence..'}'end
r.ExecProcess=function(command,timeout)
 local leaf=assert(command:match('"([^"]+)/job.json"$'));local nonce=assert(leaf:match('/([^/]+)$'))
 local output=here..'/tests/Audio/FlexTime-'..nonce..'.wav';write(output,wav)
 local id=M.fingerprint(output)
 write(leaf..'/result.txt',table.concat({'OK','2',nonce,'48000','1','144000',tostring(id.bytes),tostring(id.fnv1a32),string.rep('a',64),output},'\n')..'\n')
 return '0\nEXPLICIT SYNTHETIC HELPER SEAM, NO DSP\n'
end
local destroy_count=0;r.PCM_Source_Destroy=function()destroy_count=destroy_count+1 end
local modes={'success','attach','setter','FX throws','FX missing','envelope throws','restore semantic mismatch','restore false','restore mismatch','restore active mismatch','restore count mismatch'}
for _,mode in ipairs(modes)do
 current=current+1;sequence=0;item.take=take;item.takes={take,inactive};local _,s=r.GetItemStateChunk(item);baseline=s
 local copy=r.TakeFX_CopyToTake;local insert=r.InsertEnvelopePoint;local restore=r.SetItemStateChunk
 f.hooks.attach_refusal=mode=='attach';f.hooks.setter=mode=='setter'
 if mode=='FX throws' or mode:find('restore',1,true) then r.TakeFX_CopyToTake=function()error('injected FX failure')end end
 if mode=='FX missing' then r.TakeFX_CopyToTake=function()end end
 if mode=='envelope throws' then
  local original={};for _,t in ipairs({take,inactive})do for n=0,r.CountTakeEnvelopes(t)-1 do original[r.GetTakeEnvelope(t,n)]=true end end
  r.InsertEnvelopePoint=function(e,...)if not original[e] then error('injected point failure')end;return insert(e,...)end
 end
 if mode=='restore false' then r.SetItemStateChunk=function(i,s)if s==baseline then return false end;return restore(i,s)end end
 if mode=='restore semantic mismatch' then
  -- Even successful API repair calls must be read back; raw chunk stays equal.
  r.InsertEnvelopePoint=function(e,...)local ok=insert(e,...);if e==take.builtins.Volume then e.points[#e.points][2]=.21 end;return ok end
 end
 if mode=='restore mismatch' then
  r.SetItemStateChunk=function(i,s)local ok=restore(i,s);if s==baseline then take.values.D_PLAYRATE=7 end;return ok end
 end
 if mode=='restore active mismatch' then
  r.SetItemStateChunk=function(i,s)local ok=restore(i,s);if s==baseline then i.take=inactive end;return ok end
 end
 if mode=='restore count mismatch' then
  r.SetItemStateChunk=function(i,s)local ok=restore(i,s);if s==baseline then i.takes[3]=f.init({values={},markers={},source=f.source})end;return ok end
 end
 local before=destroy_count;local ok,why=M.run(r,here)
 r.TakeFX_CopyToTake=copy;r.InsertEnvelopePoint=insert;r.SetItemStateChunk=restore;f.hooks.attach_refusal=nil;f.hooks.setter=nil
 if mode=='success' then assert(ok,why);assert(#item.takes==3 and item.take~=take and item.take.values.D_VOL==-.625)
 else
  assert(not ok,'injected failure accepted: '..mode)
  if mode:find('restore',1,true) then assert(tostring(why):find('ROLLBACK FAILED',1,true),tostring(why))
  else
   assert(not tostring(why):find('ROLLBACK FAILED',1,true),'original API points lost after chunk restore: '..tostring(why))
   assert(item.take==take and #item.takes==2,'rollback/original not retained: '..mode)
  end
 end
 if not mode:find('restore',1,true) then
  assert(take.builtins.Volume.points[1][2]==.2 and take.builtins.Volume.points[2][2]==.3,'original points lost')
  assert(inactive.builtins.Volume.points[1][2]==.123 and inactive.builtins.Pan.points[1][2]==-.3,'inactive points lost')
 end
 if mode=='restore semantic mismatch' then assert(inactive.builtins.Volume.points[1][2]==.123,'failed repair of one envelope prevented recovery of unrelated original take')end
 assert(destroy_count-before==(mode=='attach' and 1 or 0),'source ownership/double-destroy: '..mode)
 assert(f.undos()==0,'Undo block not balanced: '..mode)
 print('PASS synthetic helper action mode='..mode)
 -- Reset only explicit destructive refusal controls after assertions.
 take.values.D_PLAYRATE=1
 take.builtins.Volume.points={{0,.2,1,0,false},{1.25,.3,5,.35,true},{2.5,.8,0,0,false}}
 inactive.builtins.Volume.points={{.4,.123,5,-.2,true}}
end
