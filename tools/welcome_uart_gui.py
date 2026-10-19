#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""迎新/应急流动通知串口控制器（115200/8N1）。

依赖: pip install pyserial
协议与 FPGA 的 src/welcome_uart_controller.v 同源。
"""
import tkinter as tk
from tkinter import messagebox, ttk

try:
    import serial
    from serial.tools import list_ports
except ImportError:
    serial = None
    list_ports = None

GLYPHS = " 迎新报到流程签领卡入住军训物资热烈欢同学校园通知请前往体育馆办理手续注意安全今日明天开始"
DEFAULT_TEXT = "迎新报到流程 签到 领卡 入住 军训物资"
GLYPH_ID = {ch: i for i, ch in enumerate(GLYPHS)}
EM_GLYPHS = "紧急告警火灾报地震避险恶劣天气临时疏散级别：提示事件点实验楼三层校园室外教学区域请沿东侧安全通道有序撤离禁止乘坐电梯远玻璃和高大物体双手保护头部暂停活动前往内树木空坠按照现场人员指引操集合持续间尚未解除仅管理可 0123456789"
DEFAULT_EM_TEXT = "火灾警报 请沿东侧安全通道有序撤离 禁止乘坐电梯"
EM_GLYPH_ID = {ch: i for i, ch in enumerate(EM_GLYPHS)}


def make_frame(cmd: int, payload: bytes = b"") -> bytes:
    if len(payload) > 32:
        raise ValueError("payload too long")
    crc = cmd ^ len(payload)
    for value in payload:
        crc ^= value
    return bytes((0xA5, 0x5A, cmd, len(payload))) + payload + bytes((crc,))


class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("校园迎新/应急流动通知控制器")
        self.geometry("800x700")
        self.resizable(False, False)
        self.port = tk.StringVar()
        self.text_value = tk.StringVar(value=DEFAULT_TEXT)
        self.speed = tk.IntVar(value=1)
        self.paused = tk.BooleanVar(value=False)
        self.em_text_value = tk.StringVar(value=DEFAULT_EM_TEXT)
        self.em_speed = tk.IntVar(value=1)
        self.em_paused = tk.BooleanVar(value=False)
        self.status = tk.StringVar(value="未连接")
        self._build()
        self.refresh_ports()

    def _build(self):
        frm = ttk.Frame(self, padding=16)
        frm.pack(fill="both", expand=True)
        ttk.Label(frm, text="串口").grid(row=0, column=0, sticky="w")
        self.port_box = ttk.Combobox(frm, textvariable=self.port, width=18, state="readonly")
        self.port_box.grid(row=0, column=1, sticky="w", padx=8)
        ttk.Button(frm, text="刷新", command=self.refresh_ports).grid(row=0, column=2, sticky="w")
        ttk.Label(frm, text="115200 / 8N1").grid(row=0, column=3, padx=16, sticky="w")

        ttk.Label(frm, text="迎新流动通知（最多32字）").grid(row=1, column=0, columnspan=4, pady=(22, 4), sticky="w")
        ttk.Entry(frm, textvariable=self.text_value, width=70).grid(row=2, column=0, columnspan=4, sticky="we")
        ttk.Label(frm, text="支持字库：" + GLYPHS, wraplength=670).grid(
            row=3, column=0, columnspan=4, pady=8, sticky="w")

        ttk.Label(frm, text="滚动速度（数值越小越快）").grid(row=4, column=0, columnspan=2, pady=(16, 2), sticky="w")
        ttk.Scale(frm, from_=1, to=30, variable=self.speed, orient="horizontal", length=380).grid(
            row=5, column=0, columnspan=3, sticky="w")
        ttk.Label(frm, textvariable=self.speed, width=4).grid(row=5, column=3, sticky="w")

        ttk.Checkbutton(frm, text="暂停滚动", variable=self.paused, command=self.send_pause).grid(
            row=6, column=0, pady=18, sticky="w")
        ttk.Button(frm, text="发送内容并生效", command=self.send_text).grid(row=7, column=0, padx=(0, 8), sticky="we")
        ttk.Button(frm, text="应用速度", command=self.send_speed).grid(row=7, column=1, padx=8, sticky="we")
        ttk.Button(frm, text="恢复默认", command=self.restore_default).grid(row=7, column=2, padx=8, sticky="we")
        ttk.Button(frm, text="全部应用", command=self.apply_all).grid(row=7, column=3, padx=(8, 0), sticky="we")
        ttk.Separator(frm).grid(row=8, column=0, columnspan=4, pady=16, sticky="we")
        ttk.Label(frm, text="应急底部流动通知（最多32字）").grid(row=9, column=0, columnspan=4, sticky="w")
        ttk.Entry(frm, textvariable=self.em_text_value, width=76).grid(row=10, column=0, columnspan=4, sticky="we")
        ttk.Label(frm, text="应急字库：" + EM_GLYPHS, wraplength=750).grid(
            row=11, column=0, columnspan=4, pady=8, sticky="w")
        ttk.Label(frm, text="应急滚动速度（数值越小越快）").grid(row=12, column=0, columnspan=2, sticky="w")
        ttk.Scale(frm, from_=1, to=30, variable=self.em_speed, orient="horizontal", length=420).grid(
            row=13, column=0, columnspan=3, sticky="w")
        ttk.Label(frm, textvariable=self.em_speed, width=4).grid(row=13, column=3, sticky="w")
        ttk.Checkbutton(frm, text="暂停应急滚动", variable=self.em_paused, command=self.send_emergency_pause).grid(
            row=14, column=0, pady=12, sticky="w")
        ttk.Button(frm, text="发送应急内容", command=self.send_emergency_text).grid(row=15, column=0, padx=(0, 8), sticky="we")
        ttk.Button(frm, text="应用应急速度", command=self.send_emergency_speed).grid(row=15, column=1, padx=8, sticky="we")
        ttk.Button(frm, text="恢复分类默认", command=self.restore_emergency_default).grid(row=15, column=2, padx=8, sticky="we")
        ttk.Button(frm, text="全部应用应急", command=self.apply_emergency_all).grid(row=15, column=3, padx=(8, 0), sticky="we")
        ttk.Separator(frm).grid(row=16, column=0, columnspan=4, pady=16, sticky="we")
        ttk.Label(frm, textvariable=self.status).grid(row=17, column=0, columnspan=4, sticky="w")
        ttk.Label(frm, text="提示：配置在下一帧边界生效；断电后恢复默认通知。", foreground="#555").grid(
            row=18, column=0, columnspan=4, pady=8, sticky="w")
        for col in range(4):
            frm.columnconfigure(col, weight=1)

    def refresh_ports(self):
        if list_ports is None:
            self.status.set("缺少 pyserial，请先执行：pip install pyserial")
            return
        ports = [p.device for p in list_ports.comports()]
        self.port_box["values"] = ports
        if ports and self.port.get() not in ports:
            self.port.set(ports[0])
        self.status.set("找到串口：" + (", ".join(ports) if ports else "无"))

    def _send(self, cmd: int, payload: bytes = b""):
        if serial is None:
            raise RuntimeError("缺少 pyserial，请先执行 pip install pyserial")
        if not self.port.get():
            raise RuntimeError("请选择串口")
        frame = make_frame(cmd, payload)
        with serial.Serial(self.port.get(), 115200, timeout=0.7) as dev:
            dev.reset_input_buffer()
            dev.write(frame)
            dev.flush()
            reply = dev.read(6)
        if len(reply) != 6 or reply[0:2] != b"\xA5\x5A":
            raise RuntimeError("FPGA无有效回执，请检查COM口、固化位流和USB连接")
        crc = reply[2] ^ reply[3] ^ reply[4]
        if reply[5] != crc or reply[3] != 1:
            raise RuntimeError("FPGA回执校验失败")
        if reply[4] != 0:
            errors = {1: "校验错误", 2: "长度错误", 3: "参数错误", 4: "串口帧错误", 5: "未知命令"}
            raise RuntimeError(errors.get(reply[4], f"错误码{reply[4]}"))
        self.status.set(f"发送成功：命令 0x{cmd:02X}")

    def _guard(self, action):
        try:
            action()
        except Exception as exc:
            self.status.set("失败：" + str(exc))
            messagebox.showerror("发送失败", str(exc))

    def send_text(self):
        def action():
            value = self.text_value.get()
            if not 1 <= len(value) <= 32:
                raise ValueError("通知长度必须为1～32字")
            unsupported = sorted(set(value) - set(GLYPHS))
            if unsupported:
                raise ValueError("字库暂不支持：" + " ".join(unsupported))
            # FPGA 用固定移位寄存器接收；逆序发送后，显示顺序仍与输入一致。
            self._send(0x01, bytes(GLYPH_ID[ch] for ch in reversed(value)))
        self._guard(action)

    def send_speed(self):
        self._guard(lambda: self._send(0x02, bytes((max(1, min(30, self.speed.get())),))))

    def send_pause(self):
        self._guard(lambda: self._send(0x03, bytes((1 if self.paused.get() else 0,))))

    def restore_default(self):
        def action():
            self._send(0x04)
            self.text_value.set(DEFAULT_TEXT)
            self.speed.set(1)
            self.paused.set(False)
        self._guard(action)

    def apply_all(self):
        self.send_text()
        self.send_speed()
        self.send_pause()

    def send_emergency_text(self):
        def action():
            value = self.em_text_value.get()
            if not 1 <= len(value) <= 32:
                raise ValueError("应急通知长度必须为1～32字")
            unsupported = sorted(set(value) - set(EM_GLYPHS))
            if unsupported:
                raise ValueError("应急字库暂不支持：" + " ".join(unsupported))
            self._send(0x11, bytes(EM_GLYPH_ID[ch] for ch in reversed(value)))
        self._guard(action)

    def send_emergency_speed(self):
        self._guard(lambda: self._send(0x12, bytes((max(1, min(30, self.em_speed.get())),))))

    def send_emergency_pause(self):
        self._guard(lambda: self._send(0x13, bytes((1 if self.em_paused.get() else 0,))))

    def restore_emergency_default(self):
        def action():
            self._send(0x14)
            self.em_text_value.set(DEFAULT_EM_TEXT)
            self.em_speed.set(1)
            self.em_paused.set(False)
        self._guard(action)

    def apply_emergency_all(self):
        self.send_emergency_text()
        self.send_emergency_speed()
        self.send_emergency_pause()


if __name__ == "__main__":
    App().mainloop()
