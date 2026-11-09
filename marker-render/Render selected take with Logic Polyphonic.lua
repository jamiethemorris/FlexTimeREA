-- Experimental action: test first with synthetic audio in a disposable saved project.
local path=debug.getinfo(1,'S').source:sub(2):match('^(.*)/')
local M=dofile(path..'/marker_render.lua')
local ok,result=M.run(reaper,path)
if not ok then reaper.ShowMessageBox(tostring(result),'Polyphonic render — no verified import',0)end
