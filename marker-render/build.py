#!/usr/bin/python3
"""Build only this standalone candidate; refuses to overwrite a compiled helper."""
from pathlib import Path
import hashlib,json,re,subprocess,sys
ROOT=Path(__file__).resolve().parent
if __name__=='__main__':
 if len(sys.argv)>2 or not re.fullmatch(r'build(?:-[A-Za-z0-9_-]+)?',sys.argv[1] if len(sys.argv)==2 else 'build'):raise SystemExit('usage: build.py [build-version]')
 out=ROOT/(sys.argv[1] if len(sys.argv)==2 else 'build')
 if (out/'native').exists() or (out/'build.json').exists():raise SystemExit(str(out)+' already built; preserve it and choose a fresh build-version')
 out.mkdir(exist_ok=True);(out/'analysis').mkdir(exist_ok=True)
 argv=['/usr/bin/clang++','-std=c++17','-arch','arm64','-O2','-Wall','-Wextra','-Werror','-DANALYSIS_DIRECTORY='+json.dumps(str(out/'analysis')),'-Wl,-rpath,/Applications/Logic Pro.app/Contents/Frameworks',str(ROOT/'native.cpp'),'-o',str(out/'native')]
 p=subprocess.run(argv,capture_output=True,text=True,timeout=60)
 receipt=dict(argv=argv,exit=p.returncode,stdout=p.stdout,stderr=p.stderr,sources={n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in ['native.cpp','piecewise.hpp','source_analysis.hpp']})
 if p.returncode==0:receipt['binary_sha256']=hashlib.sha256((out/'native').read_bytes()).hexdigest()
 (out/'build.json').write_text(json.dumps(receipt,indent=2));print(json.dumps(receipt,indent=2));raise SystemExit(p.returncode)
