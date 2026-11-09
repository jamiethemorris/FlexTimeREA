#!/usr/bin/python3
"""Offline WAV supervisor: streamed identity/crop/publication, isolated native DSP."""
from pathlib import Path
import array, hashlib, io, json, math, os, resource, shutil, stat, struct, subprocess, sys, time
ROOT=Path(__file__).resolve().parent
BUILD=ROOT/'build-logic13-1'  # Exact local build required by this runtime.
FRAMEWORKS=Path('/Applications/Logic Pro.app/Contents/Frameworks')
# Logic 13.0 (7801), ARM64. See ATTRIBUTION.md for provenance/version limits.
# Never accept unrecognized hashes.
PINS={'MADSP':'debcb14d002a70694077bde72e7a7f17a89f0f21e223be365fd3cb290564f7da','MAMusicAnalysis':'208be62acb634fc42a728a476806ed3bfbc9527009dd5c56507728841e29f196','MAFiles':'287db4300302ae90c2a29b4b5ba27a69c097403574d6ad21d0ee6f0597698bfe'}
RIFF_MAX=0xffffffff
BLOCK=256*1024
BASE_MEMORY=256*1024*1024

def require(ok,message):
 if not ok:raise ValueError(message)
def integer(v):return type(v) is int
def fnv(data,h=2166136261):
 for b in data:h=((h^b)*16777619)&0xffffffff
 return h
def digest(data):return hashlib.sha256(data).hexdigest()
def check(deadline):require(time.monotonic()<deadline,'job deadline exceeded')
def identity(s):return s.st_dev,s.st_ino,s.st_size,s.st_mtime_ns

def available_memory():
 # Admission estimate, NOT an enforceable RSS/VM cap. macOS rejects AS/DATA.
 text=subprocess.check_output(['/usr/bin/vm_stat'],text=True,timeout=3)
 page=int(text.split('page size of ')[1].split(' bytes')[0]);counts={}
 for line in text.splitlines()[1:]:
  if ':' in line:
   k,v=line.split(':',1)
   if v.strip().rstrip('.').isdigit():counts[k]=int(v.strip().rstrip('.'))
 return page*sum(counts.get(k,0) for k in ('Pages free','Pages inactive','Pages speculative'))

def safe_directory(value):
 require(type(value) is str and not any(c in value for c in '\0\r\n') and Path(value).is_absolute() and Path(value).name=='Audio','output directory')
 path=Path(value)
 require(str(path.resolve(strict=True))==value and path.is_dir(),'output directory must be normalized and non-symlink')
 return path

