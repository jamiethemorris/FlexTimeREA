-- Portable fake-REAPER boundary test. This is NOT live-host/API tokenizer proof.
local here=arg[1]
local phase=arg[2]
local file=io.open(here..'/marker_render.lua','r')
assert(file,'missing stretch-marker action module');file:close()
local M=dofile(here..'/marker_render.lua')
local function read(p)local f=assert(io.open(p,'rb'));local s=f:read('*a');f:close();return s end
local source={path=here..'/tests/fixture.wav',rate=48000,ch=1,length=4,type='WAVE'}
local take={guid='{FIXTURE-SOURCE}',source=source,markers={{0,.5,0},{1.5,1.5,0},{3,3.5,0}},values={D_PLAYRATE=1,D_PITCH=0,B_PPITCH=1,I_CHANMODE=0,D_VOL=1,D_PAN=0,D_STARTOFFS=.5},fx=0,envelopes=0}
local item={take=take,takes={take},chunk='original markers and take state',values={D_POSITION=12,D_LENGTH=3,B_LOOPSRC=0,B_ALLTAKESPLAY=0,C_LOCK=0}}
local project={};local change=0;local imports=0;local undos=0;local failures={};local hooks={}
local r={}
function r.APIExists()return true end
function r.EnumProjects()return project,here..'/tests/fixture.wav' end
function r.GetPlayStateEx()return 0 end
function r.CountSelectedMediaItems()return 1 end
function r.GetSelectedMediaItem()return item end
function r.GetActiveTake(i)return i.take end
function r.GetMediaItemTake_Source(t)return t.source end
function r.GetMediaSourceParent()return nil end
function r.GetMediaSourceType(s)return s.type end
function r.GetMediaSourceFileName(s)return s.path end
function r.GetMediaSourceSampleRate(s)return s.rate end
function r.GetMediaSourceNumChannels(s)return s.ch end
function r.GetMediaSourceLength(s)return s.length,false end
function r.TakeIsMIDI()return false end
function r.GetMediaItemInfo_Value(i,k)return i.values[k] or 0 end
function r.GetMediaItemTakeInfo_Value(t,k)return t.values[k] or 0 end
function r.TakeFX_GetCount(t)return t.fx end
function r.CountTakeEnvelopes(t)return t.envelopes end
function r.GetTakeEnvelopeByName()return nil end
function r.GetTakeEnvelope()return nil end
function r.TakeFX_GetNamedConfigParm(_,_,key)return key=='container_count','0'end
function r.GetTakeNumStretchMarkers(t)return #t.markers end
function r.GetTakeStretchMarker(t,i)local m=t.markers[i+1];return i,m[1],m[2] end
function r.GetTakeStretchMarkerSlope(t,i)return t.markers[i+1][3] end
function r.GetItemStateChunk(i)return true,i.chunk end
function r.SetItemStateChunk(i,s)i.chunk=s;i.take=take;i.takes={take};return true end
function r.GetProjectStateChangeCount()return change end
function r.ValidatePtr2()return true end
function r.genGuid()return '{'..phase..'}' end
function r.RecursiveCreateDirectory(p)return os.execute('/bin/mkdir -p "'..p..'"') and 1 or 0 end
function r.ExecProcess(command)
 if hooks.exec then return hooks.exec(command) end
 local pipe=assert(io.popen(command..' 2>&1'));local text=pipe:read('*a');local ok=pipe:close();return (ok and '0' or '1')..'\n'..text
