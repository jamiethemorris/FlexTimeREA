"""Bounded installed-framework tests. No DAW or audio-device access."""
from pathlib import Path
import json, os, subprocess, tempfile, unittest
ROOT=Path(__file__).resolve().parent
from build import MADSP
RUN=Path(tempfile.mkdtemp(prefix='renderer-tests-',dir=ROOT/'runtime'))
BIN=ROOT/'runtime'/'flex-render'
POLICY=ROOT/'runtime'/'sandbox.sb'

def tearDownModule():
    print('Polyphonic regression evidence:',RUN)

class NativeSmoke(unittest.TestCase):
    def test_installed_polyphonic_lifecycle(self):
        self.assertTrue(BIN.is_file(), 'standalone renderer not built')
        p=subprocess.run(['/usr/bin/sandbox-exec','-f',str(POLICY),str(BIN),'smoke'],cwd=RUN,
                         env={'PATH':'/usr/bin:/bin','HOME':str(RUN),'TMPDIR':str(RUN),'FLEX_MADSP':str(MADSP)},
                         text=True,capture_output=True,timeout=20)
        self.assertEqual(p.returncode,0,p.stderr)
        result=json.loads(p.stdout)
        self.assertTrue(result['created'])
        self.assertTrue(result['destroyed'])
        self.assertEqual(result.get('cycles'),10,'repeated lifecycle not implemented')
        self.assertEqual(result['instances_after'],result['instances_before'])

    def test_numeric_suffix_is_rejected_without_output(self):
        p=subprocess.run(['/usr/bin/sandbox-exec','-f',str(POLICY),str(BIN),'render',str(RUN/'stereo-tone.f32'),str(RUN/'must-not-write.f32'),'48000','2','1.5junk'],cwd=RUN,
             env={'PATH':'/usr/bin:/bin','HOME':str(RUN),'TMPDIR':str(RUN),'FLEX_MADSP':str(MADSP)},text=True,capture_output=True,timeout=20)
        self.assertEqual(p.returncode,2,'malformed stretch was accepted: '+p.stdout)
        self.assertIn('numeric',p.stderr)
        self.assertFalse((RUN/'must-not-write.f32').exists())

    def test_wav_cli_refuses_overwrite_and_outside_output(self):
        import wave, struct
        from offline import render_wav
        source=RUN/'refusal-input.wav'
        with wave.open(str(source),'wb') as w:
            w.setnchannels(1);w.setsampwidth(2);w.setframerate(48000);w.writeframes(struct.pack('<h',123))
        before=source.read_bytes()
        with self.assertRaisesRegex(ValueError,'different file'):
            render_wav(source,source,1)
        with self.assertRaisesRegex(ValueError,'below project runtime'):
            render_wav(source,ROOT/'outside-not-created.wav',1)
        self.assertEqual(source.read_bytes(),before)
        self.assertFalse((ROOT/'outside-not-created.wav').exists())
        other=RUN/'refusal-existing.wav';other.write_bytes(b'preserve synthetic sentinel')
        with self.assertRaisesRegex(ValueError,'overwrite'):
            render_wav(source,other,1)
        self.assertEqual(other.read_bytes(),b'preserve synthetic sentinel')

    def test_wav_cli_rejects_fifo_without_blocking(self):
        fifo=RUN/'test-input.fifo'
        if fifo.exists():fifo.unlink()
        os.mkfifo(fifo)
        try:
            try:
                p=subprocess.run([os.sys.executable,str(ROOT/'offline.py'),str(fifo)],cwd=ROOT,text=True,capture_output=True,timeout=2)
            except subprocess.TimeoutExpired:
                self.fail('WAV CLI blocked on non-regular input')
            self.assertEqual(p.returncode,2,p.stdout+p.stderr)
            self.assertIn('regular file',p.stderr)
        finally: fifo.unlink()

    def test_float_wav_cli_produces_playable_pcm(self):
        import wave, math, struct
        path=RUN/'mono-input.wav'
        with wave.open(str(path),'wb') as f:
            f.setnchannels(1);f.setsampwidth(2);f.setframerate(44100)
            f.writeframes(b''.join(struct.pack('<h',round(6000*math.sin(2*math.pi*330*i/44100))) for i in range(88217)))
        self.assertTrue((ROOT/'offline.py').is_file(),'WAV renderer not implemented')
        dest=RUN/'mono-output.wav'

        p=subprocess.run([os.sys.executable,str(ROOT/'offline.py'),str(path),'--stretch','1.5','--output',str(dest)],cwd=ROOT,text=True,capture_output=True,timeout=25)
        self.assertEqual(p.returncode,0,p.stderr)
        with wave.open(str(RUN/'mono-output.wav'),'rb') as f:
            self.assertEqual((f.getnchannels(),f.getframerate(),f.getsampwidth()),(1,44100,2))
            self.assertEqual(f.getnframes(),132326)
            self.assertEqual(len(f.readframes(f.getnframes())),132326*2)

class NativeRender(unittest.TestCase):
    def test_polyphonic_stretch_preserves_stereo_pitch(self):
        import math, struct
        rate=48000; frames=rate*3; channels=2
        source=RUN/'stereo-tone.f32'; dest=RUN/'polyphonic-1.5.f32'
        data=[v for i in range(frames) for v in (0.2*math.sin(2*math.pi*440*i/rate),0.2*math.sin(2*math.pi*660*i/rate))]
        source.write_bytes(struct.pack('<'+'f'*len(data),*data))
        p=subprocess.run(['/usr/bin/sandbox-exec','-f',str(POLICY),str(BIN),'render',str(source),str(dest),str(rate),str(channels),'1.5'],
            cwd=RUN,env={'PATH':'/usr/bin:/bin','HOME':str(RUN),'TMPDIR':str(RUN),'FLEX_MADSP':str(MADSP)},text=True,capture_output=True,timeout=20)
        self.assertEqual(p.returncode,0,p.stderr)
        report=json.loads(p.stdout)
        self.assertTrue(report['destroyed'])
        self.assertEqual(report['output_frames'],216000)
        raw=dest.read_bytes(); self.assertEqual(len(raw),216000*channels*4)
        samples=struct.unpack('<'+'f'*(len(raw)//4),raw)
        self.assertTrue(all(math.isfinite(x) for x in samples))
        metrics=[]
        for channel,target in enumerate((440,660)):
            x=samples[channel::channels]
            middle=x[rate:rate*3]
            rms=math.sqrt(sum(v*v for v in middle)/len(middle))
            self.assertGreater(rms,0.05)
            crossings=[i+(0-a)/(b-a) for i,(a,b) in enumerate(zip(middle,middle[1:])) if a<=0<b]
            hz=(len(crossings)-1)*rate/(crossings[-1]-crossings[0])
            self.assertLess(abs(hz-target),target*0.01)
            metrics.append({'channel':channel,'rms':rms,'frequency_hz':hz,'target_hz':target})
        (RUN/'first-render-metrics.json').write_text(json.dumps(metrics,indent=2)+'\n')

if __name__=='__main__': unittest.main()
