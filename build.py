#!/usr/bin/env python3
"""Build locally; preflight the exact sandbox before any MADSP execution."""
from pathlib import Path
import hashlib,json,subprocess,sys,os,socket,shlex,platform,tempfile
ROOT=Path(__file__).resolve().parent
RUN=ROOT/'runtime'; RUN.mkdir(exist_ok=True)
POLICY=RUN/'sandbox.sb'
APP=Path(os.environ.get('FLEX_LOGIC_APP','/Applications/Logic Pro.app')).expanduser().resolve()/'Contents/Frameworks'
MADSP=APP/'MADSP.framework/Versions/A/MADSP'
EXPECTED='1fd28ddf6592db72533511ea6f916d9a500659269c8a2f71ff758e9f90376e3b'
def bounded(args, **kw):
    return subprocess.run(args,cwd=ROOT,text=True,capture_output=True,timeout=45,**kw)
def main():
    if sys.argv[1:] not in ([],['--compile-only']):
        raise SystemExit('usage: python3 build.py [--compile-only]')
    compiler=shlex.split(os.environ.get('CXX','c++'))
    command=compiler+['-std=c++17','-O2','-Wall','-Wextra','-Werror',
                     'flex-render.cpp','-o',str(RUN/'flex-render')]
    if platform.system()=='Darwin': command+=['-Wl,-rpath,'+str(APP)]
    else: command+=['-ldl']
    p=bounded(command)
    (RUN/'build.json').write_text(json.dumps({'returncode':p.returncode,'stdout':p.stdout,'stderr':p.stderr},indent=2)+'\n')
    print(p.stdout+p.stderr,end='')
    if p.returncode: raise SystemExit(p.returncode)
    if sys.argv[1:]==['--compile-only']:
        print('Built runtime/flex-render; framework execution NOT validated')
        return
    if platform.system()!='Darwin' or platform.machine()!='arm64':
        raise SystemExit('Native execution requires macOS arm64; use --compile-only elsewhere')
    if hashlib.sha256(MADSP.read_bytes()).hexdigest()!=EXPECTED:
        raise SystemExit('MADSP identity changed; ABI needs revalidation')
    # User-home reads are denied except the project; only runtime writes allowed.
    policy=f'''(version 1)
(allow default)
(deny network*)
(deny process-fork)
(deny file-write*)
(deny file-read* (subpath "{Path.home()}"))
(allow file-read* (subpath "{ROOT}"))
(allow file-write* (subpath "{RUN}"))
(allow file-write-data (literal "/dev/null"))
'''
    POLICY.write_text(policy)
    env={'PATH':'/usr/bin:/bin','HOME':str(RUN),'TMPDIR':str(RUN)}
    # Fixed external write target inside project but outside authorized runtime.
    outside=ROOT/'sandbox-must-not-exist'
    if outside.exists(): raise SystemExit('preflight sentinel already exists')
    probe='''import os,socket,json
result={}
for key,path in [('outside_write',os.environ['OUTSIDE']),('inside_write',os.environ['INSIDE'])]:
 try:
  with open(path,'w') as f: f.write('preflight')
  result[key]='allowed'
 except PermissionError: result[key]='denied'
try:
 with open(os.environ['SECRET'],'rb') as f: f.read(1)
 result['unrelated_read']='allowed'
except PermissionError: result['unrelated_read']='denied'
s=socket.socket(); s.settimeout(1)
try:
 s.connect(('127.0.0.1',int(os.environ['PORT'])))
 result['network']='allowed'
except PermissionError: result['network']='denied'
finally: s.close()
print(json.dumps(result))
'''
    # Owned synthetic sentinel outside the readable project; never read user config.
    sentinel=tempfile.TemporaryDirectory(prefix='.flex-preflight-',dir=ROOT.parent)
    secret=Path(sentinel.name)/'synthetic-read-sentinel'
    secret.write_text('synthetic preflight data')
    listener=socket.socket(); listener.bind(('127.0.0.1',0)); listener.listen(1)
    penv={**env,'OUTSIDE':str(outside),'INSIDE':str(RUN/'preflight-write.txt'),
          'SECRET':str(secret),'PORT':str(listener.getsockname()[1])}
    try:
        p=bounded(['/usr/bin/sandbox-exec','-f',str(POLICY),sys.executable,'-c',probe],env=penv)
    finally:
        listener.close()
        sentinel.cleanup()
    report={'command':'sandbox-exec exact policy preflight','returncode':p.returncode,'stdout':p.stdout,'stderr':p.stderr}
    (RUN/'preflight.json').write_text(json.dumps(report,indent=2)+'\n')
    if p.returncode or json.loads(p.stdout)!={'outside_write':'denied','inside_write':'allowed','unrelated_read':'denied','network':'denied'}:
        raise SystemExit('Sandbox preflight failed: '+str(report))

    print('Built runtime/flex-render; sandbox preflight passed')
if __name__=='__main__':main()