def validate(job):
 require(type(job) is dict and set(job)=={'version','nonce','source','output_dir','identity','rate','channels','crop_start','crop_end','points','output_frames'},'job schema')
 require(integer(job['version']) and job['version']==2,'job version')
 require(type(job['nonce']) is str and 1<=len(job['nonce'])<=80 and all(c in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_' for c in job['nonce']),'job nonce')
 require(type(job['source']) is str and Path(job['source']).is_absolute() and not any(c in job['source'] for c in '\0\r\n'),'source path')
 safe_directory(job['output_dir'])
 ident=job['identity'];require(type(ident) is dict and set(ident)=={'bytes','fnv1a32'} and all(integer(x) for x in ident.values()) and 44<=ident['bytes']<=RIFF_MAX+8 and 0<=ident['fnv1a32']<=RIFF_MAX,'source identity')
 require(integer(job['rate']) and job['rate'] in (44100,48000) and integer(job['channels']) and job['channels'] in (1,2),'job format')
 a,b,total=job['crop_start'],job['crop_end'],job['output_frames'];ch=job['channels']
 require(all(integer(v) for v in (a,b,total)) and 0<=a<b<=RIFF_MAX and 0<total<=RIFF_MAX and (b-a)*ch*4<=RIFF_MAX-36 and total*ch*4<=RIFF_MAX-36,'crop/output representational bounds')
 points=job['points'];require(type(points) is list and 2<=len(points)<=b-a+1,'map count')
 require(all(type(p) is list and len(p)==2 and all(integer(x) for x in p) for p in points),'map coordinates')
 require(points[0]==[0,0] and points[-1]==[b-a,total],'map endpoints')
 for (s,d),(ss,dd) in zip(points,points[1:]):
  require(0<=s<ss<=b-a and 0<=d<dd<=total and (ss-s)<=4*(dd-d) and (dd-d)<=4*(ss-s),'map order/local duration ratio')
 return job

def budgets(job,job_bytes):
 frames=job['crop_end']-job['crop_start'];crop=frames*job['channels']*4;out=job['output_frames']*job['channels']*4
 # Calibration: 21.7 MB/s FNV; 0.92 M native frames/s. Deliberately lower
 # rates + startup slack are allowances, not promised throughput.
 native=math.ceil(8+(frames+job['output_frames'])*job['channels']/50_000+len(job['points'])*.002+crop/2_000_000)
 wall=math.ceil(10+native+(2*job['identity']['bytes']+3*(out+44))/2_000_000+crop/800_000+job_bytes/1_000_000)
 memory=BASE_MEMORY+crop*12+frames*64+job_bytes*32
 cuts=(frames+len(job['points'])+2)*22
 return dict(native_seconds=native,wall_seconds=wall,cpu_seconds=native,file_bytes=max(crop+44,out+44,cuts,job_bytes),memory_bytes=memory,leaf_disk_bytes=2*crop+2*out+cuts+44,publication_disk_bytes=out+44)

def admit(job,leaf,budget):
 require(budget['memory_bytes']<=available_memory()//2,'resource refusal: estimated native/analysis memory exceeds half currently available memory')
 needs={}
 for path,n in ((leaf,budget['leaf_disk_bytes']),(Path(job['output_dir']),budget['publication_disk_bytes']),(BUILD/'analysis',(job['crop_end']-job['crop_start'])*job['channels']*4+44)):
  device=path.stat().st_dev;old=needs.get(device,(path,0));needs[device]=(path,old[1]+n)
 for path,n in needs.values():require(shutil.disk_usage(path).free>=n+max(BLOCK*4,n//10),'resource refusal: insufficient free disk space')

def limits(budget):
 resource.setrlimit(resource.RLIMIT_CPU,(budget['cpu_seconds'],)*2)
 resource.setrlimit(resource.RLIMIT_FSIZE,(budget['file_bytes'],)*2)
 resource.setrlimit(resource.RLIMIT_NOFILE,(64,64));resource.setrlimit(resource.RLIMIT_CORE,(0,0))

def fingerprint(f,size,deadline):
 f.seek(0);h=2166136261;sha=hashlib.sha256();n=0
 while n<size:
  check(deadline);block=f.read(min(BLOCK,size-n));require(block,'truncated identity read');n+=len(block);h=fnv(block,h);sha.update(block)
 require(not f.read(1),'file grew while hashing');check(deadline)
 return dict(bytes=n,fnv1a32=h,sha256=sha.hexdigest())

def stream_sha(f):
 sha=hashlib.sha256()
 while True:
  block=f.read(BLOCK)
  if not block:return sha.hexdigest()
  sha.update(block)

def wave_info(f,size,deadline=math.inf):
 check(deadline);f.seek(0);head=f.read(12)
 require(len(head)==12 and head[:4]==b'RIFF' and head[8:]==b'WAVE' and struct.unpack_from('<I',head,4)[0]+8==size,'unsupported RIFF extent')
 fmt=None;data=None;pos=12
 while pos+8<=size:
  check(deadline);f.seek(pos);chunk=f.read(8);require(len(chunk)==8,'truncated RIFF chunk');tag,n=struct.unpack('<4sI',chunk);pos+=8
  require(pos+n+(n&1)<=size,'truncated RIFF chunk')
  if tag==b'fmt ':require(fmt is None and n in (16,18),'unsupported/duplicate fmt');fmt=f.read(n)
  if tag==b'data':require(data is None,'duplicate data');data=(pos,n)
  pos+=n+(n&1)
 require(pos==size and fmt is not None and data is not None,'unsupported WAV chunks')
 format,ch,rate,speed,align,bits=struct.unpack_from('<HHIIHH',fmt)
 require(len(fmt)==16 or fmt[16:]==b'\0\0','unsupported extended fmt')
 require(ch in (1,2) and rate in (44100,48000) and ((format==1 and bits in (16,24,32)) or (format==3 and bits==32)),'unsupported WAV format')
 require(align==ch*(bits//8) and speed==rate*align and data[1]>0 and data[1]%align==0,'WAV alignment')
 return dict(rate=rate,channels=ch,format=format,bits=bits,align=align,offset=data[0],frames=data[1]//align)

def floats(block,format,bits):
 if format==3:
  out=array.array('f');out.frombytes(block)
  if sys.byteorder!='little':out.byteswap()
 elif bits==16:out=array.array('f',(x[0]/32768 for x in struct.iter_unpack('<h',block)))
 elif bits==32:out=array.array('f',(x[0]/2147483648 for x in struct.iter_unpack('<i',block)))
 else:out=array.array('f',(int.from_bytes(block[i:i+3],'little',signed=True)/8388608 for i in range(0,len(block),3)))
 require(all(math.isfinite(x) for x in out),'nonfinite audio in crop/output');return out

def decode(raw,max_seconds=None):
 # Small-test compatibility only. Production never materializes a whole WAV.
 f=io.BytesIO(raw);info=wave_info(f,len(raw));f.seek(info['offset'])
 return info['rate'],info['channels'],floats(f.read(info['frames']*info['align']),info['format'],info['bits'])

def crop_to_file(source,info,a,b,path,deadline):
 source.seek(info['offset']+a*info['align']);remaining=b-a
 with path.open('xb') as out:
  while remaining:
   check(deadline);n=min(remaining,BLOCK//info['align']);block=source.read(n*info['align']);require(len(block)==n*info['align'],'truncated crop')
   pcm=floats(block,info['format'],info['bits'])
   if sys.byteorder!='little':pcm.byteswap()
   out.write(pcm.tobytes());remaining-=n

def header(rate,ch,frames):
 n=frames*ch*4;require(n<=RIFF_MAX-36,'RIFF32 output limit')
 return struct.pack('<4sI4s4sIHHIIHH4sI',b'RIFF',n+36,b'WAVE',b'fmt ',16,3,ch,rate,rate*ch*4,ch*4,32,b'data',n)

def verify_wave(f,size,job,deadline):
 info=wave_info(f,size,deadline)
 require((info['rate'],info['channels'],info['frames'],info['format'],info['bits'])==(job['rate'],job['channels'],job['output_frames'],3,32),'final WAV verification')
 f.seek(info['offset']);remaining=info['frames']*info['align']
 while remaining:
  check(deadline);block=f.read(min(BLOCK,remaining));require(block,'truncated final WAV');floats(block,3,32);remaining-=len(block)
 return fingerprint(f,size,deadline)

def unchanged(source,path,before):
 require(identity(os.fstat(source.fileno()))==before and identity(path.lstat())==before and not path.is_symlink(),'source edited during job')

def same_directory(directory,value):
 current=safe_directory(value).stat();owned=os.fstat(directory)
 require((current.st_dev,current.st_ino)==(owned.st_dev,owned.st_ino),'output directory changed')

def run(jobpath):
 start=time.monotonic();path=Path(jobpath).absolute();leaf=path.parent
 require(leaf.parent==ROOT/'runs' and path.name=='job.json' and leaf.resolve()==leaf and not path.is_symlink(),'owned job path required')
 require(stat.S_ISREG(path.lstat().st_mode),'regular job required');job_bytes=path.stat().st_size
 require(job_bytes*32+BASE_MEMORY<=available_memory()//2,'resource refusal: job JSON memory')
 def pairs(items):
  out={}
  for k,v in items:require(k not in out,'duplicate JSON key');out[k]=v
  return out
 with os.fdopen(os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK),'rb') as f:
  require(stat.S_ISREG(os.fstat(f.fileno()).st_mode),'regular job required')
  raw_job=f.read(job_bytes+1);require(len(raw_job)==job_bytes and os.fstat(f.fileno()).st_size==job_bytes,'job extent changed')
 check(start+10+job_bytes/1_000_000)
 job=validate(json.loads(raw_job,object_pairs_hook=pairs,parse_constant=lambda x:(_ for _ in ()).throw(ValueError('nonfinite JSON'))))
 require(job['nonce']==leaf.name,'nonce/path mismatch');budget=budgets(job,job_bytes);deadline=start+budget['wall_seconds'];check(deadline)
 for name in ('source.f32','map.txt','native.f32','cuts.txt','result.wav','result.json','result.txt','native.json','sandbox.sb','stdout.log','stderr.log'):
  require(not os.path.lexists(leaf/name),'job already consumed: '+name)
 destination=Path(job['output_dir'])/('FlexTime-'+job['nonce']+'.wav')
 require(not os.path.lexists(destination),'destination collision');admit(job,leaf,budget)
 directory=os.open(job['output_dir'],os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
 try:
  with os.fdopen(os.open(job['source'],os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK),'rb') as source:
   before=os.fstat(source.fileno());require(stat.S_ISREG(before.st_mode) and before.st_size==job['identity']['bytes'],'source identity changed');before=identity(before)
   source_hash=fingerprint(source,before[2],deadline);unchanged(source,Path(job['source']),before)
   require(source_hash['fnv1a32']==job['identity']['fnv1a32'],'source identity changed')
   info=wave_info(source,before[2],deadline);rate,ch=job['rate'],job['channels']
   require((info['rate'],info['channels'])==(rate,ch) and job['crop_end']<=info['frames'],'source metadata/crop mismatch')
   for name,expected in PINS.items():
    with (FRAMEWORKS/(name+'.framework/Versions/A')/name).open('rb') as f:require(stream_sha(f)==expected,'framework identity changed: '+name)
   binary=BUILD/'native';build=json.loads((BUILD/'build.json').read_text())
   with binary.open('rb') as f:require(stream_sha(f)==build['binary_sha256'],'native binary changed')
   crop_to_file(source,info,job['crop_start'],job['crop_end'],leaf/'source.f32',deadline)
   with (leaf/'map.txt').open('x') as f:
    for point in job['points']:f.write('%d %d\n'%tuple(point))
   policy=r'''(version 1)
(allow default)
(deny network*)
(deny process-fork)
(deny mach-lookup (global-name-regex #"com\.apple\.audio\..*") (global-name-regex #"com\.apple\.midi.*") (global-name-regex #"com\.apple\.cfprefsd.*") (global-name-regex #"com\.apple\.AudioComponent.*"))
(deny file-read* (subpath "/dev"))
(deny file-write*)
(deny file-read* (subpath %s))
(allow file-read* (subpath %s))
(allow file-write* (subpath %s) (subpath %s))
(deny file-write* (subpath %s))
(allow file-write-data (literal "/dev/null"))
'''%(json.dumps(str(Path.home())),json.dumps(str(ROOT)),json.dumps(str(leaf)),json.dumps(str(BUILD/'analysis')),json.dumps(job['output_dir']))
   (leaf/'sandbox.sb').write_text(policy);check(deadline)
   argv=['/usr/bin/sandbox-exec','-f',str(leaf/'sandbox.sb'),str(binary),str(leaf/'source.f32'),str(leaf/'native.f32'),str(rate),str(ch),str(leaf/'map.txt'),str(leaf/'cuts.txt')]
   native_start=time.monotonic()
   with (leaf/'stdout.log').open('xb') as stdout,(leaf/'stderr.log').open('xb') as stderr:
    p=subprocess.run(argv,stdout=stdout,stderr=stderr,timeout=min(budget['native_seconds'],deadline-time.monotonic()),preexec_fn=lambda:limits(budget),env={'HOME':str(leaf),'TMPDIR':str(leaf),'PATH':'/usr/bin:/bin'})
   with (leaf/'stdout.log').open() as f:stdout=f.read(4000)
   with (leaf/'stderr.log').open() as f:stderr=f.read(4000)
   native=dict(argv=argv,exit=p.returncode,stdout=stdout,stderr=stderr,seconds=time.monotonic()-native_start)
   (leaf/'native.json').write_text(json.dumps(native,indent=2));require(p.returncode==0,'native failed: '+stderr);check(deadline)
   require((leaf/'native.f32').stat().st_size==job['output_frames']*ch*4,'native output length')
   unchanged(source,Path(job['source']),before)
   require(fingerprint(source,before[2],deadline)==source_hash,'source edited during job');unchanged(source,Path(job['source']),before)
   with (leaf/'native.f32').open('rb') as raw,(leaf/'result.wav').open('xb') as out:
    out.write(header(rate,ch,job['output_frames']))
    while True:
     check(deadline);block=raw.read(BLOCK)
     if not block:break
     floats(block,3,32);out.write(block)
   size=(leaf/'result.wav').stat().st_size
   with (leaf/'result.wav').open('rb') as f:verified=verify_wave(f,size,job,deadline)
   same_directory(directory,job['output_dir'])
   fd=os.open(destination.name,os.O_RDWR|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600,dir_fd=directory);owned=os.fstat(fd);published=False;receipt_owned=None
   try:
    with os.fdopen(fd,'w+b') as out,(leaf/'result.wav').open('rb') as src:
     while True:
      check(deadline);block=src.read(BLOCK)
      if not block:break
      out.write(block)
     out.flush();os.fsync(out.fileno());require(verify_wave(out,size,job,deadline)==verified,'destination verification')
    current=os.stat(destination.name,dir_fd=directory,follow_symlinks=False)
    require(stat.S_ISREG(current.st_mode) and (current.st_dev,current.st_ino,current.st_size)==(owned.st_dev,owned.st_ino,size),'destination changed')
    same_directory(directory,job['output_dir']);unchanged(source,Path(job['source']),before);check(deadline)
    result=dict(version=2,destination=str(destination),frames=job['output_frames'],rate=rate,channels=ch,**verified,source_sha256=source_hash['sha256'],crop=[job['crop_start'],job['crop_end']],points=job['points'],native_sha256=build['binary_sha256'],native=native,budgets=budget,seconds=time.monotonic()-start)
    with (leaf/'result.json').open('x') as f:f.write(json.dumps(result,indent=2))
    check(deadline)
    with (leaf/'result.txt').open('x') as f:
     receipt_owned=os.fstat(f.fileno());f.write('OK\n2\n%s\n%d\n%d\n%d\n%d\n%d\n%s\n%s\n'%(job['nonce'],rate,ch,result['frames'],size,verified['fnv1a32'],verified['sha256'],destination))
    unchanged(source,Path(job['source']),before);same_directory(directory,job['output_dir']);check(deadline)
    published=True;return result
   finally:
    if not published:
     if receipt_owned is not None:
      try:
       current=(leaf/'result.txt').lstat()
       if stat.S_ISREG(current.st_mode) and (current.st_dev,current.st_ino)==(receipt_owned.st_dev,receipt_owned.st_ino):(leaf/'result.txt').unlink()
      except FileNotFoundError:pass
     try:
      current=os.stat(destination.name,dir_fd=directory,follow_symlinks=False)
      if stat.S_ISREG(current.st_mode) and (current.st_dev,current.st_ino)==(owned.st_dev,owned.st_ino):os.unlink(destination.name,dir_fd=directory)
     except FileNotFoundError:pass
 finally:os.close(directory)

if __name__=='__main__':
 try:
  require(len(sys.argv)==2,'usage: render.py owned-job.json');r=run(sys.argv[1]);print('Verified %d frames; published %s'%(r['frames'],r['destination']))
 except Exception as e:
  print('Render refused/failed: '+str(e),file=sys.stderr);sys.exit(1)
