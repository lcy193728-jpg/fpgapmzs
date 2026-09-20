"""Host-side arithmetic/constants checks only. NOT RTL simulation or board proof."""
from pathlib import Path
import json, math, random, re
ROOT=Path(__file__).resolve().parents[2]
rtl=ROOT/'audio_board/rtl'
s=(rtl/'pcm_media_tone.v').read_text()
expected={'PH_BLIP':134217728,'PH_A4':39370534,'PH_C5':46819617,
 'PH_D5':52553399,'PH_E5':58988691,'PH_G5':70150238,'PH_A5':78741067,
 'PH_C6':93639235,'PH_ALM_LO':71582788,'PH_ALM_HI':107374182}
for name,val in expected.items():
 assert re.search(r'\b'+name+r'\s*=\s*'+str(val)+r'\b',s),name
rom={(a,b):c for a,b,c in re.findall(r"5'b([01]{2})_([01]{3}):note_phase=(PH_\w+)",s)}
sequences=[['PH_C5','PH_E5','PH_G5','PH_C6','PH_G5','PH_E5'],
 ['PH_A4','PH_C5','PH_E5','PH_A5','PH_E5','PH_C5'],
 ['PH_C5','PH_D5','PH_E5','PH_G5','PH_A5','PH_C6']]
for scene,seq in enumerate(sequences):
 assert [rom[(f'{scene:02b}',f'{i:03b}')] for i in range(6)]==seq
# Fractional accumulator gives precisely 48,000 ticks over 25,000,000 clocks.
acc=ticks=0
for _ in range(25000000):
 if acc>=25000000-48000: acc+=48000-25000000;ticks+=1
 else:acc+=48000
assert ticks==48000 and acc==0
# Signed shift/add matches exact floor interpolation for every gain including 256.
rng=random.Random(20260918)
cases=0
for gain in range(257):
 for test,media in [(4096,16384),(-4096,16384),(4096,-16384),(-4096,-16384),
                    (0,0)]+[(rng.randrange(-4096,4097),rng.randrange(-16384,16385)) for _ in range(200)]:
  diff=media-test;term=diff;acc=0;weight=gain
  for _ in range(9):
   if weight&1:acc+=term
   weight>>=1;term*=2
  out=test+(acc>>8)
  assert out==test+((media-test)*gain//256)
  assert min(test,media)<=out<=max(test,media)
  assert -16384<=out<=16384
  if gain==0:assert out==test
  if gain==256:assert out==media
  cases+=1
volume_cases=0
for volume in (0,32,64,128,200,256):
 for value in range(-16384,16385,127):
  total=0;term=value
  for b in range(9):
   if (volume>>b)&1:total+=term
   term*=2
  assert total//256==value*volume//256
  assert -16384<=total//256<=16384
  volume_cases+=1
for duration in (4800,12000,24000):
 env=[min(age+1,duration-age,256) for age in range(duration)]
 assert len(env)==duration and env[:256]==list(range(1,257))
 assert env[-256:]==list(range(256,0,-1))
 assert max(env)==256
report={'check_type':'host_math_only_not_RTL_simulation','fractional_ticks_per_second':ticks,
 'interpolation_cases':cases,'compile_volume_cases':volume_cases,'blip_samples':4800,'note_samples':12000,
 'melody_notes':6,'melody_repetitions':2,'blip_plus_melody_seconds':3.1,
 'alarm_half_samples':24000,'ramp_samples':256,
 'phase_constants':expected,'sequences':sequences}
(ROOT/'audio_board/reports/media_math_checks.json').write_text(json.dumps(report,indent=2)+'\n')
print('Host arithmetic checks passed:',cases,'interpolation cases; this is not RTL simulation.')
