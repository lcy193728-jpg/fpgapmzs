from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

root=Path(__file__).resolve().parents[1]
font_path=r"C:\Windows\Fonts\Noto Sans SC (TrueType).otf"
f32=ImageFont.truetype(font_path,32); f48=ImageFont.truetype(font_path,48); f16=ImageFont.truetype(font_path,16); f24=ImageFont.truetype(font_path,24)
items=[
 ("火灾警报",(255,59,48),"告警级别：紧急","事件地点：实验楼三层","请沿东侧安全通道有序撤离","禁止乘坐电梯","火灾警报 请沿东侧安全通道有序撤离 禁止乘坐电梯"),
 ("地震避险",(255,159,10),"告警级别：紧急","事件地点：实验楼三层","远离玻璃和高大物体","双手保护头部","地震避险 远离玻璃和高大物体 双手保护头部"),
 ("恶劣天气",(50,173,230),"告警级别：警告","事件地点：校园室外","暂停室外活动前往室内安全区","远离树木和高空坠物","恶劣天气 暂停室外活动前往室内安全区 远离树木和高空坠物"),
 ("临时疏散",(191,90,242),"告警级别：提示","事件地点：教学楼区域","按照现场人员指引有序撤离","前往东区操场集合点","临时疏散 按照现场人员指引有序撤离 前往东区操场集合点")]
canvas=Image.new("RGB",(1280,960),(20,20,20))
for n,(title,accent,level,place,action,avoid,icon) in enumerate(items):
 x0=(n%2)*640;y0=(n//2)*480
 d=ImageDraw.Draw(canvas);d.rectangle((x0,y0,x0+639,y0+479),fill=tuple(v//5 for v in accent))
 d.rectangle((x0,y0,x0+639,y0+55),fill=accent);d.text((x0+256,y0+12),"紧急告警",font=f32,fill="white")
 d.rectangle((x0+184,y0+126,x0+600,y0+286),fill=tuple(v//2 for v in accent))
 d.text((x0+224,y0+58),title,font=f48,fill=(255,59,48))
 if n==0:
  d.polygon([(x0+112,y0+140),(x0+143,y0+202),(x0+152,y0+238),(x0+140,y0+270),(x0+112,y0+280),(x0+82,y0+270),(x0+70,y0+238),(x0+82,y0+198),(x0+96,y0+220)],fill=(255,122,0));d.polygon([(x0+112,y0+210),(x0+132,y0+252),(x0+124,y0+272),(x0+100,y0+272),(x0+92,y0+252)],fill=(255,214,10))
 elif n==3:
  d.rectangle((x0+58,y0+144,x0+116,y0+278),outline=(255,214,10),width=8);d.line((x0+116,y0+223,x0+174,y0+223),fill=(255,214,10),width=10);d.polygon([(x0+174,y0+223),(x0+154,y0+210),(x0+154,y0+236)],fill=(255,214,10));d.ellipse((x0+120,y0+154,x0+144,y0+178),fill=(255,214,10))
 elif n==1:d.text((x0+78,y0+170),"⚠",font=ImageFont.truetype(font_path,72),fill=(255,214,10))
 else:d.text((x0+78,y0+170),"☁",font=ImageFont.truetype(font_path,72),fill=(255,214,10))
 for y,t in [(142,level),(174,place),(222,action),(254,avoid)]:d.text((x0+200,y0+y),t,font=f16,fill="white")
 d.text((x0+240,y0+306),"持续时间：00:18",font=f24,fill=(255,214,10));d.text((x0+272,y0+350),"告警尚未解除",font=f16,fill=(255,214,10))
 d.text((x0+248,y0+390),"仅管理员可解除告警",font=f16,fill="white")
 d.rectangle((x0,y0+438,x0+639,y0+479),fill=(16,16,16));d.text((x0+20,y0+448),icon,font=f16,fill="white")
canvas.save(root/'scene4_alarm_types_preview.png')
