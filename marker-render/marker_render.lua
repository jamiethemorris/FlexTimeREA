-- Local offline candidate. Source-only render; no native code enters REAPER.
local M={}
local function require_(v,message)if not v then error(message,0)end return v end
local function finite(x)return type(x)=='number' and x==x and math.abs(x)<math.huge end
-- Quantize the private job only; the original item chunk/markers stay untouched.
local function frame(x,rate)
 require_(finite(x),'Invalid time')
 return math.floor(x*rate+.5)
end
local function fingerprint(path)
 local f=require_(io.open(path,'rb'),'Cannot read source/result file')
 local n=f:seek('end');if not n or n<44 or n>0xffffffff+8 then f:close();error('WAV exceeds RIFF32 representation',0)end
 f:seek('set',0);local h,read=2166136261,0
 while read<n do
  local s=f:read(math.min(256*1024,n-read))
  if not s or #s==0 then f:close();error('File changed while reading',0)end
  read=read+#s;for i=1,#s do h=((h~s:byte(i))*16777619)&0xffffffff end
 end
 local extra=f:read(1);local size=f:seek('end');f:close()
 require_(not extra and size==n,'File changed while reading')
 return {bytes=n,fnv1a32=h}
end
local function project_path(r,project)
 local p,path=r.EnumProjects(-1,'')
 require_(p==project and type(path)=='string' and path:sub(1,1)=='/' and not path:find('[%z\r\n]') and not path:find('//',1,true) and not path:find('/%.%.?/') and not path:match('/%.%.?$'),'A saved named project with a normalized absolute path is required')
 local f=require_(io.open(path,'rb'),'A saved project file must exist');f:close()
 return path
end
local function quote(s)
 return '"'..s:gsub('[%z\1-\31\\"]',function(c)
  local known={['"']='\\"',['\\']='\\\\',['\n']='\\n',['\r']='\\r',['\t']='\\t'}
  return known[c] or string.format('\\u%04x',c:byte()) end)..'"'
