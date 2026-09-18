"""Generate additive TD projects/top from the pinned main baseline; no RTL simulation.
Run: python audio_board/tools/prepare_projects.py
Normal users receive pre-generated projects and do not need Python.
"""
from pathlib import Path
import hashlib
import json
import math
import re
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
BOARD = ROOT / 'audio_board'
RTL = BOARD / 'rtl'
VENDOR = BOARD / 'vendor'
BASE = '6586b66447375c1c4dfc9568b17a79df889cfbae'


def prepare():
    # sine initialization: no external .hex file / working-directory dependency
    rows = ['// Generated 256-point sine, amplitude 4096; signed two\'s complement.',
            'function signed [15:0] audio_sine;', 'input [7:0] index;', 'begin case(index)']
    rows += [f"8'd{i}:audio_sine=16'h{round(4096*math.sin(2*math.pi*i/256)) & 0xffff:04x};" for i in range(256)]
    rows += ['default:audio_sine=0;', 'endcase end endfunction', '']
    (RTL/'audio_sine_init.vh').write_text('\n'.join(rows), encoding='utf-8')
    # Tutorial adaptation lives outside baseline src/. Originals retained in vendor/.
    core = (VENDOR/'hdmi_audio_symbol_core.v').read_text(encoding='utf-8')
    core = core.replace('    wire video_preamble =', '''    // Only emit a video preamble/guard on lines that actually contain video.
    reg active_line;
    always @(posedge pixel_clk or negedge rst_n)
        if (!rst_n) active_line <= 1'b0;
        else if (video_x == 0) active_line <= video_de;
        else if (video_de) active_line <= 1'b1;
    wire video_preamble = active_line &&''')
    core = core.replace('wire video_guard = video_x', 'wire video_guard = active_line && video_x')
    core = core.replace('wire info_valid, info_ready;', '''wire info_valid, info_ready;
    wire audio_info_valid, audio_info_ready;
    wire avi_valid, avi_ready;
    wire [23:0] avi_header, audio_info_header;
    wire [7:0] avi_header_ecc, audio_info_header_ecc;
    wire [223:0] avi_body, audio_info_body;
    wire [31:0] avi_body_ecc, audio_info_body_ecc;''')
    start = core.index('    hdmi_audio_infoframe_packetizer u_info_packetizer')
    end = core.index('    wire packet_valid;', start)
    core = core[:start] + '''    hdmi_audio_infoframe_packetizer u_info_packetizer (
        .clk(pixel_clk),.rst_n(rst_n),.emit(info_emit),
        .packet_valid(audio_info_valid),.packet_ready(audio_info_ready),
        .packet_header(audio_info_header),.packet_header_ecc(audio_info_header_ecc),
        .packet_body(audio_info_body),.packet_body_ecc(audio_info_body_ecc)
    );
    hdmi_avi_infoframe_packetizer u_avi_packetizer (
        .clk(pixel_clk),.rst_n(rst_n),.emit(info_emit),
        .packet_valid(avi_valid),.packet_ready(avi_ready),
        .packet_header(avi_header),.packet_header_ecc(avi_header_ecc),
        .packet_body(avi_body),.packet_body_ecc(avi_body_ecc)
    );
    assign info_valid=avi_valid || audio_info_valid;
    assign avi_ready=info_ready && avi_valid;
    assign audio_info_ready=info_ready && !avi_valid;
    assign info_header=avi_valid ? avi_header : audio_info_header;
    assign info_header_ecc=avi_valid ? avi_header_ecc : audio_info_header_ecc;
    assign info_body=avi_valid ? avi_body : audio_info_body;
    assign info_body_ecc=avi_valid ? avi_body_ecc : audio_info_body_ecc;

''' + core[end:]
    (RTL/'hdmi_audio_symbol_core.v').write_text(core,encoding='utf-8')
    for name in ('hdmi_audio_acr_packetizer','hdmi_audio_infoframe_packetizer',
                 'hdmi_audio_packet_scheduler','hdmi_audio_sample_packetizer',
                 'hdmi_bch8','hdmi_data_island_mapper','hdmi_data_island_scheduler',
                 'hdmi_terc4_encoder','hdmi_tmds_channel_encoder'):
        (RTL/f'{name}.v').write_bytes((VENDOR/f'{name}.v').read_bytes())

    top = (ROOT/'src/top.v').read_text(encoding='utf-8')
    # The original module name and external ports are unchanged.
    top = re.sub(r'`include "([^"/]+)"',r'`include "../../src/\1"',top)
    pattern = r'hdmi_tx #\(\.FAMILY\("EG4"\)\).*?\n\s*\);'
    insertion = '''// Public audio bottom layer. Test is continuous in EVERY scene/menu.
// Future scene sources replace u_audio_test_source via the same PCM interface.
localparam integer AUDIO_TEST_PROFILE=0; // 0 stereo / 1 left / 2 right
wire audio_rst_n_ser;
reset_sync u_audio_serial_reset(.clk(hdmi_5x_clk),.rst_n_async(ext_rst_n),.rst_n_sync(audio_rst_n_ser));
wire audio_pcm_valid,audio_pcm_ready;
wire signed [15:0] audio_left,audio_right;
wire audio_tone_overflow,audio_timing_locked,audio_timing_error;
wire audio_sequence_error,audio_contract_error;
wire [31:0] audio_generated_samples,audio_accepted_samples;
wire [6:0] audio_fifo_level;
audio_pcm_tone #(.PROFILE(AUDIO_TEST_PROFILE)) u_audio_test_source(
    .clk(video_clk),.rst_n(rst_n_vid),.enable(1'b1),
    .sample_valid(audio_pcm_valid),.sample_ready(audio_pcm_ready),
    .sample_left(audio_left),.sample_right(audio_right),
    .overflow(audio_tone_overflow),.sample_count(audio_generated_samples));
audio_hdmi_output u_audio_hdmi(
    .pixel_clk(video_clk),.serial_clk(hdmi_5x_clk),
    .pixel_rst_n(rst_n_vid),.serial_rst_n(audio_rst_n_ser),
    .hs(fin_hs),.vs(fin_vs),.de(fin_de),.rgb(fin_data),
    .pcm_valid(audio_pcm_valid),.pcm_ready(audio_pcm_ready),.pcm_left(audio_left),.pcm_right(audio_right),
    .HDMI_CLK_P(HDMI_CLK_P),.HDMI_D0_P(HDMI_D0_P),.HDMI_D1_P(HDMI_D1_P),.HDMI_D2_P(HDMI_D2_P),
    .timing_locked(audio_timing_locked),.timing_error(audio_timing_error),
    .sequence_error(audio_sequence_error),.pcm_contract_error(audio_contract_error),
    .fifo_level(audio_fifo_level),.accepted_samples(audio_accepted_samples));'''
    top,n = re.subn(pattern,lambda _:insertion,top,flags=re.S)
    assert n==1, 'baseline HDMI instance changed: review generator'
    (BOARD/'integrated').mkdir(exist_ok=True)
    (BOARD/'integrated/top_audio.v').write_text('// Generated from main '+BASE+'; audio output addition only.\n'+top,encoding='utf-8')
    common = sorted('rtl/'+p.name for p in RTL.glob('*.v'))
    standalone = ET.Element('Project',Version='3',Minor='2',Path=(BOARD/'standalone').as_posix())
    ET.SubElement(standalone,'TD_Version').text='6.2.168116'
    ET.SubElement(standalone,'Name').text='hdmi_tone'
    hw=ET.SubElement(standalone,'HardWare')
    ET.SubElement(hw,'Family').text='EG4'
    ET.SubElement(hw,'Device').text='EG4S20BG256'
    ET.SubElement(hw,'Speed')
    sources=ET.SubElement(standalone,'Source_Files')
    verilog=ET.SubElement(sources,'Verilog')
    for i,path in enumerate(['top_tone.v','../../al_ip/video_pll.v']+['../'+p for p in common]):
        add_file(verilog,path,i,'design_1')
    for i,(tag,path) in enumerate([('ADC_FILE','tone.adc'),('SDC_FILE','tone.sdc')],start=90):
        add_file(ET.SubElement(sources,tag),path,i,'constraint_1')
    # TD .al uses literal '&' in UsedInP&R; normalize only while parsing.
    original=ET.ElementTree(ET.fromstring((ROOT/'pic_sdram.al').read_text(encoding='utf-8').replace('UsedInP&R','UsedInP&amp;R')))
    for tag in ('FileSets','TOP_MODULE','Property','Device_Settings','Configurations','Runs','Project_Settings'):
        standalone.append(ET.fromstring(ET.tostring(original.getroot().find(tag))))
    ET.indent(standalone)
    ET.ElementTree(standalone).write(BOARD/'standalone/hdmi_tone.al',encoding='utf-8',xml_declaration=True)

    project=ET.ElementTree(ET.fromstring((ROOT/'pic_sdram.al').read_text(encoding='utf-8').replace('UsedInP&R','UsedInP&amp;R')))
    pr=project.getroot()
    pr.set('Path',ROOT.as_posix())
    pr.find('Name').text='pic_sdram_audio'
    # Register IP wrappers explicitly: copied IPC paths may contain old machine paths.
    ipfiles=pr.find('Source_Files/IP_FILE')
    pr.find('Source_Files').remove(ipfiles)
    vl=pr.find('Source_Files/Verilog')
    for f in pr.findall('Source_Files/*/File'):
        path=f.get('Path')
        f.set('Path','audio_board/integrated/top_audio.v' if path=='src/top.v' else path)
    pr.find('Source_Files/SDC_FILE/File').set('Path','audio_board/integrated/audio.sdc')
    for i,path in enumerate(['al_ip/sys_pll.v','al_ip/video_pll.v',
                             'al_ip/afifo_16_32_256.v','al_ip/afifo_32_16_256.v']+
                            ['audio_board/'+p for p in common],start=100):
        add_file(vl,path,i,'design_1')
    ET.indent(project)
    project.write(ROOT/'pic_sdram_audio.al',encoding='utf-8',xml_declaration=True)
    for path in (BOARD/'standalone/hdmi_tone.al',ROOT/'pic_sdram_audio.al'):
        text=path.read_text(encoding='utf-8').replace('UsedInP&amp;R','UsedInP&R')
        text=re.sub(r'(<Project[^>]* Path=")[^"]+',r'\1.',text)
        path.write_text(text,encoding='utf-8')
    adc=(ROOT/'top.adc').read_text(encoding='utf-8')
    (BOARD/'standalone/tone.adc').write_text('\n'.join(l for l in adc.splitlines() if 'HDMI_' in l or re.search(r'\{\s*clk\s*\}',l))+'\n',encoding='utf-8')
    sdc=(ROOT/'top.sdc').read_text(encoding='utf-8')
    (BOARD/'integrated/audio.sdc').write_text(sdc,encoding='utf-8')
    (BOARD/'standalone/tone.sdc').write_text('''# 25 MHz / 125 MHz are RELATED clocks: never false-path the symbol transfer.
create_clock -name clk -period 20.000 [get_ports {clk}]
create_generated_clock -name video_clk -source [get_ports {clk}] -master_clock clk -divide_by 2 [get_pins {video_pll_m0/pll_inst.clkc[0]}]
create_generated_clock -name hdmi_5x_clk -source [get_ports {clk}] -master_clock clk -multiply_by 2.5 [get_pins {video_pll_m0/pll_inst.clkc[1]}]
set_false_path -to [get_regs -hier {*/sync_ff[0]}]
set_false_path -from [get_pins {video_pll_m0/pll_inst.extlock}]
set_clock_uncertainty -hold 0.050 [get_clocks {clk video_clk hdmi_5x_clk}]
set_max_delay -from [get_clocks {hdmi_5x_clk}] -to [get_ports {HDMI_CLK_P HDMI_D0_P HDMI_D1_P HDMI_D2_P}] 8.000 -datapath_only
''',encoding='utf-8')
    manifest={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(VENDOR.glob('*.v'))}
    (VENDOR/'SHA256.json').write_text(json.dumps(manifest,indent=2)+'\n',encoding='utf-8')
    print('Generated audio_board/standalone/hdmi_tone.al and pic_sdram_audio.al')


def add_file(parent,path,order,fileset):
    f=ET.SubElement(parent,'File',Path=path)
    info=ET.SubElement(f,'FileInfo')
    for name,value in [('UsedInSyn','true'),('UsedInP&R','true'),('BelongTo',fileset),('CompileOrder',str(order))]:
        ET.SubElement(info,'Attr',Name=name,Val=value)


if __name__=='__main__':
    prepare()
