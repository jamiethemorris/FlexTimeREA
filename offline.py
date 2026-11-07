#!/usr/bin/env python3
"""Bounded Flex Time PCM16 WAV renderer using the installed MADSP (no DAW).

All generated files live below runtime/. Native execution is sandboxed and
limited to 20 seconds per invocation. Requires `python3 build.py` first.
"""
from pathlib import Path
from array import array
import argparse, hashlib, json, math, os, stat, subprocess, sys, tempfile, wave
from build import EXPECTED, MADSP, ROOT, RUN, POLICY

MODES=('polyphonic','speed','tempophone','rhythmic','slicing')
UNSUPPORTED={'monophonic':'monophonic unsupported: requires native pitch-analysis provider; its data ABI is not recovered'}

def render_wav(source, output=None, stretch=1.0, block=1024, mode='polyphonic', transients=None):
    if mode in UNSUPPORTED: raise ValueError(UNSUPPORTED[mode])
    if mode not in MODES: raise ValueError('unsupported mode: '+str(mode))
    source=Path(source).resolve(strict=True)
    if not math.isfinite(stretch) or not 0.5<=stretch<=2:
        raise ValueError('stretch must be finite and in 0.5..2 (output/input duration)')
    if type(block) is not int or not 1<=block<=1024:
        raise ValueError('block must be an integer in 1..1024')
    if hashlib.sha256(MADSP.read_bytes()).hexdigest()!=EXPECTED:
        raise ValueError('MADSP identity changed; rerun static ABI validation')
    if not POLICY.is_file() or not (RUN/'flex-render').is_file():
        raise ValueError('run python3 build.py first')
    if output is not None:
        output=Path(output).resolve()
        if not output.is_relative_to(RUN.resolve()) or output==source:
            raise ValueError('output must be a different file below project runtime/')
        if output.exists(): raise ValueError('refusing to overwrite existing output')
    if not source.is_file(): raise ValueError('input must be a regular file')
    # Nonblocking open + descriptor type check rejects FIFOs/devices even if the
    # path is replaced after resolution. No decoder sees a non-regular stream.
    with os.fdopen(os.open(source,os.O_RDONLY|os.O_NONBLOCK|os.O_NOFOLLOW),'rb') as input_file:
        if not stat.S_ISREG(os.fstat(input_file.fileno()).st_mode):
            raise ValueError('input must be a regular file')
        with wave.open(input_file,'rb') as w:
            channels,rate,width,frames=w.getnchannels(),w.getframerate(),w.getsampwidth(),w.getnframes()
            if channels not in (1,2) or rate not in (44100,48000) or width!=2 or w.getcomptype()!='NONE':
                raise ValueError('input must be uncompressed PCM16 WAV, mono/stereo, 44100/48000 Hz')
            if not 1<=frames<=rate*30: raise ValueError('input must contain 1 frame through 30 seconds')
            pcm=w.readframes(frames)
            if len(pcm)!=frames*channels*width: raise ValueError('truncated WAV data')
    values=array('h');values.frombytes(pcm)
    transients=[] if transients is None else transients
    if (not isinstance(transients,(list,tuple)) or len(transients)>4096 or
        any(type(t) is not int or not 0<t<frames for t in transients) or
        any(a>=b for a,b in zip(transients,transients[1:]))):
        raise ValueError('transients must be up to 4096 strictly increasing integer frames inside input')
    if mode in ('rhythmic','slicing') and not transients:
        raise ValueError('rhythmic/slicing requires explicit source transient frames')
    if mode not in ('rhythmic','slicing') and transients:
        raise ValueError('transients are only supported for rhythmic/slicing')
    bounds=[0,*transients,frames]
    mapped=[math.floor(t*stretch+0.5) for t in bounds]
    if any(a>=b for a,b in zip(mapped,mapped[1:])):
        raise ValueError('transient map collapses an output interval')
    if sys.byteorder!='little':values.byteswap()
    floats=array('f',(x/32768.0 for x in values))
    if sys.byteorder!='little':floats.byteswap()
    job=Path(tempfile.mkdtemp(prefix='render-',dir=RUN))
    input_raw=job/'input.f32'; output_raw=job/'output.f32'
    input_raw.write_bytes(floats.tobytes())
    command=['/usr/bin/sandbox-exec','-f',str(POLICY),str(RUN/'flex-render'),'render',
             str(input_raw),str(output_raw),str(rate),str(channels),str(stretch),str(block),mode]
    if transients:command.append(','.join(map(str,transients)))
    env={'PATH':'/usr/bin:/bin','HOME':str(job),'TMPDIR':str(job),'FLEX_MADSP':str(MADSP)}
    try:
        p=subprocess.run(command,cwd=job,env=env,text=True,capture_output=True,timeout=20)
        report={'command':command,'returncode':p.returncode,'stdout':p.stdout,'stderr':p.stderr}
    except subprocess.TimeoutExpired as e:
        (job/'failure.json').write_text(json.dumps({'error':'native deadline exceeded','timeout_seconds':20})+'\n')
        raise RuntimeError('native render exceeded 20 seconds; child killed and reaped') from e
    (job/'native.json').write_text(json.dumps(report,indent=2)+'\n')
    if p.returncode: raise RuntimeError(f'native renderer exited {p.returncode}: {p.stderr.strip()} (evidence {job})')
    native=json.loads(p.stdout)
    expected=math.floor(frames*stretch+0.5)
    raw=output_raw.read_bytes()
    if len(raw)!=expected*channels*4:raise RuntimeError('native output length mismatch')
    samples=array('f');samples.frombytes(raw)
    if sys.byteorder!='little':samples.byteswap()
    if not all(math.isfinite(x) for x in samples):raise RuntimeError('native output contains nonfinite samples')
    clipped=sum(abs(x)>=1 for x in samples)
    pcmout=array('h',(max(-32768,min(32767,round(x*32768))) for x in samples))
    if sys.byteorder!='little':pcmout.byteswap()
    output=output or job/'output.wav'
    # Exclusive creation makes user-facing WAV output non-destructive.
    with output.open('xb') as f:
        with wave.open(f,'wb') as w:
            w.setnchannels(channels);w.setsampwidth(2);w.setframerate(rate);w.writeframes(pcmout.tobytes())
    with wave.open(str(output),'rb') as w:
        if (w.getnchannels(),w.getframerate(),w.getnframes())!=(channels,rate,expected):
            raise RuntimeError('finalized WAV verification failed')
        if len(w.readframes(expected))!=expected*channels*2:raise RuntimeError('finalized WAV is truncated')
    summary={'mode':mode,'input':str(source),'output':str(output),'job':str(job),
             'sample_rate':rate,'channels':channels,'input_frames':frames,'output_frames':expected,
             'stretch':stretch,'transients':transients,'clipped_samples':clipped,'native':native,'sha256':hashlib.sha256(output.read_bytes()).hexdigest()}
    (job/'result.json').write_text(json.dumps(summary,indent=2)+'\n')
    return summary

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input',type=Path)
    parser.add_argument('--output',type=Path,help='new WAV below project runtime/; default unique job output.wav')
    parser.add_argument('--stretch',type=float,default=1.0,help='output/input duration, 0.5 through 2')
    parser.add_argument('--block',type=int,default=1024)
    parser.add_argument('--mode',choices=(*MODES,*UNSUPPORTED),default='polyphonic')
    parser.add_argument('--transients',type=int,nargs='+',help='explicit increasing source onset frames (rhythmic/slicing)')
    args=parser.parse_args()
    try: print(json.dumps(render_wav(args.input,args.output,args.stretch,args.block,args.mode,args.transients),indent=2))
    except (OSError,ValueError,RuntimeError,wave.Error) as e:
        print(f'offline.py: {e}',file=sys.stderr);return 2
    return 0
if __name__=='__main__':raise SystemExit(main())
