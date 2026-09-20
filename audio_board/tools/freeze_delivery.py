"""Collect real TD evidence and bitstreams; refuse errors or negative routed slack.
No simulation, no programming hardware. Requires git and successful build.ps1 runs.
"""
from pathlib import Path
import hashlib
import json
import re
import shutil
import subprocess

ROOT=Path(__file__).resolve().parents[2]
BOARD=ROOT/'audio_board'
BASE='6586b66447375c1c4dfc9568b17a79df889cfbae'


def git(*args):
    return subprocess.check_output(['git','-C',str(ROOT),*args])


def main():
    # Compare the actual baseline blob; tolerate checkout newline conversion.
    baseline={}
    for entry in git('ls-tree','-r','-z',BASE).split(b'\0'):
        if not entry:continue
        meta,path=entry.split(b'\t',1)
        p=path.decode('utf-8')
        if not (p.startswith(('src/','al_ip/')) or p in ('pic_sdram.al','top.adc','top.sdc')):continue
        expected=meta.split()[2].decode()
        blob=git('show',BASE+':'+p)
        working=(ROOT/p).read_bytes()
        if blob.replace(b'\r\n',b'\n')!=working.replace(b'\r\n',b'\n'):
            raise RuntimeError('Baseline file changed: '+p)
        baseline[p]=expected
    vendor=json.loads((BOARD/'vendor/SHA256.json').read_text())
    for p,digest in vendor.items():
        assert hashlib.sha256((BOARD/'vendor'/p).read_bytes()).hexdigest()==digest,p
    for p in ('hdmi_audio_acr_packetizer','hdmi_audio_infoframe_packetizer','hdmi_audio_packet_scheduler',
              'hdmi_audio_sample_packetizer','hdmi_bch8','hdmi_data_island_mapper',
              'hdmi_data_island_scheduler','hdmi_terc4_encoder','hdmi_tmds_channel_encoder'):
        assert (BOARD/'vendor'/f'{p}.v').read_bytes()==(BOARD/'rtl'/f'{p}.v').read_bytes(),p
    # Byte-level sanity checks of added AVI and fixed Audio InfoFrame checksum.
    assert sum((0x82,2,13,0x57,0,0x10,8))%256==0
    assert sum((0x84,1,10,0x70,1))%256==0
    arts=BOARD/'artifacts';reports=BOARD/'reports'
    arts.mkdir(exist_ok=True);reports.mkdir(exist_ok=True)
    results={}
    for target,name in [('tone','hdmi_tone'),('integrated','pic_sdram_audio')]:
        build=BOARD/'build'/target
        log=(build/'build-output.txt').read_text(encoding='utf-8-sig',errors='replace')
        if 'AUDIO_BUILD_COMPLETE:' not in log or re.search(r'ERROR:',log):
            raise RuntimeError('Incomplete/failed TD build: '+target)
        timing=(build/(name+'_pr.timing')).read_text(errors='replace')
        area=(build/(name+'_phy.area')).read_text(errors='replace')
        slack={k:float(re.search(k+r':\s*(-?[0-9.]+)ns',timing)[1]) for k in ('SWNS','HWNS')}
        if min(slack.values())<0:raise RuntimeError('Negative routed slack: '+target)
        utilization={k:int(re.search(r'^#'+k+r'\s+(\d+)',area,re.M)[1]) for k in ('lut','reg','bram','dsp','pll')}
        warnings=[l for l in log.splitlines() if 'WARNING:' in l or 'CRITICAL-WARNING:' in l]
        results[target]={'routed_slack_ns':slack,'utilization':utilization,'warning_messages':warnings,
                         'bit_sha256':hashlib.sha256((build/(name+'.bit')).read_bytes()).hexdigest()}
        shutil.copyfile(build/(name+'.bit'),arts/(name+'.bit'))
        shutil.copyfile(build/'build-output.txt',reports/(target+'_build-output.txt'))
        for suffix,filename in [('_pr.timing','postroute-timing'),('_phy.area','resources-io'),
                                 ('_exception.timing','timing-exceptions')]:
            shutil.copyfile(build/(name+suffix),reports/(target+'_'+filename+'.txt'))
    (arts/'SHA256SUMS.json').write_text(json.dumps({name+'.bit':results[t]['bit_sha256'] for t,name in
        [('tone','hdmi_tone'),('integrated','pic_sdram_audio')]},indent=2)+'\n')
    (reports/'build_summary.json').write_text(json.dumps({'baseline':BASE,'td_version':'6.2.168116',
        'simulation_run':False,'hardware_tested':False,'previous_bottom_layer_hardware_pass_reported_by_user':True,'results':results},ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    (reports/'baseline_git_blobs.json').write_text(json.dumps(baseline,indent=2)+'\n')
    # LF-normalized source snapshot so Git autocrlf does not invalidate it.
    paths=[ROOT/p for p in baseline]
    paths += [p for p in BOARD.rglob('*') if p.is_file() and 'build' not in p.parts and
              p.suffix in ('.v','.vh','.al','.sdc','.adc','.inc')]
    paths += [ROOT/'pic_sdram_audio.al']
    snapshot={p.relative_to(ROOT).as_posix():hashlib.sha256(p.read_bytes().replace(b'\r\n',b'\n')).hexdigest() for p in sorted(set(paths))}
    (reports/'source_sha256_lf.json').write_text(json.dumps(snapshot,indent=2)+'\n')
    rows=['# 验证记录','',f'基线 main `{BASE}`；TD EDA 6.2.168116，器件 EG4S20BG256。',
          '', '**实际执行：综合、布局布线、最终静态时序分析、比特流生成。未运行 ModelSim，未连接开发板下载或试听。**',
          '', '| 工程 | Setup WNS(ns) | Hold WNS(ns) | LUT | FF | BRAM9K | DSP | PLL |',
          '|---|---:|---:|---:|---:|---:|---:|---:|']
    for target in results:
        r=results[target];s=r['routed_slack_ns'];u=r['utilization']
        rows.append(f"| {target} | {s['SWNS']:.3f} | {s['HWNS']:.3f} | {u['lut']} | {u['reg']} | {u['bram']} | {u['dsp']} | {u['pll']} |")
    rows += ['', '两个工程最终 Setup/Hold 均非负，成功生成 bit；不是零 warning。',
        'pixel→serial 同源相关时钟路径参与真实 STA，没有 false-path 掩盖。',
        '', f'逐一核对 {len(baseline)} 个基线 RTL/IP/工程/约束文件的 Git blob，与 main 相同。',
        '14 份教程原件哈希一致，9 份直接复用协议文件逐字节一致；附加 AVI/Audio InfoFrame 校验和核对通过。',
        'PowerShell 脚本语法检查、Python 生成器语法检查通过。下载脚本仅做语法检查，没有在硬件执行。',
        '', '## 实际限制与警告', '',
        '- 集成版 DSP 为 29/29，后续加入乘法型音量、频谱等功能前需做资源优化。',
        '- 独立版查找表推断的 ROM 存在未使用 B 端口/写使能绑零的 SYN-5011，及匿名网命名警告，完整日志保留。',
        '- 集成日志还包含基线 IP/RTL 的位宽、未使用端口和 SDRAM 映射警告。PHY-5079 指向 ext_mem_clk_sft / U3/u2_ram/SDRAM_CLK；SDRAM 单元位置重定位也有 CRITICAL-WARNING。',
        '- 这些警告不作为已证明无影响的结论；队友需同时验证原图、缩放、TF 卡及长时间运行，见 README。',
        '- 25 MHz 对应约 59.524 Hz，沿用原视频时钟；未做 EDID/DDC/HPD 协商，接收器兼容性尚待实测。',
        '- 布线时序余量较小，修改或重新布局后必须重新检查，不以旧报告代替。',
        '- 本版已接入三种场景旋律、切图提示音与应急报警音；未实现WAV读取/语音，新增联动功能待队友实机验收。',
        '- 用户确认上一版公共底层已上板正常出声；这不代表本次新增联动状态机及CDC已经实机通过。',
        '- 新增渐变使用串行移位加法，DSP维持29/29；同一正弦表两个DDS实例各有ROM，BRAM由39增至40。',
        '- reports/media_math_checks.json为软件数学检查，不是RTL仿真或实机通过证据。',
        '', '## 证据', '',
        '- reports/ 中保留最终完整 TD 日志、布线时序、资源/IO、时序例外及机器可读摘要。',
        '- artifacts/ 中提供本次生成的两个 bit，SHA256SUMS.json 标识其哈希。',
        '- reports/source_sha256_lf.json 标识生成 bit 所使用的源码（换行归一化 LF）。',
        '- 队友按 README 保存照片、带声音的视频、设备型号、bit 哈希和运行时间后再确认上板通过。','']
    (BOARD/'VALIDATION.md').write_text('\n'.join(rows),encoding='utf-8')
    print(json.dumps({t:r['routed_slack_ns'] for t,r in results.items()}))
    print(f'{len(baseline)} baseline files unchanged; artifacts and evidence collected')


if __name__=='__main__':main()