end
local function json(v)
 if type(v)=='string' then return quote(v)end
 if type(v)=='number' then require_(finite(v),'Nonfinite job number');return string.format('%.17g',v)end
 require_(type(v)=='table','Unsupported JSON value')
 local parts={}
 if #v>0 then for i=1,#v do parts[#parts+1]=json(v[i])end;return '['..table.concat(parts,',')..']' end
 for k,x in pairs(v)do parts[#parts+1]=quote(k)..':'..json(x)end;table.sort(parts);return '{'..table.concat(parts,',')..'}'
end
local function take_guid(r,take)
 local ok,g=r.GetSetMediaItemTakeInfo_String(take,'GUID','',false)
 require_(ok and g:match('^{[^}\r\n]+}$'),'Cannot identify take GUID');return g
end
local function envelope_guid(r,e)
 local ok,g=r.GetSetEnvelopeInfo_String(e,'GUID','',false)
 require_(ok and g:match('^{[^}\r\n]+}$'),'Cannot identify envelope GUID');return g
end
local function envelope_snapshot(r,e)
 require_(r.CountAutomationItems(e)==0,'Take automation items unsupported; nothing rendered')
 local ok,state=r.GetEnvelopeStateChunk(e,'',false);require_(ok,'Cannot read take envelope')
 require_(not state:find('\n%s*<'),'Nested/pooled take automation unsupported')
 local points={}
 for i=0,r.CountEnvelopePoints(e)-1 do
  local good,t,v,shape,tension,selected=r.GetEnvelopePoint(e,i)
  require_(good and finite(t) and finite(v) and finite(tension),'Invalid take envelope point')
  points[#points+1]={t,v,shape,tension,selected}
 end
 return {state=state,guid=envelope_guid(r,e),points=points}
end
local function modulation_state(r,take,fx,param)
 local values={};local known=0
 for _,kind in ipairs({'mod','lfo','acs','plink'})do
  local exists,active=r.TakeFX_GetNamedConfigParm(take,fx,'param.'..param..'.'..kind..'.active')
  require_((exists==false and active=='') or (exists==true and (active=='0' or (kind=='mod' and active=='1'))),'Take parameter modulation/links unsupported or unknown')
  if exists then known=known+1;values[kind]=active end
 end
 -- Native ordinary envelopes can report global mod=1 without any input source.
 -- Admit only complete known disabled sources or the measured all-absent state.
 require_(known==0 or known==4,'Incomplete take parameter modulation/links state')
 return values.mod or false
end
local function processing_snapshot(r,take)
 local result={scalars={},fx={},envelopes={}};local mapped={}
 for _,k in ipairs({'D_VOL','D_PAN','D_PANLAW'})do
  local v=r.GetMediaItemTakeInfo_Value(take,k);require_(finite(v),'Invalid take gain/pan');result.scalars[k]=v
 end
 require_(math.abs(result.scalars.D_PAN)<=1,'Invalid take pan')
 for _,spec in ipairs({{'Volume','VOLENV'},{'Pan','PANENV'}})do
  local e=r.GetTakeEnvelopeByName(take,spec[1])
  if e then mapped[e]={name=spec[1],tag=spec[2]}end
 end
 for i=0,r.TakeFX_GetCount(take)-1 do
  -- Settled offline FX can hide canonical identity/parameters in the native API.
  -- Never load/toggle original effects merely to inspect or copy them.
  require_(r.TakeFX_GetOffline(take,i)==false,'Offline take FX unsupported; nothing rendered (FX must already be online)')
  local container=r.TakeFX_GetNamedConfigParm(take,i,'container_count')
  require_(not container,'Take FX containers unsupported')
  local ok,ident=r.TakeFX_GetNamedConfigParm(take,i,'fx_ident');require_(ok and ident~='','Cannot identify take FX')
  local effect={ident=ident,guid=r.TakeFX_GetFXGUID(take,i),enabled=r.TakeFX_GetEnabled(take,i),offline=r.TakeFX_GetOffline(take,i),params={},modulation={}}
  for p=0,r.TakeFX_GetNumParams(take,i)-1 do
   effect.modulation[p+1]=modulation_state(r,take,i,p)
   local v=r.TakeFX_GetParamNormalized(take,i,p);require_(finite(v),'Invalid take FX parameter');effect.params[#effect.params+1]=v
   local e=r.TakeFX_GetEnvelope(take,i,p,false);if e then mapped[e]={fx=i,param=p}end
  end
  result.fx[#result.fx+1]=effect
 end
 if #result.fx>0 then result.fx_channels=r.GetMediaItemTakeInfo_Value(take,'I_TAKEFX_NCH')end
 local enumerated={}
 for i=0,r.CountTakeEnvelopes(take)-1 do
  local e=r.GetTakeEnvelope(take,i);local spec=mapped[e]
  require_(spec,'Unsupported take envelope (only Volume, Pan and ordinary FX parameter points copy)')
  require_(not enumerated[e],'Duplicate take envelope enumeration');enumerated[e]=true
  local s=envelope_snapshot(r,e);s.name=spec.name;s.tag=spec.tag;s.fx=spec.fx;s.param=spec.param
  result.envelopes[#result.envelopes+1]=s
 end
 for e in pairs(mapped)do require_(enumerated[e],'Incomplete take envelope enumeration; no automation may be silently skipped')end
 result.take_guid=take_guid(r,take)
 return result
end
local function find_take(r,item,guid)
 local found
 for i=0,r.CountTakes(item)-1 do local t=r.GetTake(item,i)
  if take_guid(r,t)==guid then require_(not found,'Duplicate take GUID');found=t end
 end
 return require_(found,'Take disappeared during editable copy')
end
local function verify_points(r,s,dest)
 require_(r.CountEnvelopePoints(dest)==#s.points,'Envelope point count differs')
 for i,p in ipairs(s.points)do
  local ok,t,v,shape,tension,selected=r.GetEnvelopePoint(dest,i-1)
  require_(ok and math.abs(t-p[1])<1e-10 and math.abs(v-p[2])<1e-8 and shape==p[3] and math.abs(tension-p[4])<1e-8 and selected==p[5],'Envelope point differs')
 end
end
local function verify_original(r,src,snapshot)
 for key,value in pairs(snapshot.scalars)do require_(r.GetMediaItemTakeInfo_Value(src,key)==value,'Original take scalar changed during copy/rollback')end
 require_(r.TakeFX_GetCount(src)==#snapshot.fx and r.CountTakeEnvelopes(src)==#snapshot.envelopes,'Original take processing count changed')
 for i,effect in ipairs(snapshot.fx)do
  require_(r.TakeFX_GetFXGUID(src,i-1)==effect.guid and r.TakeFX_GetEnabled(src,i-1)==effect.enabled and r.TakeFX_GetOffline(src,i-1)==effect.offline and r.TakeFX_GetNumParams(src,i-1)==#effect.params,'Original take FX changed')
  for p,v in ipairs(effect.params)do
   require_(r.TakeFX_GetParamNormalized(src,i-1,p-1)==v,'Original take FX parameter changed')
   require_(modulation_state(r,src,i-1,p-1)==effect.modulation[p],'Original take FX modulation state changed')
  end
 end
 for _,e in ipairs(snapshot.envelopes)do
  local original
  if e.name then original=r.GetTakeEnvelopeByName(src,e.name)else original=r.TakeFX_GetEnvelope(src,e.fx,e.param,false)end
  require_(original and envelope_guid(r,original)==e.guid,'Original envelope identity changed')
  local ok,state=r.GetEnvelopeStateChunk(original,'',false);require_(ok and state==e.state,'Original envelope state changed during copy/rollback')
  verify_points(r,e,original)
 end
 if snapshot.fx_channels then require_(r.GetMediaItemTakeInfo_Value(src,'I_TAKEFX_NCH')==snapshot.fx_channels,'Original take FX channel count changed')end
end
local function rebuild_points(r,s,dest)
 for i=r.CountEnvelopePoints(dest)-1,0,-1 do require_(r.DeleteEnvelopePointEx(dest,-1,i),'Cannot clear envelope point')end
 for _,p in ipairs(s.points)do require_(r.InsertEnvelopePoint(dest,p[1],p[2],p[3],p[4],p[5],true),'Cannot restore/copy envelope point')end
 require_(r.Envelope_SortPoints(dest),'Cannot sort envelope points')
 verify_points(r,s,dest)
end
local take_fields={'D_STARTOFFS','D_PLAYRATE','D_PITCH','B_PPITCH','I_CHANMODE','I_PITCHMODE','I_STRETCHFLAGS'}
local function originals_snapshot(r,item,active,processing)
 local result={}
 for i=0,r.CountTakes(item)-1 do
  local take=r.GetTake(item,i)
  -- Every preexisting take can be affected by rollback deserialization. Apply
  -- the same ordinary-envelope safety admission before doing any DSP/mutation.
  local p=take==active and processing or processing_snapshot(r,take)
  local s={processing=p,scalars={},markers={},source=r.GetMediaSourceFileName(r.GetMediaItemTake_Source(take),''),name=select(2,r.GetSetMediaItemTakeInfo_String(take,'P_NAME','',false))}
  for _,k in ipairs(take_fields)do s.scalars[k]=r.GetMediaItemTakeInfo_Value(take,k)end
  for n=0,r.GetTakeNumStretchMarkers(take)-1 do
   local id,pos,src=r.GetTakeStretchMarker(take,n);require_(id==n,'Cannot snapshot original stretch marker')
   s.markers[#s.markers+1]={pos,src,r.GetTakeStretchMarkerSlope(take,n)}
  end
  result[#result+1]=s
 end
 return result
end
local function verify_originals(r,item,originals)
 for i,s in ipairs(originals)do
  local take=r.GetTake(item,i-1);require_(take and take_guid(r,take)==s.processing.take_guid,'Original take order/identity changed')
  verify_original(r,take,s.processing)
  for k,v in pairs(s.scalars)do require_(r.GetMediaItemTakeInfo_Value(take,k)==v,'Original take timing/configuration changed: '..k)end
  require_(r.GetMediaSourceFileName(r.GetMediaItemTake_Source(take),'')==s.source and select(2,r.GetSetMediaItemTakeInfo_String(take,'P_NAME','',false))==s.name,'Original source/name changed')
  require_(r.GetTakeNumStretchMarkers(take)==#s.markers,'Original marker count changed')
  for n,m in ipairs(s.markers)do
   local id,pos,src=r.GetTakeStretchMarker(take,n-1)
   require_(id==n-1 and pos==m[1] and src==m[2] and r.GetTakeStretchMarkerSlope(take,n-1)==m[3],'Original marker changed')
  end
 end
end
local function restore_originals(r,s)
 require_(r.SetItemStateChunk(s.item,s.chunk,false),'Restore API refused')
 require_(r.CountTakes(s.item)==#s.originals and take_guid(r,require_(r.GetActiveTake(s.item),'Restored active take missing'))==s.processing.take_guid,'Restore take count/active identity mismatch')
 -- Restore only captured ordinary point payloads, never repair unrelated state.
 -- Raw item equality is neither necessary (native VST program serialization)
 -- nor sufficient (VOLTYPE 1 values) to establish semantic restoration.
 local failures={}
 for _,original in ipairs(s.originals)do
  local found,take=pcall(find_take,r,s.item,original.processing.take_guid)
  if not found then failures[#failures+1]=tostring(take)else
   for _,e in ipairs(original.processing.envelopes)do
    local restored,why=pcall(function()
     local target
     if e.name then target=r.GetTakeEnvelopeByName(take,e.name)else target=r.TakeFX_GetEnvelope(take,e.fx,e.param,false)end
     require_(target and envelope_guid(r,target)==e.guid,'Restore envelope identity mismatch')
     rebuild_points(r,e,target)
    end)
    if not restored then failures[#failures+1]=tostring(why)end
   end
  end
 end
 require_(#failures==0,table.concat(failures,'; '))
 verify_originals(r,s.item,s.originals)
 require_(r.GetMediaItemInfo_Value(s.item,'D_POSITION')==s.position and r.GetMediaItemInfo_Value(s.item,'D_LENGTH')==s.length,'Restore item alignment mismatch')
end
local function copy_envelope(r,s,dest)
 local dg=envelope_guid(r,dest);require_(dg~=s.guid,'Envelope GUID collision')
 local state,n=s.state:gsub('(\n%s*EGUID%s+){[^}\r\n]+}',function(head)return head..dg end)
 require_(n==1,'Expected one ordinary envelope EGUID')
 require_(r.SetEnvelopeStateChunk(dest,state,false),'Cannot copy envelope state')
 require_(envelope_guid(r,dest)==dg and r.CountAutomationItems(dest)==0,'Copied envelope identity/topology differs')
 -- Native cursor probes establish API times as item-relative, unscaled at .5/2.
 -- Rebuild API values too: raw VOLTYPE PT serialization can quantize values.
 rebuild_points(r,s,dest)
 local ok,copied=r.GetEnvelopeStateChunk(dest,'',false)
 local function metadata(state)
  -- Known ordinary envelope only: identity and API-rebuilt PT rows differ.
  return (state:gsub('\n[ \t]*EGUID[ \t]+{[^}\r\n]+}',''):gsub('\n[ \t]*PT[ \t]+[^\r\n]*',''))
 end
 require_(ok and metadata(copied)==metadata(s.state),'Copied envelope metadata differs')
end
function M.copy_processing(r,item,src,dest,snapshot)
 -- Empty serialized shells are dropped by REAPER. Rewriting the whole item
 -- also quantizes ORIGINAL fader-scaled envelopes, including inactive takes.
 -- Native toggles create only the new active take's envelopes. Never change
 -- selection to make an action fit: require the already admitted sole item.
 for _,e in ipairs(snapshot.envelopes)do if e.name then
  local project=r.GetItemProjectContext(item)
  local function scoped()
   require_(project and r.EnumProjects(-1,'')==project and r.CountSelectedMediaItems(project)==1 and r.GetSelectedMediaItem(project,0)==item,'Envelope creation requires the sole selected item in its current project')
  end
  scoped()
  require_(src~=dest and find_take(r,item,take_guid(r,dest))==dest,'Invalid destination take')
  require_(not r.GetTakeEnvelopeByName(dest,e.name),'New take unexpectedly has built-in envelope')
  r.SetActiveTake(dest);scoped()
  require_(r.GetActiveTake(item)==dest,'Cannot activate destination for envelope creation')
  r.Main_OnCommandEx(require_(({Volume=40693,Pan=40694})[e.name],'Unsupported built-in envelope'),0,project)
  scoped();require_(r.GetActiveTake(item)==dest and r.GetTakeEnvelopeByName(dest,e.name),'Native built-in envelope creation failed')
 end end
 for key,value in pairs(snapshot.scalars)do
  require_(r.SetMediaItemTakeInfo_Value(dest,key,value) and r.GetMediaItemTakeInfo_Value(dest,key)==value,'Copied take scalar differs: '..key)
 end
 if snapshot.fx_channels then
  require_(r.SetMediaItemTakeInfo_Value(dest,'I_TAKEFX_NCH',snapshot.fx_channels),'Cannot copy take FX channel count')
 end
 require_(r.TakeFX_GetCount(dest)==0,'New take unexpectedly has FX')
 for i,effect in ipairs(snapshot.fx)do
  r.TakeFX_CopyToTake(src,i-1,dest,i-1,false)
  require_(r.TakeFX_GetCount(dest)==i and r.TakeFX_GetFXGUID(dest,i-1)~=effect.guid,'Take FX copy failed or duplicated GUID')
  local ok,ident=r.TakeFX_GetNamedConfigParm(dest,i-1,'fx_ident')
  require_(ok and ident==effect.ident and r.TakeFX_GetEnabled(dest,i-1)==effect.enabled and r.TakeFX_GetOffline(dest,i-1)==effect.offline and r.TakeFX_GetNumParams(dest,i-1)==#effect.params,'Copied take FX state differs')
  for p,v in ipairs(effect.params)do require_(r.TakeFX_GetParamNormalized(dest,i-1,p-1)==v,'Copied take FX parameter differs')end
 end
 for _,e in ipairs(snapshot.envelopes)do
  local target
  if e.name then target=r.GetTakeEnvelopeByName(dest,e.name)else target=r.TakeFX_GetEnvelope(dest,e.fx,e.param,true)end
  copy_envelope(r,e,require_(target,'Copied envelope missing'))
 end
 require_(r.CountTakeEnvelopes(dest)==#snapshot.envelopes,'Unexpected/missing copied take envelopes')
 -- Native whole-FX copy preserves the admitted global flag; envelope transfer
 -- must not enable a source or change known/absent state afterward.
 for i,effect in ipairs(snapshot.fx)do for p in ipairs(effect.params)do
  require_(modulation_state(r,dest,i-1,p-1)==effect.modulation[p],'Copied take FX modulation state differs')
 end end
 -- Verify the original independently even though native creation is scoped.
 verify_original(r,src,snapshot)
 local seen={}
 for _,effect in ipairs(snapshot.fx)do seen[effect.guid]=true end
 for _,e in ipairs(snapshot.envelopes)do seen[e.guid]=true end
 for i in ipairs(snapshot.fx)do
  local dg=r.TakeFX_GetFXGUID(dest,i-1);require_(dg~='' and not seen[dg],'Copied FX GUID collision');seen[dg]=true
 end
 for _,e in ipairs(snapshot.envelopes)do
  local target
  if e.name then target=r.GetTakeEnvelopeByName(dest,e.name)else target=r.TakeFX_GetEnvelope(dest,e.fx,e.param,false)end
  local dg=envelope_guid(r,require_(target,'Copied envelope missing'));require_(not seen[dg],'Copied envelope GUID collision');seen[dg]=true
 end
 if snapshot.fx_channels then require_(r.GetMediaItemTakeInfo_Value(dest,'I_TAKEFX_NCH')==snapshot.fx_channels,'Copied take FX channel count changed')end
 return dest,src
end
function M.capture(r)
 local apis={'EnumProjects','GetPlayStateEx','GetTakeStretchMarker','GetTakeStretchMarkerSlope','GetMediaSourceParent','CountTakeEnvelopes','ExecProcess','GetItemStateChunk','PCM_Source_CreateFromFile','GetMediaSourceSampleRate','GetMediaSourceNumChannels','ValidatePtr2','GetTakeEnvelopeByName','GetTakeEnvelope','CountAutomationItems','GetEnvelopeStateChunk','SetEnvelopeStateChunk','GetEnvelopePoint','CountEnvelopePoints','GetSetEnvelopeInfo_String','DeleteEnvelopePointEx','InsertEnvelopePoint','Envelope_SortPoints','TakeFX_CopyToTake','TakeFX_GetEnvelope','TakeFX_GetNamedConfigParm','TakeFX_GetNumParams','TakeFX_GetParamNormalized','TakeFX_GetEnabled','TakeFX_GetOffline','TakeFX_GetFXGUID','GetSetMediaItemTakeInfo_String','CountTakes','GetTake'}
 for _,api in ipairs({'GetItemProjectContext','Main_OnCommandEx','SetActiveTake'})do apis[#apis+1]=api end
 for _,api in ipairs(apis)do require_(r.APIExists(api),'Required REAPER API unavailable: '..api)end
 local project=r.EnumProjects(-1,'');require_(project,'No current project')
 local saved_path=project_path(r,project);local output_dir=assert(saved_path:match('^(.*)/[^/]+$'))..'/Audio'
 require_(r.GetPlayStateEx(project)==0,'Stop transport before rendering')
 require_(r.CountSelectedMediaItems(project)==1,'Select exactly one audio item')
 local item=r.GetSelectedMediaItem(project,0);local take=r.GetActiveTake(item)
 require_(take and not r.TakeIsMIDI(take),'Selected item needs an active audio take')
 local tv=function(k)return r.GetMediaItemTakeInfo_Value(take,k)end
 local iv=function(k)return r.GetMediaItemInfo_Value(item,k)end
 local playrate=tv('D_PLAYRATE');require_(finite(playrate) and playrate>0,'Invalid base take playrate')
 require_(tv('D_PITCH')==0 and tv('B_PPITCH')==1,'Zero pitch and preserve-pitch must be enabled')
 require_(tv('I_CHANMODE')==0 and tv('I_STRETCHFLAGS')==0,'Channel/stretch mode overrides unsupported')

 require_(tv('IP_SPECEDIT:CNT')==0,'Spectral edits unsupported')
 local processing=processing_snapshot(r,take)
 require_(iv('B_ALLTAKESPLAY')==0 and iv('C_LOCK')==0,'all-takes-play or locked items unsupported')
 -- B_LOOPSRC is left untouched: the complete mapped interval must still fit
 -- the bare WAV below; no wrap, source SECTION or reverse is admitted.
 local source=r.GetMediaItemTake_Source(take)
 require_(source and not r.GetMediaSourceParent(source) and r.GetMediaSourceType(source,'')=='WAVE','Bare WAV source required (no reverse/section/subproject)')
 local path=r.GetMediaSourceFileName(source,'');require_(type(path)=='string' and path:sub(1,1)=='/','Absolute source file required')
 local rate=r.GetMediaSourceSampleRate(source);local channels=r.GetMediaSourceNumChannels(source)
 local slen,isqn=r.GetMediaSourceLength(source)
 require_((rate==44100 or rate==48000) and (channels==1 or channels==2) and not isqn and finite(slen) and slen>0,'Source must be mono/stereo 44.1/48 kHz')
 local offset,length=tv('D_STARTOFFS'),iv('D_LENGTH');local total=frame(length,rate)
 require_(finite(offset) and offset>=0 and length>0 and total>0 and total*channels*4<=0xffffffff-36,'Item offset/output exceeds representation')
 local count=r.GetTakeNumStretchMarkers(take);require_(count>=0 and count<=1024,'Maximum 1024 user markers')
 local markers={};local previous_pos,previous_src
 for i=0,count-1 do
  local index,pos,src=r.GetTakeStretchMarker(take,i)
  require_(index==i and r.GetTakeStretchMarkerSlope(take,i)==0,'Invalid or non-zero-slope stretch marker')
  require_(finite(pos) and finite(src),'Invalid marker time')
  pos=pos/playrate
  local d=frame(pos,rate);local s=frame(src,rate)
  if i>0 then
   local prev=markers[#markers]
   require_(pos>previous_pos and src>previous_src and d>prev[2] and s>prev[1],'Markers must increase before and after nearest-sample rounding')
  end
  markers[#markers+1]={s,d,src,pos};previous_pos=pos;previous_src=src
 end
 local function at(d)
  if #markers==0 then return offset+d*playrate end
  local first,last=markers[1],markers[#markers]
  -- Native rate probe: raw marker pos/rate is item time; outer source slope=rate.
  if d<=first[4] then return first[3]+(d-first[4])*playrate end
  if d>=last[4] then return last[3]+(d-last[4])*playrate end
  for i=2,#markers do
   local a,b=markers[i-1],markers[i]
   if d<=b[4] then return a[3]+(d-a[4])*(b[3]-a[3])/(b[4]-a[4]) end
  end
 end
 local raw_start,raw_end=at(0),at(length)
 local crop_start,crop_end=frame(raw_start,rate),frame(raw_end,rate)
 require_(raw_start>=0 and raw_end<=slen and crop_start>=0 and crop_end<=frame(slen,rate) and crop_end<=0xffffffff and (crop_end-crop_start)*channels*4<=0xffffffff-36,'Mapped interval outside real WAV source bounds; looping/padding unsupported')
 local points={{0,0}}
 for _,p in ipairs(markers)do if p[2]>0 and p[2]<total then points[#points+1]={p[1]-crop_start,p[2]} end end
 points[#points+1]={crop_end-crop_start,total}
 require_(#points<=1024,'Maximum 1024 job points including inferred endpoints')
 for i=2,#points do
  local a,b=points[i-1],points[i];local ds,dd=b[1]-a[1],b[2]-a[2]
  require_(ds>0 and dd>0 and dd/ds>=.25 and dd/ds<=4,'Markers must increase; every local duration ratio must be 0.25–4')
 end
 local ok,chunk=r.GetItemStateChunk(item,'',false);require_(ok,'Cannot snapshot selected item')
 return {project=project,saved_path=saved_path,item=item,take=take,source=source,chunk=chunk,processing=processing,originals=originals_snapshot(r,item,take,processing),revision=r.GetProjectStateChangeCount(project),position=iv('D_POSITION'),length=length,job={version=2,output_dir=output_dir,source=path,identity=fingerprint(path),rate=rate,channels=channels,crop_start=crop_start,crop_end=crop_end,points=points,output_frames=total}}
end
function M.unchanged(r,s,stage)
 require_(project_path(r,s.project)==s.saved_path,'Saved project path changed; result not imported')
 require_(r.EnumProjects(-1,'')==s.project and r.ValidatePtr2(s.project,s.item,'MediaItem*') and r.ValidatePtr2(s.project,s.take,'MediaItem_Take*'),'Project/item/take changed or closed')
 local revision=r.GetProjectStateChangeCount(s.project)
 local selected_count=r.CountSelectedMediaItems(s.project)
 local selected_item_same=r.GetSelectedMediaItem(s.project,0)==s.item
 local active_take_same=r.GetActiveTake(s.item)==s.take
 local source_same=r.GetMediaItemTake_Source(s.take)==s.source
 local changed={}
 if revision~=s.revision then changed[#changed+1]='revision'end
 if selected_count~=1 then changed[#changed+1]='selection_count'end
 if not selected_item_same then changed[#changed+1]='selected_item'end
 if not active_take_same then changed[#changed+1]='active_take'end
 if not source_same then changed[#changed+1]='source'end
 require_(#changed==0,'Project/selection/source changed; result retained but not imported [stage='..tostring(stage or 'unspecified')..'; changed='..table.concat(changed,',')..'; captured_revision='..tostring(s.revision)..'; current_revision='..tostring(revision)..'; captured_selection_count=1; current_selection_count='..tostring(selected_count)..'; selected_item_same='..tostring(selected_item_same)..'; active_take_same='..tostring(active_take_same)..'; source_same='..tostring(source_same)..']')
 require_(r.GetPlayStateEx(s.project)==0,'Transport changed; result not imported')
 local ok,chunk=r.GetItemStateChunk(s.item,'',false);require_(ok and chunk==s.chunk,'Item/take edited while rendering; result not imported')
 local now=fingerprint(s.job.source);require_(now.bytes==s.job.identity.bytes and now.fnv1a32==s.job.identity.fnv1a32,'Source file edited while rendering; result not imported')
end
local function filewrite(path,text)local f=require_(io.open(path,'wb'),'Cannot create job file');require_(f:write(text),'Cannot write job file');require_(f:close(),'Cannot close job file')end
function M.timeout_ms(job,job_bytes)
 -- Keep these work terms in sync with render.py:budgets; add only host startup slack.
 local frames=job.crop_end-job.crop_start;local crop=frames*job.channels*4
 local out=job.output_frames*job.channels*4
 local native=math.ceil(8+(frames+job.output_frames)*job.channels/50000+#job.points*.002+crop/2000000)
 local wall=math.ceil(10+native+(2*job.identity.bytes+3*(out+44))/2000000+crop/800000+job_bytes/1000000)
 local ms=(wall+15)*1000
 require_(finite(ms) and ms>0 and ms<=0x7fffffff,'Workload exceeds ExecProcess timeout representation')
 return ms
end
function M.receipt(text,job)
 local lines={};for line in text:gmatch('([^\n]+)\n')do lines[#lines+1]=line end
 local function decimal(s)return s and s:match('^%d+$') and tonumber(s)end
 local expected=job.output_dir..'/FlexTime-'..job.nonce..'.wav'
 local bytes,hash=decimal(lines[7]),decimal(lines[8])
 require_(#lines==10 and text==table.concat(lines,'\n')..'\n' and lines[1]=='OK' and lines[2]=='2' and lines[3]==job.nonce and decimal(lines[4])==job.rate and decimal(lines[5])==job.channels and decimal(lines[6])==job.output_frames and bytes and bytes>=44 and bytes<=0xffffffff+8 and hash and hash>=0 and hash<=0xffffffff and lines[9]:match('^[a-f0-9]+$') and #lines[9]==64 and lines[10]==expected,'Invalid helper success receipt')
 return lines[10],{bytes=bytes,fnv1a32=hash}
end
local function do_run(r,here)
 require_(type(here)=='string' and here:sub(1,1)=='/' and not here:find('["\\\r\n]'),'Runtime path must be absolute, without double quotes, backslashes or newlines')
 local s=M.capture(r)
 -- Only a saved project's parent may own publication media. Python additionally
 -- pins and rejects symlink/non-normalized Audio directories before native work.
 require_(project_path(r,s.project)==s.saved_path,'Saved project path changed before Audio creation')
 -- The documented mkdir return is not an existence test: on macOS an
 -- already-existing Audio can return 0. Attempt creation, then let the helper
 -- strictly validate/pin the normalized, non-symlink directory before DSP.
 r.RecursiveCreateDirectory(s.job.output_dir,0)
 require_(project_path(r,s.project)==s.saved_path,'Saved project path changed during Audio creation')
 local nonce='job-'..r.genGuid():gsub('[{}%-]','');require_(nonce:match('^job%-%w+$') and #nonce<=80,'Invalid generated job identity')
 local leaf=here..'/runs/'..nonce;local existing=io.open(leaf..'/job.json','rb')
 if existing then existing:close();error('Generated job already exists',0)end
 require_(r.RecursiveCreateDirectory(leaf,0)~=0,'Cannot create owned job directory')
 s.job.nonce=nonce;local job_text=json(s.job);filewrite(leaf..'/job.json',job_text)
 -- ExecProcess is synchronous: the REAPER UI cannot service Cancel during it.
 -- Native/Python budgets and this outer wait scale from actual work, not duration caps.
 local command='/usr/bin/python3 "'..here..'/render.py" "'..leaf..'/job.json"'
 local result=r.ExecProcess(command,M.timeout_ms(s.job,#job_text))
 require_(type(result)=='string' and result:match('^0[\r\n]'),'Helper failed/timed out. No take added. Files retained: '..leaf..'\n'..tostring(result))
 local rf=require_(io.open(leaf..'/result.txt','rb'),'Helper did not publish verified success');local text=rf:read('*a');rf:close()
 local output,receipt=M.receipt(text,s.job);local id=fingerprint(output)
 require_(id.bytes==receipt.bytes and id.fnv1a32==receipt.fnv1a32,'Rendered WAV identity mismatch')
 M.unchanged(r,s,'after-helper')
 local pcm=require_(r.PCM_Source_CreateFromFile(output),'REAPER could not open verified rendered WAV')
 local length,qn=r.GetMediaSourceLength(pcm)
 if qn or r.GetMediaSourceSampleRate(pcm)~=s.job.rate or r.GetMediaSourceNumChannels(pcm)~=s.job.channels or math.abs(length*s.job.rate-s.job.output_frames)>.00001 then r.PCM_Source_Destroy(pcm);error('REAPER result metadata mismatch; no take added',0)end
 -- Recheck immediately before the sole project mutation.
 local valid,why=pcall(M.unchanged,r,s,'before-import');if not valid then r.PCM_Source_Destroy(pcm);error(why,0)end
 r.Undo_BeginBlock2(s.project)
 local added,attached=false,false
 local ok,err=pcall(function()
  local new=require_(r.AddTakeToMediaItem(s.item),'Cannot add take');added=true
  require_(r.SetMediaItemTake_Source(new,pcm),'Cannot attach rendered source');attached=true
  local configuration={D_STARTOFFS=0,D_PLAYRATE=1,D_PITCH=0,B_PPITCH=1,I_CHANMODE=0,I_PITCHMODE=-1,I_STRETCHFLAGS=0}
  for key,value in pairs(configuration)do require_(r.SetMediaItemTakeInfo_Value(new,key,value),'Cannot configure rendered take')end
  for key,value in pairs(configuration)do require_(r.GetMediaItemTakeInfo_Value(new,key)==value,'Rendered take readback mismatch: '..key)end
  new=M.copy_processing(r,s.item,s.take,new,s.processing)
  require_(r.CountTakes(s.item)==#s.originals+1,'Unexpected take count after copy')
  verify_originals(r,s.item,s.originals)
  r.GetSetMediaItemTakeInfo_String(new,'P_NAME','Logic Polyphonic (rendered)',true)
  r.SetActiveTake(new)
  local new_source=r.GetMediaItemTake_Source(new)
  require_(r.GetActiveTake(s.item)==new and new_source and r.GetMediaSourceFileName(new_source,'')==output and r.GetTakeNumStretchMarkers(new)==0 and r.GetMediaItemTakeInfo_Value(new,'D_PLAYRATE')==1 and r.GetMediaItemTakeInfo_Value(new,'D_STARTOFFS')==0,'Rendered take verification failed')
  require_(r.GetMediaItemInfo_Value(s.item,'D_POSITION')==s.position and r.GetMediaItemInfo_Value(s.item,'D_LENGTH')==s.length,'Item alignment changed')
 end)
 if not ok then
  if added then
   local restored,detail=pcall(restore_originals,r,s)
   if not restored then err=tostring(err)..'\nROLLBACK FAILED: use Undo and inspect original item. '..tostring(detail)end
  end
  if not attached then r.PCM_Source_Destroy(pcm)end
 end
 r.Undo_EndBlock2(s.project,ok and 'Render stretch markers with installed Logic Polyphonic (new take)' or 'Polyphonic import failed (check original)',-1)
 r.UpdateItemInProject(s.item);r.UpdateArrange();require_(ok,err)
 return true,output
end
function M.run(r,here)
 -- Suppress implicit REAPER undo on refusal/no-import; explicit undo on import.
 if r.defer then r.defer(function()end)end
 local ok,a,b=pcall(do_run,r,here)
 if not ok then return false,a end
 return a,b
end
M.json=json;M.fingerprint=fingerprint
return M
