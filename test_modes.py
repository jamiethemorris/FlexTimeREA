"""Real installed-MADSP mode tests, synthetic audio only; retained unique jobs."""
from array import array
from pathlib import Path
import json, math, statistics, subprocess, tempfile, unittest, wave
from build import RUN, MADSP
from offline import render_wav


def tone(rate, frames, channels=2):
    return [v for i in range(frames) for v in
            ([0.2*math.sin(2*math.pi*440*i/rate),
              0.2*math.sin(2*math.pi*660*i/rate)][:channels])]


def wav(path, samples, rate, channels):
    pcm=array('h',(round(x*32767) for x in samples))
    with path.open('xb') as f:
        with wave.open(f,'wb') as w:
            w.setnchannels(channels);w.setsampwidth(2);w.setframerate(rate)
            w.writeframes(pcm.tobytes())


def read_float(report):
    a=array('f');a.frombytes((Path(report['job'])/'output.f32').read_bytes())
    return a


def frequency(x, rate):
    crossings=[i-a/(b-a) for i,(a,b) in enumerate(zip(x,x[1:])) if a<=0<b]
    if len(crossings)<3:raise AssertionError('insufficient tone crossings')
    return (len(crossings)-1)*rate/(crossings[-1]-crossings[0])


class Modes(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root=Path(tempfile.mkdtemp(prefix='mode-tests-',dir=RUN))
        cls.reports=[]

    @classmethod
    def tearDownClass(cls):
        (cls.root/'reports.json').write_text(json.dumps(cls.reports,indent=2)+'\n')
        print('Mode evidence:',cls.root)

    def test_rhythmic_moves_explicit_percussion_slices(self):
        self.check_percussion_slices('rhythmic')

    def test_slicing_moves_attacks_without_varispeed(self):
        self.check_percussion_slices('slicing')

    def check_percussion_slices(self, mode):
        rate=48000;frames=rate*4+17
        source=self.root/(mode+'-input.wav');starts=[rate//2,rate*3//2,rate*5//2]
        samples=[]
        for i in range(frames):
            age=next((i-t for t in starts if 0<=i-t<rate//12),None)
            v=0 if age is None else 0.4*math.exp(-age/(rate*.025))*math.sin(2*math.pi*440*age/rate)
            samples.extend((v,0))
        wav(source,samples,rate,2)
        for stretch in (0.75,1.5):
            with self.subTest(stretch=stretch):
                r=render_wav(source,stretch=stretch,block=257,mode=mode,transients=starts)
                self.reports.append(r);a=read_float(r)
                self.assertTrue(all(math.isfinite(v) for v in a))
                self.assertEqual(max(abs(v) for v in a[1::2]),0)
                x=a[::2];step=240
                active=[i/rate for i in range(0,len(x)-step,step)
                        if math.sqrt(sum(v*v for v in x[i:i+step])/step)>.02]
                groups=[]
                for t in active:
                    if not groups or t-groups[-1][-1]>.01:groups.append([])
                    groups[-1].append(t)
                self.assertEqual(len(groups),3)
                onsets=[g[0] for g in groups];r['measured_onsets']=onsets
                for actual,t in zip(onsets,starts):self.assertLess(abs(actual-t/rate*stretch),.02)
                # Fixed-frequency local attack, not a rate-changed copy.
                for t in starts:
                    offset=round(t*stretch)
                    mid=x[offset+480:offset+2400]
                    self.assertLess(abs(frequency(mid,rate)-440),2.2)

    def test_supported_mode_rate_channel_bounds_and_silence(self):
        for mode in ('speed','tempophone','rhythmic','slicing'):
            for rate in (44100,48000):
                for channels in (1,2):
                    frames=rate+37
                    source=self.root/f'{mode}-{rate}-{channels}-matrix.wav'
                    values=tone(rate,frames,channels)
                    if channels==2:values[1::2]=[0]*frames
                    wav(source,values,rate,channels)
                    cuts=[frames//3,2*frames//3] if mode in ('rhythmic','slicing') else None
                    for stretch in (0.5,1,2):
                        with self.subTest(mode=mode,rate=rate,channels=channels,stretch=stretch):
                            r=render_wav(source,stretch=stretch,block=64,mode=mode,transients=cuts)
                            self.reports.append(r);a=read_float(r)
                            self.assertEqual(len(a),math.floor(frames*stretch+0.5)*channels)
                            self.assertTrue(all(math.isfinite(v) for v in a))
                            self.assertTrue(r['native']['destroyed'])
                            self.assertEqual(r['clipped_samples'],0)
                            self.assertGreater(max(abs(v) for v in a[::channels]),.05)
                            if channels==2:self.assertEqual(max(abs(v) for v in a[1::2]),0)
                source=self.root/f'{mode}-{rate}-silence.wav'
                wav(source,[0]*(rate+17),rate,1)
                r=render_wav(source,stretch=2,mode=mode,
                             transients=[rate//2] if mode in ('rhythmic','slicing') else None)
                self.reports.append(r)
                self.assertEqual(max(abs(v) for v in read_float(r)),0)

    def test_monophonic_refuses_with_analysis_barrier(self):
        source=self.root/'mono-refusal.wav';wav(source,[0]*64,48000,1)
        with self.assertRaisesRegex(ValueError,'pitch.analysis'):
            render_wav(source,mode='monophonic')

    def test_invalid_transients_refuse_before_native_job(self):
        source=self.root/'bad-transients.wav';wav(source,[0]*64,48000,1)
        before=set(RUN.glob('render-*'))
        for cuts in ([True],[1.0],[-1],[0],[64],[4,4],[5,4],[1]*4097,'4',[],[1,2]):
            with self.subTest(cuts=str(cuts)[:50]):
                with self.assertRaises(ValueError):
                    render_wav(source,mode='slicing',transients=cuts,stretch=.5)
        with self.assertRaises(ValueError):render_wav(source,mode='speed',transients=[4])
        self.assertEqual(before,set(RUN.glob('render-*')))

    def test_native_output_never_overwrites(self):
        from build import POLICY
        source=self.root/'exclusive-input.f32';source.write_bytes(array('f',[0]*512).tobytes())
        dest=self.root/'exclusive-sentinel.f32';dest.write_bytes(b'preserve this synthetic output')
        command=['/usr/bin/sandbox-exec','-f',str(POLICY),str(RUN/'flex-render'),'render',
                 str(source),str(dest),'48000','1','1','64','speed']
        p=subprocess.run(command,cwd=self.root,env={'PATH':'/usr/bin:/bin','HOME':str(self.root),'FLEX_MADSP':str(MADSP),
                         'TMPDIR':str(self.root)},capture_output=True,text=True,timeout=20)
        self.assertEqual(p.returncode,2,p.stdout+p.stderr)
        self.assertEqual(dest.read_bytes(),b'preserve this synthetic output')

    def test_native_mode_and_transient_rejections(self):
        from build import POLICY
        source=self.root/'native-rejections.f32';source.write_bytes(array('f',[0]*64).tobytes())
        cases=[('unknown',None),('monophonic',None),('rhythmic',None),('slicing',None),
               ('speed','4'),('slicing','0'),('slicing','64'),('slicing','5,4'),
               ('slicing','4,4'),('slicing','4,'),('slicing','-1'),('slicing','1.0'),
               ('slicing','NaN'),('slicing','9999999999999999999999999999999999999999')]
        for index,(mode,csv) in enumerate(cases):
            dest=self.root/f'native-reject-{index}.f32'
            command=['/usr/bin/sandbox-exec','-f',str(POLICY),str(RUN/'flex-render'),'render',
                     str(source),str(dest),'48000','1','1','64',mode]
            if csv is not None:command.append(csv)
            p=subprocess.run(command,cwd=self.root,env={'PATH':'/usr/bin:/bin','HOME':str(self.root),'FLEX_MADSP':str(MADSP),
                             'TMPDIR':str(self.root)},capture_output=True,text=True,timeout=20)
            self.assertEqual(p.returncode,2,p.stdout+p.stderr)
            self.assertFalse(dest.exists())

    def test_short_sources_stay_bounded_and_finite(self):
        for mode in ('speed','tempophone','rhythmic','slicing'):
            for frames in ((1,17) if mode in ('speed','tempophone') else (3,17)):
                source=self.root/f'{mode}-short-{frames}.wav'
                wav(source,[0.1]*frames,48000,1)
                for stretch in (.5,2):
                    r=render_wav(source,stretch=stretch,block=1,mode=mode,
                                 transients=[1] if mode in ('rhythmic','slicing') else None)
                    self.reports.append(r);a=read_float(r)
                    self.assertTrue(all(math.isfinite(v) for v in a))
                    self.assertEqual(len(a),math.floor(frames*stretch+.5))

    def test_tempophone_preserves_carrier_and_moves_gates(self):
        rate=48000;frames=rate*4+17
        source=self.root/'tempophone-input.wav'
        samples=[v if (0.5<=i/rate<1 or 2<=i/rate<2.5) else 0
                 for i in range(frames) for v in
                 (0.2*math.sin(2*math.pi*440*i/rate),
                  0.2*math.sin(2*math.pi*660*i/rate))]
        wav(source,samples,rate,2)
        for stretch in (0.75,1.5):
            with self.subTest(stretch=stretch):
                r=render_wav(source,stretch=stretch,block=257,mode='tempophone')
                self.reports.append(r);a=read_float(r)
                self.assertEqual(r['output_frames'],math.floor(frames*stretch+0.5))
                self.assertTrue(all(math.isfinite(x) for x in a))
                for c,target in enumerate((440,660)):
                    x=a[c::2]
                    mid=x[round(rate*0.6*stretch):round(rate*0.9*stretch)]
                    self.assertGreater(math.sqrt(sum(v*v for v in mid)/len(mid)),0.05)
                    # Grain discontinuities add crossings/sidebands: estimate
                    # median local period, not whole-window zero-crossing rate.
                    crossings=[i-v/(w-v) for i,(v,w) in enumerate(zip(mid,mid[1:])) if v<=0<w]
                    hz=statistics.median(rate/(b-a) for a,b in zip(crossings,crossings[1:]))
                    self.assertLess(abs(hz-target),target*0.02)
                # Windows are measured, not inferred from the output file size.
                x=a[::2];step=480
                active=[i/ rate for i in range(0,len(x)-step,step)
                        if math.sqrt(sum(v*v for v in x[i:i+step])/step)>0.025]
                groups=[]
                for t in active:
                    if not groups or t-groups[-1][-1]>0.015:groups.append([])
                    groups[-1].append(t)
                self.assertEqual(len(groups),2)
                windows=[(g[0],g[-1]+step/rate) for g in groups]
                r['active_windows']=windows
                for actual,expected in zip(windows,[(0.5*stretch,stretch),(2*stretch,2.5*stretch)]):
                    for got,want in zip(actual,expected):self.assertLess(abs(got-want),0.1)

    def test_speed_pitch_tracks_inverse_duration(self):
        rate=48000;frames=rate*3+19
        source=self.root/'speed-input.wav';wav(source,tone(rate,frames),rate,2)
        for stretch in (0.5,1.5,2):
            with self.subTest(stretch=stretch):
                r=render_wav(source,stretch=stretch,block=257,mode='speed')
                self.reports.append(r)
                self.assertEqual(r['mode'],'speed')
                self.assertEqual(r['output_frames'],math.floor(frames*stretch+0.5))
                self.assertTrue(r['native']['destroyed'])
                a=read_float(r);self.assertTrue(all(math.isfinite(x) for x in a))
                metrics=[]
                for c,target in enumerate((440/stretch,660/stretch)):
                    x=a[c::2];middle=x[len(x)//4:len(x)*3//4]
                    rms=math.sqrt(sum(v*v for v in middle)/len(middle))
                    self.assertGreater(rms,0.1)
                    hz=frequency(middle,rate)
                    self.assertLess(abs(hz-target),target*0.005)
                    metrics.append({'frequency_hz':hz,'target_hz':target,'rms':rms})
                r['measurements']=metrics


if __name__=='__main__':unittest.main()
