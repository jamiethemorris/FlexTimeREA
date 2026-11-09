-- Full-file streamed identity; real >former cap file plus bounded-read seam.
local here=arg[1];local prefix=arg[2] or ('fingerprint'..os.time()..math.floor(os.clock()*1000000))
local M=dofile(here..'/marker_render.lua')
local path=here..'/evidence/'..prefix..'-fingerprint.fixture'
local existing=io.open(path,'rb');if existing then existing:close();error('preserve existing fingerprint fixture')end
local f=assert(io.open(path,'wb'));assert(f:seek('set',36864043));assert(f:write('\0'));assert(f:close())
local id=M.fingerprint(path);assert(id.bytes==36864044 and type(id.fnv1a32)=='number')
local open=io.open;local reads,closed=0,false
io.open=function(p,mode)
 if p=='synthetic-growing-file' then
  return {seek=function(_,kind)return kind=='end' and 44 or 0 end,
   read=function(_,n)assert(n<=256*1024,'unbounded read');reads=reads+1;return string.rep('\0',n)end,
   close=function()closed=true;return true end}
 end
 return open(p,mode)
end
local accepted,why=pcall(M.fingerprint,'synthetic-growing-file');io.open=open
assert(not accepted and tostring(why):find('changed',1,true) and closed and reads==2,tostring(why))
print('PASS full streamed 36,864,044-byte identity; bounded reads and grow refusal; retained '..path)
