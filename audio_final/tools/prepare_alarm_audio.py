from pathlib import Path
import hashlib, json
import numpy as np
import soundfile as sf
from scipy.signal import resample_poly

SRC = Path(r"D:\App\QQMusic\铃声 - 防空警报_L.ogg")
ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "assets"
ASSETS.mkdir(parents=True, exist_ok=True)
RATE = 4000
SECONDS = 7

STEP = np.array([7,8,9,10,11,12,13,14,16,17,19,21,23,25,28,31,34,37,41,45,50,55,60,66,73,80,88,97,107,118,130,143,157,173,190,209,230,253,279,307,337,371,408,449,494,544,598,658,724,796,876,963,1060,1166,1282,1411,1552,1707,1878,2066,2272,2499,2749,3024,3327,3660,4026,4428,4871,5358,5894,6484,7132,7845,8630,9493,10442,11487,12635,13899,15289,16818,18500,20350,22385,24623,27086,29794,32767], dtype=np.int32)
ADJ = np.array([-1,-1,-1,-1,2,4,6,8], dtype=np.int32)

def encode(samples):
    pred=0; idx=0; n=[]; decoded=[]
    for target in samples.astype(np.int32):
        step=int(STEP[idx]); diff=int(target)-pred; code=0
        if diff < 0: code=8; diff=-diff
        delta=step>>3
        if diff>=step: code|=4; diff-=step; delta+=step
        if diff>=(step>>1): code|=2; diff-=step>>1; delta+=step>>1
        if diff>=(step>>2): code|=1; delta+=step>>2
        pred += -delta if code&8 else delta
        pred=max(-32768,min(32767,pred))
        idx=max(0,min(88,idx+int(ADJ[code&7])))
        n.append(code); decoded.append(pred)
    packed=bytearray((len(n)+1)//2)
    for i,c in enumerate(n):
        if i&1: packed[i//2] |= c<<4
        else: packed[i//2]=c
    return bytes(packed), np.array(decoded,dtype=np.int16)

audio, sr = sf.read(SRC, dtype='float32', always_2d=True)
source_mono=audio[:min(len(audio),sr*SECONDS)].mean(axis=1)
source_mono-=float(np.mean(source_mono))
def make_mono(rate):
    mono=resample_poly(source_mono, rate, sr).astype(np.float32)[:rate*SECONDS]
    mono*=0.80/(float(np.max(np.abs(mono))) or 1.0)
    fade=min(rate*3//100,len(mono)//4)
    mono[:fade]*=np.linspace(0,1,fade,dtype=np.float32)
    mono[-fade:]*=np.linspace(1,0,fade,dtype=np.float32)
    return mono

mono=make_mono(RATE)
pcm=np.clip(np.rint(mono*32767),-32768,32767).astype('<i2')
adpcm, decoded=encode(pcm)
(ASSETS/'alarm_4k_adpcm.hex').write_text('\n'.join(f'{b:02x}' for b in adpcm)+'\n',encoding='ascii')
bram_depth=16384
(ASSETS/'alarm_4k_adpcm.dath').write_text(
    '\n'.join(f'{b:02x}' for b in adpcm) + '\n' +
    '00\n' * (bram_depth-len(adpcm)), encoding='ascii')
(ASSETS/'alarm_4k_reference.pcm').write_bytes(pcm.tobytes())
sf.write(ASSETS/'alarm_4k_reference.wav',pcm,RATE,subtype='PCM_16')
pcm_rate=3000
pcm_mono=make_mono(pcm_rate)
pcm8=np.clip(np.rint(pcm_mono*127),-128,127).astype(np.int8)
pcm_depth=21504
pcm_bytes=pcm8.view(np.uint8).tobytes()
(ASSETS/'alarm_3k_pcm8.raw').write_bytes(pcm_bytes)
(ASSETS/'alarm_3k_pcm8.dath').write_text(
    '\n'.join(f'{b:02x}' for b in pcm_bytes)+'\n'+'00\n'*(pcm_depth-len(pcm_bytes)),
    encoding='ascii')
sf.write(ASSETS/'alarm_3k_pcm8_reference.wav',pcm8.astype(np.int16)<<8,pcm_rate,subtype='PCM_16')
sf.write(ASSETS/'alarm_3k_pcm8_board_48k.wav',
         np.repeat(pcm8.astype(np.int16)<<8,16),48000,subtype='PCM_16')
meta={
 'source':str(SRC),'source_sha256':hashlib.sha256(SRC.read_bytes()).hexdigest(),
 'source_rate':sr,'source_channels':audio.shape[1],'clip_seconds':SECONDS,
 'stored_rate':RATE,'samples':len(pcm),'adpcm_bytes':len(adpcm),'bram_depth':bram_depth,
 'adpcm_sha256':hashlib.sha256(adpcm).hexdigest(),
 'decoded_snr_db':float(10*np.log10(np.mean(pcm.astype(float)**2)/(np.mean((pcm.astype(float)-decoded.astype(float))**2)+1e-9))),
 'active_format':'signed PCM8','active_rate':pcm_rate,'active_samples':len(pcm8),
 'active_bram_depth':pcm_depth,'active_sha256':hashlib.sha256(pcm_bytes).hexdigest()
}
(ASSETS/'alarm_audio.json').write_text(json.dumps(meta,ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps(meta,ensure_ascii=False,indent=2))
