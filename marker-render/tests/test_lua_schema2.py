"""Focused Lua schema2 -> real supervisor/native checks; never controls a DAW."""
from pathlib import Path
import array, hashlib, importlib.util, json, math, random, shutil, subprocess, sys, wave
sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parents[1]
prefix=sys.argv[1]
assert prefix.isascii() and prefix.isalnum(), 'fresh ASCII alphanumeric prefix required'
ev=ROOT/'evidence'/prefix;ev.mkdir(parents=True,exist_ok=False)
spec=importlib.util.spec_from_file_location('render',ROOT/'render.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
rate=48000;rng=random.Random(272);data=array.array('h')
for i in range(rate*12):
 burst=0
 for t in (1.5,2.5,5,7):
  j=i-round(t*rate)
  if 0<=j<rate//12:burst+=.65*math.exp(-j/(rate*.007))*rng.uniform(-1,1)
 data.append(round(32767*(.04*math.sin(2*math.pi*440*i/rate)+burst)))
source=ev/'synthetic source.wav'
with wave.open(str(source),'wb') as f:f.setparams((1,2,rate,0,'NONE','not compressed'));f.writeframes(data.tobytes())
before=hashlib.sha256(source.read_bytes()).hexdigest()
rows=[]
commands=[['lua',str(ROOT/'tests'/n),str(ROOT)] for n in ('test_schema2.lua','test_receipt2.lua','test_processing_copy.lua','test_envelope_scope.lua','test_modulation_admission.lua','test_offline_fx.lua','test_usability.lua')]
commands += [['lua',str(ROOT/'tests/test_action.lua'),str(ROOT),'capture-only'],['lua',str(ROOT/'tests/test_fingerprint.lua'),str(ROOT),prefix],['lua',str(ROOT/'tests/test_copy_rollback.lua'),str(ROOT),prefix+'Rollback'],['lua',str(ROOT/'tests/test_rate_action.lua'),str(ROOT),prefix,str(source)]]
commands += [['lua',str(ROOT/'tests/test_existing_audio.lua'),str(ROOT),prefix+'Existing']]
commands += [['luac','-p',str(ROOT/'marker_render.lua')]+[str(p) for p in sorted((ROOT/'tests').glob('*.lua'))]]
for n,argv in enumerate(commands):
 p=subprocess.run(argv,text=True,capture_output=True,timeout=180,cwd=ROOT)
 (ev/('command-%d.log'%n)).write_text(p.stdout+p.stderr)
 rows.append(dict(argv=argv,exit=p.returncode,stdout=p.stdout,stderr=p.stderr))
 (ev/'commands.json').write_text(json.dumps(rows,indent=2))
 print(p.stdout+p.stderr,end='');assert p.returncode==0,argv
metrics=[]
for index,playrate,expected,stable in ((1,.5,[1,3],(1.6,2.4)),(2,2,[.25,.75,2,3],(1,1.7))):
 lines=(ROOT/'evidence'/('%s-%d.txt'%(prefix,index))).read_text().splitlines();output=Path(lines[0]);leaf=Path(lines[1]);timeout=int(lines[2])
 job=json.loads((leaf/'job.json').read_text());result=json.loads((leaf/'result.json').read_text())
 assert result['destination']==str(output) and output.parent==ROOT/'tests/Audio'
 assert timeout==(m.budgets(job,(leaf/'job.json').stat().st_size)['wall_seconds']+15)*1000,'Lua/Python timeout budget drift'
 rr,ch,pcm=m.decode(output.read_bytes());assert (rr,ch,len(pcm))==(rate,1,rate*4)
 assert all(math.isfinite(x) for x in pcm) and 'finite/canaries=pass' in result['native']['stdout']
 errors=[];actuals=[];size=round(rate*.01);bounds=[0]+[(a+b)/2 for a,b in zip(expected,expected[1:])]+[4]
 for k,want in enumerate(expected):
  best=max(range(round(bounds[k]*rate),round(bounds[k+1]*rate)-size,size),key=lambda i:sum(float(x)**2 for x in pcm[i:i+size]))
  actual=(best+size/2)/rate;actuals.append(actual);errors.append(abs(actual-want))
 a,b=(round(x*rate) for x in stable)
 crossings=[i-pcm[i]/(pcm[i+1]-pcm[i]) for i in range(a,b-1) if pcm[i]<=0<pcm[i+1]]
 hz=(len(crossings)-1)*rate/(crossings[-1]-crossings[0]);assert abs(hz-440)<2 and max(errors)<.04
 assert hashlib.sha256(source.read_bytes()).hexdigest()==before
 assert result['sha256']==hashlib.sha256(output.read_bytes()).hexdigest()
 metrics.append(dict(playrate=playrate,output=str(output),job=str(leaf/'job.json'),frames=len(pcm),crop=[job['crop_start'],job['crop_end']],expected_landmarks=expected,actual_landmarks=actuals,max_error=max(errors),pitch_hz=hz,timeout_ms=timeout,native_seconds=result['native']['seconds']))
(ev/'metrics.json').write_text(json.dumps(metrics,indent=2))
assert not list((m.BUILD/'analysis').iterdir())
print(json.dumps(metrics,indent=2));print('PASS focused portable Lua + two real rate-native renders; no host claims')
