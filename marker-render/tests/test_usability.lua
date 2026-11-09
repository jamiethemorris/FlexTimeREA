-- Portable capture only: original host state is read, never edited by capture.
local here=arg[1];arg[2]='fixture-only';dofile(here..'/tests/test_action.lua')
local f=fixture;local M,r,take,item,source=f.M,f.r,f.take,f.item,f.source
local cases=0
local function capture(points,crop_start,crop_end,total)
 local before=M.json(take.markers);local chunk=item.chunk
 local s=M.capture(r)
 assert(M.json(s.job.points)==M.json(points),'map: '..M.json(s.job.points))
 assert(s.job.crop_start==crop_start and s.job.crop_end==crop_end and s.job.output_frames==total,'crop/output')
 assert(M.json(take.markers)==before and item.chunk==chunk and s.chunk==chunk,'original snapshot/markers changed')
 assert(f.imports()==0 and f.undos()==0,'capture mutated host')
 cases=cases+1;return s
end
local function rejects(needle)
 local ok,why=pcall(M.capture,r);assert(not ok and tostring(why):find(needle,1,true),tostring(why));cases=cases+1
end
for _,rate in ipairs({44100,48000})do
 source.rate=rate
 for _,delta in ipairs({-.49,-.001,0,.001,.49,.5})do
  take.markers={{0,.5,0},{1.5+delta/rate,1.5+delta/rate,0},{3,3.5,0}}
  local s=math.floor(1.5*rate+delta+.5)
  capture({{0,0},{s-rate/2,s},{3*rate,3*rate}},rate/2,rate*3.5,rate*3)
 end
 -- Refuse collapsed coordinates, never remove/move original user markers.
 take.markers={{0,.5,0},{1/rate,.5+1/rate,0},{1.1/rate,.5+2/rate,0},{3,3.5,0}};rejects('increase')
 take.markers={{0,.5,0},{1/rate,.5+1/rate,0},{2/rate,.5+1.1/rate,0},{3,3.5,0}};rejects('increase')
 take.markers={{0,.5,0},{1.1/rate,.5+1/rate,0},{1/rate,.5+2/rate,0},{3,3.5,0}};rejects('increase')
end
print('PASS ordinary nearest-sample capture and collision refusals: '..cases)
source.rate=48000;source.length=12;item.values.D_LENGTH=4;take.values.D_STARTOFFS=1
local R=source.rate
-- Exact outcomes of the retained native endpoint probe, independent of offset.
take.markers={{1,2.25,0},{3,5.25,0}}
local snapshot=capture({{0,0},{R,R},{4*R,3*R},{5*R,4*R}},1.25*R,6.25*R,4*R)
item.chunk='same integer map, fractional original edit'
local ok,why=pcall(M.unchanged,r,snapshot)
assert(not ok and tostring(why):find('Item/take edited',1,true),'raw snapshot edit was missed')
item.chunk=snapshot.chunk
take.markers={{2,3.5,0}};capture({{0,0},{2*R,2*R},{4*R,4*R}},1.5*R,5.5*R,4*R)
take.markers={};capture({{0,0},{4*R,4*R}},R,5*R,4*R)
-- Bracketing markers are clipped by linear interpolation, not unity extension.
take.markers={{-1,1,0},{5,10,0}};capture({{0,0},{6*R,4*R}},2.5*R,8.5*R,4*R)
take.markers={{-2,1,0},{1,4,0},{3,7,0},{6,10,0}}
capture({{0,0},{R,R},{4*R,3*R},{5*R,4*R}},3*R,8*R,4*R)
take.markers={{-2,1,0}};capture({{0,0},{4*R,4*R}},3*R,7*R,4*R)
take.markers={{6,8,0}};capture({{0,0},{4*R,4*R}},2*R,6*R,4*R)
-- Refuse extrapolated overrun rather than clamp, pad or wrap.
take.markers={{2,1,0}};rejects('source bounds')
take.markers={{2,11,0}};rejects('source bounds')
take.markers={{1,2,0},{1,3,0}};rejects('increase')
print('PASS inferred/clipped endpoints and original snapshot guard: '..cases..' cumulative cases')
-- Duration ratio means destination/source, independently bounded per segment.
source.length=12;take.values.D_STARTOFFS=0
for _,ratio in ipairs({.25,4})do
 item.values.D_LENGTH=2*ratio;take.markers={{0,0,0},{2*ratio,2,0}}
 capture({{0,0},{2*R,2*ratio*R}},0,2*R,2*ratio*R)
end
for _,ratio in ipairs({.249,4.001})do
 item.values.D_LENGTH=2*ratio;take.markers={{0,0,0},{2*ratio,2,0}};rejects('ratio')
end
print('PASS 0.25–4 local duration ratio admission/refusals: '..cases..' cumulative cases')
item.values.B_LOOPSRC=1;item.values.D_LENGTH=4;take.values.D_STARTOFFS=1;take.markers={}
capture({{0,0},{4*R,4*R}},R,5*R,4*R)
assert(item.values.B_LOOPSRC==1,'harmless LOOP flag was changed')
take.markers={{1,2.25,0},{3,5.25,0}}
capture({{0,0},{R,R},{4*R,3*R},{5*R,4*R}},1.25*R,6.25*R,4*R)
assert(item.values.B_LOOPSRC==1)
take.markers={};take.values.D_STARTOFFS=8
capture({{0,0},{4*R,4*R}},8*R,12*R,4*R)
take.values.D_STARTOFFS=8+1/R;rejects('source bounds')
take.values.D_STARTOFFS=1;source.type='SECTION';rejects('Bare WAV');source.type='WAVE'
r.GetMediaSourceParent=function()return {}end;rejects('Bare WAV');r.GetMediaSourceParent=function()return nil end
assert(item.values.B_LOOPSRC==1,'refusal changed LOOP flag')
print('PASS harmless LOOP flag only, real looping/SECTION/reverse refused: '..cases..' cumulative cases')
