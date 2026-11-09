-- Receipt parser contract; explicit synthetic strings, never native evidence.
local here=arg[1];local M=dofile(here..'/marker_render.lua')
local job={nonce='job-receipt',version=2,output_dir='/owned/Audio',rate=48000,channels=2,output_frames=144000,identity={bytes=345600044},crop_start=0,crop_end=48000,points={{0,0},{48000,144000}}}
local expected='/owned/Audio/FlexTime-job-receipt.wav'
local lines={'OK','2',job.nonce,'48000','2','144000','1152044','123',string.rep('a',64),expected}
local function receipt(a)return table.concat(a,'\n')..'\n'end
local output,id=M.receipt(receipt(lines),job)
assert(output==expected and id.bytes==1152044 and id.fnv1a32==123)
local cases=0
for i,v in ipairs({'NOT_OK','1','other','44100','1','10','x','4294967296','xyz','/owned/runs/result.wav'})do
 local bad={table.unpack(lines)};bad[i]=v
 local ok,why=pcall(M.receipt,receipt(bad),job)
 assert(not ok and tostring(why):find('Invalid helper success receipt',1,true),'field '..i..' accepted');cases=cases+1
end
for _,bad in ipairs({receipt(lines)..'extra\n',receipt(lines):sub(1,-2),receipt(lines)..'tail',(receipt(lines):gsub('\n','\r\n'))})do
 assert(not pcall(M.receipt,bad,job));cases=cases+1
end
local timeout=M.timeout_ms(job,777)
assert(timeout>120000,'work-scaled timeout should exceed former fixed120s for long source')
job.identity.bytes=100000;local short=M.timeout_ms(job,777);assert(short<timeout and short>0)
print('PASS schema2 exact Audio receipt + '..cases..' malformed controls and workload-derived wait')
