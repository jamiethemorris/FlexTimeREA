-- Actual M.run, synthetic host/helper; NO DSP. Native macOS may return zero
-- when Audio already exists; the Python helper owns strict directory validation.
local root,prefix=assert(arg[1]),assert(arg[2])
arg[2]='fixture-only';dofile(root..'/tests/test_action.lua')
local f=fixture;local M,r,item,take=f.M,f.r,f.item,f.take
local audio=root..'/tests/Audio'
local add=r.AddTakeToMediaItem
r.AddTakeToMediaItem=function(i)local t=add(i);t.guid='{DEST-'..prefix..f.imports()..'}';return t end
assert(os.execute('/bin/mkdir -p "'..audio..'"'))
local mkdir=r.RecursiveCreateDirectory
local calls,helpers,sequence=0,0,0
r.RecursiveCreateDirectory=function(path,flags)
 if path==audio then calls=calls+1;return 0 end
 return mkdir(path,flags)
end
r.genGuid=function()sequence=sequence+1;return '{'..prefix..sequence..'}'end
local function write_new(path,data)
 local prior=io.open(path,'rb');if prior then prior:close();error('Fixture target already exists')end
 local out=assert(io.open(path,'wb'));assert(out:write(data));assert(out:close())
end
r.ExecProcess=function(command)
 helpers=helpers+1
 local leaf=assert(command:match('"([^"]+)/job.json"$'));local nonce=assert(leaf:match('/(job%-%w+)$'))
 local output=audio..'/FlexTime-'..nonce..'.wav'
 local pcm=string.rep('\0',144000*4)
 local wav=string.pack('<c4I4c4c4I4I2I2I4I4I2I2c4I4','RIFF',#pcm+36,'WAVE','fmt ',16,3,1,48000,192000,4,32,'data',#pcm)..pcm
 write_new(output,wav);local id=M.fingerprint(output)
 write_new(leaf..'/result.txt',table.concat({'OK','2',nonce,'48000','1','144000',tostring(id.bytes),tostring(id.fnv1a32),string.rep('a',64),output},'\n')..'\n')
 return '0\nEXPLICIT SYNTHETIC HELPER; NO DSP\n'
end
-- Two normal action imports into the same existing Audio, without DSP.
for i=1,2 do
 item.take=take
 local ok,why=M.run(r,root)
 assert(ok,'Existing Audio refused: '..tostring(why))
 assert(calls==i and helpers==i and #item.takes==i+1 and item.take~=take)
 assert(f.undos()==0 and take.values.D_PLAYRATE==1 and take.values.D_STARTOFFS==.5)
end
print('PASS M.run twice with preexisting Audio / native mkdir return 0; SYNTHETIC helper/host, NO DSP')
-- A zero result for a new owned job directory remains a creation refusal.
item.take=take
r.RecursiveCreateDirectory=function(path)if path==audio then return 0 end;return 0 end
local ok,why=M.run(r,root)
assert(not ok and tostring(why):find('Cannot create owned job directory',1,true),tostring(why))
assert(helpers==2 and #item.takes==3 and item.take==take and f.undos()==0)
print('PASS zero new-job mkdir refuses before helper/import')
