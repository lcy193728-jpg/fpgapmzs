"""Copy only the standalone module and reviewable evidence into dev_sim checkout."""
import json,re,shutil,zipfile,hashlib
from pathlib import Path
root=Path(__file__).resolve().parents[1]
dest=Path('D:/fpga_work/fpgapmzs/meeting_scene3_sim')
dest.mkdir(exist_ok=True)
for name in ['rtl','tb','tools','assets','baseline']:
    shutil.copytree(root/name,dest/name,dirs_exist_ok=True,ignore=shutil.ignore_patterns('__pycache__'))
for name in ['.gitattributes','README.md','run.do','run_checks.do','run_display.do']:
    shutil.copy2(root/name,dest/name)
evidence=dest/'evidence';evidence.mkdir(exist_ok=True)
summary=[]
for run in sorted((root/'runs').iterdir()):
    if not run.is_dir(): continue
    out=evidence/run.name;out.mkdir(exist_ok=True)
    log=run/'transcript.log';txt=log.read_text(errors='replace') if log.exists() else ''
    results=re.findall(r'RESULT checks=(\d+) errors=(\d+)',txt)
    status='passed' if results and all(int(x[1])==0 for x in results) and 'ALL TESTS PASSED' in txt else 'incomplete_or_compile_failed'
    for p in run.glob('*.png'):
        if p.name=='gui_debug.png': continue
        shutil.copy2(p,out/p.name)
    if log.exists():shutil.copy2(log,out/log.name)
    wave=run/'meeting.wlf'
    archive_wave=wave.exists() and run.name in {'20260917_163058_full','20260917_162950_edges','20260917_163002_io','20260917_163221_display'}
    if archive_wave:
        with zipfile.ZipFile(out/'waveform.zip','w',compression=zipfile.ZIP_DEFLATED,compresslevel=9) as z:z.write(wave,'meeting.wlf')
    elif (out/'waveform.zip').exists():
        (out/'waveform.zip').unlink() # Only this task's generated redundant archive.
    note={'run':run.name,'status':status,'checks':int(results[-1][0]) if results else 0,
          'errors':int(results[-1][1]) if results else None,'waveform_present':wave.exists(),
          'wave_screenshot_present':(run/'wave_full.png').exists()}
    note['waveform_archived_in_repository']=archive_wave
    if run.name=='20260917_162609':note['note']='Interrupted run; WLF was not closed cleanly. Partial process record only.'
    if not wave.exists():note['note']='Compilation failed before elaboration, so no waveform exists; original error log retained.'
    (out/'status.json').write_text(json.dumps(note,indent=2)+'\n')
    summary.append(note)
(evidence/'manifest.json').write_text(json.dumps(summary,indent=2)+'\n')
# File hashes allow a teammate to verify the transferred simulation package.
hashes={str(p.relative_to(dest)).replace('\\','/'):hashlib.sha256(p.read_bytes()).hexdigest()
        for p in dest.rglob('*') if p.is_file() and p.name!='SHA256SUMS.json'}
(dest/'SHA256SUMS.json').write_text(json.dumps(hashes,indent=2)+'\n')
print(f'{len(hashes)} files packaged in {dest}')