end
function r.PCM_Source_CreateFromFile(p)
 if hooks.create then return nil end
 local raw=read(p);local ch=string.unpack('<I2',raw,23);local rate=string.unpack('<I4',raw,25);local frames=(#raw-44)/(ch*4)
 return {path=p,rate=rate,ch=ch,length=frames/rate,type='WAVE'}
end
function r.PCM_Source_Destroy()end
function r.Undo_BeginBlock2()undos=undos+1 end
function r.Undo_EndBlock2()undos=undos-1 end
function r.AddTakeToMediaItem(i)local t={values={},markers={},source=nil,fx=0,envelopes=0};i.takes[#i.takes+1]=t;imports=imports+1;return t end
function r.SetMediaItemTake_Source(t,s)if hooks.attach_refusal then return false end;t.source=s;return true end
function r.SetMediaItemTakeInfo_Value(t,k,v)if hooks.setter then error('injected setter failure')end;if hooks.ignore_pitch and k=='D_PITCH' then t.values[k]=.5;return true end;t.values[k]=v;return true end
function r.GetSetMediaItemTakeInfo_String(t,k)return true,k=='GUID' and t.guid or ''end
function r.CountTakes(i)return #i.takes end
function r.GetTake(i,n)return i.takes[n+1]end
function r.SetActiveTake(t)item.take=t end
function r.UpdateItemInProject()end
function r.UpdateArrange()end
function r.ShowMessageBox(s)failures[#failures+1]=s;return 1 end
function r.defer()end
function r.GetAppVersion()return '7.84' end
_G.fixture={M=M,r=r,item=item,take=take,source=source,hooks=hooks,project=project,read=read,imports=function()return imports end,undos=function()return undos end,change=function()change=change+1 end}
if phase=='fixture-only' then return end
if phase=='capture-only' then
 -- Exercise capture admission only: no helper, DSP, project writes or new files.
 local original_markers=take.markers
 for _,rate in ipairs({44100,48000})do
  source.rate=rate;source.length=20
  local function saved(n)return tonumber(string.format('%.9f',n/rate))end
  take.values.D_STARTOFFS=12345/rate;item.values.D_LENGTH=572109/rate
  take.markers={{0,12345/rate,0},{100003/rate,111113/rate,0},{572109/rate,600001/rate,0}}
  local exact=M.capture(r).job
  item.values.D_LENGTH=saved(572109);take.markers[3][1]=saved(572109)
  if rate==44100 then assert(item.values.D_LENGTH==12.972993197,'saved endpoint reproduction changed')end
  local endpoint_ok,endpoint=pcall(M.capture,r)
  assert(endpoint_ok,rate..' Hz saved endpoint rejected: '..tostring(endpoint))
  assert(endpoint.job.output_frames==572109 and M.json(endpoint.job.points)==M.json(exact.points))
  take.values.D_STARTOFFS=saved(12345)
  take.markers={{0,saved(12345),0},{saved(100003),saved(111113),0},{saved(572109),saved(600001),0}}
  local ok,capture=pcall(M.capture,r)
  assert(ok,rate..' Hz saved decimal capture rejected: '..tostring(capture))
  local job=capture.job
  assert(job.crop_start==12345 and job.crop_end==600001 and job.output_frames==572109)
  assert(M.json(job.points)==M.json(exact.points),'saved rounding changed integer marker map')
  assert(M.json(job.points)=='[[0,0],[98768,100003],[587656,572109]]','wrong intended integer map')
  for _,offgrid in ipairs({(100003+.001)/rate,1.000001})do
   take.markers[2][1]=offgrid
   local capture=M.capture(r)
   assert(capture.job.points[2][2]==math.floor(offgrid*rate+.5),'wrong nearest destination frame')
   take.markers[2][1]=saved(100003);take.markers[2][2]=offgrid
   capture=M.capture(r)
   assert(capture.job.points[2][1]==math.floor(offgrid*rate+.5)-12345,'wrong nearest source frame')
   take.markers[2][2]=saved(111113)
  end
 end
 source.rate=48000;source.length=4;take.values.D_STARTOFFS=.5;item.values.D_LENGTH=3;take.markers=original_markers
 assert(imports==0 and undos==0 and item.take==take and item.chunk=='original markers and take state')
 print('PASS capture-only saved 9-decimal endpoints/markers at 44100/48000 Hz; exact maps and nearest-sample fractional positions')
 return
end
-- RED/GREEN tracer bullet: actual source crop/map sent to real supervisor/native helper.
local old=read(source.path)
local ok,why=M.run(r,here)
assert(ok,why or failures[#failures]);assert(imports==1 and #item.takes==2 and item.take~=take)
local nonce=assert(why:match('/FlexTime%-(job%-%w+)%.wav$'));local job=read(here..'/runs/'..nonce..'/job.json')
assert(job:find('"points":[[0,0],[48000,72000],[144000,144000]]',1,true) and job:find('"crop_start":24000',1,true) and job:find('"crop_end":168000',1,true),'frontend did not send original-source piecewise map')
assert(take.values.D_PLAYRATE==1 and take.values.D_STARTOFFS==.5 and #take.markers==3)
assert(item.take.values.D_PLAYRATE==1 and item.take.values.D_STARTOFFS==0 and #item.take.markers==0,'double timing applied')
assert(item.values.D_POSITION==12 and item.values.D_LENGTH==3 and item.chunk=='original markers and take state')
assert(read(source.path)==old and undos==0)
print('PASS portable Lua -> real helper/native -> aligned new take; original retained')
