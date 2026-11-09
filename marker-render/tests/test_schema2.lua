-- Focused portable capture: no DAW. Fake host state, real file identity.
local here=arg[1];arg[2]='fixture-only';dofile(here..'/tests/test_action.lua')
local f=fixture;local M,r,take,item,source=f.M,f.r,f.take,f.item,f.source
local projectpath=here..'/tests/fixture.wav' -- existing named-path seam, not a real RPP
r.EnumProjects=function()return f.project,projectpath end
source.length=180;item.values.D_LENGTH=4;take.values.D_STARTOFFS=1
for _,rate in ipairs({.5,2})do
 take.values.D_PLAYRATE=rate;take.markers={{rate,1.25+rate,0},{3*rate,1.25+3*rate,0}}
 local s=M.capture(r);local R=source.rate
 assert(s.job.version==2,'schema2 required')
 assert(s.job.output_dir==here..'/tests/Audio','derive saved-project Audio')
 assert(s.job.crop_start==1.25*R and s.job.crop_end==(1.25+4*rate)*R,'raw outer rate slope')
 assert(M.json(s.job.points)==M.json({{0,0},{rate*R,R},{3*rate*R,3*R},{4*rate*R,4*R}}),'normalize raw marker pos/rate')
end
-- Clip raw geometry before rounding, not interpolation of already rounded coordinates.
take.values.D_PLAYRATE=2;item.values.D_LENGTH=1/48000
local R=source.rate
take.markers={{-1.4/R,1/R,0},{4.6/R,4/R,0}}
local s=M.capture(r)
assert(s.job.crop_start==2 and s.job.crop_end==3,'raw source endpoints round only once')
-- No arbitrary duration admission substitute.
take.markers={};take.values.D_PLAYRATE=1;item.values.D_LENGTH=96;take.values.D_STARTOFFS=1
assert(M.capture(r).job.output_frames==96*R)
local original=r.EnumProjects
r.EnumProjects=function()return f.project,''end
local ok,why=pcall(M.capture,r);assert(not ok and tostring(why):find('saved',1,true),'unsaved project must refuse')
r.EnumProjects=original
local saved=M.capture(r);projectpath=here..'/README.md'
ok,why=pcall(M.unchanged,r,saved);assert(not ok and tostring(why):find('path',1,true),'renamed project must refuse')
assert(f.imports()==0 and f.undos()==0)
print('PASS schema2 saved Audio, raw nonunity map, one-round clipping, 96s admission, unsaved/rename refusal')
