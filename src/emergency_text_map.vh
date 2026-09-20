function [6:0] emergency_glyph_id;
  input [4:0] text_id; input [4:0] char_pos;
  begin
    emergency_glyph_id = 7'h7f;
    case ({text_id,char_pos})
      // 0: 紧急告警
      10'd0: emergency_glyph_id = 7'd0;
      10'd1: emergency_glyph_id = 7'd1;
      10'd2: emergency_glyph_id = 7'd2;
      10'd3: emergency_glyph_id = 7'd3;
      // 1: 火灾警报
      10'd32: emergency_glyph_id = 7'd4;
      10'd33: emergency_glyph_id = 7'd5;
      10'd34: emergency_glyph_id = 7'd3;
      10'd35: emergency_glyph_id = 7'd6;
      // 2: 地震避险
      10'd64: emergency_glyph_id = 7'd7;
      10'd65: emergency_glyph_id = 7'd8;
      10'd66: emergency_glyph_id = 7'd9;
      10'd67: emergency_glyph_id = 7'd10;
      // 3: 恶劣天气
      10'd96: emergency_glyph_id = 7'd11;
      10'd97: emergency_glyph_id = 7'd12;
      10'd98: emergency_glyph_id = 7'd13;
      10'd99: emergency_glyph_id = 7'd14;
      // 4: 临时疏散
      10'd128: emergency_glyph_id = 7'd15;
      10'd129: emergency_glyph_id = 7'd16;
      10'd130: emergency_glyph_id = 7'd17;
      10'd131: emergency_glyph_id = 7'd18;
      // 5: 告警级别：紧急
      10'd160: emergency_glyph_id = 7'd2;
      10'd161: emergency_glyph_id = 7'd3;
      10'd162: emergency_glyph_id = 7'd19;
      10'd163: emergency_glyph_id = 7'd20;
      10'd164: emergency_glyph_id = 7'd21;
      10'd165: emergency_glyph_id = 7'd0;
      10'd166: emergency_glyph_id = 7'd1;
      // 6: 告警级别：警告
      10'd192: emergency_glyph_id = 7'd2;
      10'd193: emergency_glyph_id = 7'd3;
      10'd194: emergency_glyph_id = 7'd19;
      10'd195: emergency_glyph_id = 7'd20;
      10'd196: emergency_glyph_id = 7'd21;
      10'd197: emergency_glyph_id = 7'd3;
      10'd198: emergency_glyph_id = 7'd2;
      // 7: 告警级别：提示
      10'd224: emergency_glyph_id = 7'd2;
      10'd225: emergency_glyph_id = 7'd3;
      10'd226: emergency_glyph_id = 7'd19;
      10'd227: emergency_glyph_id = 7'd20;
      10'd228: emergency_glyph_id = 7'd21;
      10'd229: emergency_glyph_id = 7'd22;
      10'd230: emergency_glyph_id = 7'd23;
      // 8: 事件地点：实验楼三层
      10'd256: emergency_glyph_id = 7'd24;
      10'd257: emergency_glyph_id = 7'd25;
      10'd258: emergency_glyph_id = 7'd7;
      10'd259: emergency_glyph_id = 7'd26;
      10'd260: emergency_glyph_id = 7'd21;
      10'd261: emergency_glyph_id = 7'd27;
      10'd262: emergency_glyph_id = 7'd28;
      10'd263: emergency_glyph_id = 7'd29;
      10'd264: emergency_glyph_id = 7'd30;
      10'd265: emergency_glyph_id = 7'd31;
      // 9: 事件地点：校园室外
      10'd288: emergency_glyph_id = 7'd24;
      10'd289: emergency_glyph_id = 7'd25;
      10'd290: emergency_glyph_id = 7'd7;
      10'd291: emergency_glyph_id = 7'd26;
      10'd292: emergency_glyph_id = 7'd21;
      10'd293: emergency_glyph_id = 7'd32;
      10'd294: emergency_glyph_id = 7'd33;
      10'd295: emergency_glyph_id = 7'd34;
      10'd296: emergency_glyph_id = 7'd35;
      // 10: 事件地点：教学楼区域
      10'd320: emergency_glyph_id = 7'd24;
      10'd321: emergency_glyph_id = 7'd25;
      10'd322: emergency_glyph_id = 7'd7;
      10'd323: emergency_glyph_id = 7'd26;
      10'd324: emergency_glyph_id = 7'd21;
      10'd325: emergency_glyph_id = 7'd36;
      10'd326: emergency_glyph_id = 7'd37;
      10'd327: emergency_glyph_id = 7'd29;
      10'd328: emergency_glyph_id = 7'd38;
      10'd329: emergency_glyph_id = 7'd39;
      // 11: 请沿东侧安全通道有序撤离
      10'd352: emergency_glyph_id = 7'd40;
      10'd353: emergency_glyph_id = 7'd41;
      10'd354: emergency_glyph_id = 7'd42;
      10'd355: emergency_glyph_id = 7'd43;
      10'd356: emergency_glyph_id = 7'd44;
      10'd357: emergency_glyph_id = 7'd45;
      10'd358: emergency_glyph_id = 7'd46;
      10'd359: emergency_glyph_id = 7'd47;
      10'd360: emergency_glyph_id = 7'd48;
      10'd361: emergency_glyph_id = 7'd49;
      10'd362: emergency_glyph_id = 7'd50;
      10'd363: emergency_glyph_id = 7'd51;
      // 12: 禁止乘坐电梯
      10'd384: emergency_glyph_id = 7'd52;
      10'd385: emergency_glyph_id = 7'd53;
      10'd386: emergency_glyph_id = 7'd54;
      10'd387: emergency_glyph_id = 7'd55;
      10'd388: emergency_glyph_id = 7'd56;
      10'd389: emergency_glyph_id = 7'd57;
      // 13: 远离玻璃和高大物体
      10'd416: emergency_glyph_id = 7'd58;
      10'd417: emergency_glyph_id = 7'd51;
      10'd418: emergency_glyph_id = 7'd59;
      10'd419: emergency_glyph_id = 7'd60;
      10'd420: emergency_glyph_id = 7'd61;
      10'd421: emergency_glyph_id = 7'd62;
      10'd422: emergency_glyph_id = 7'd63;
      10'd423: emergency_glyph_id = 7'd64;
      10'd424: emergency_glyph_id = 7'd65;
      // 14: 双手保护头部
      10'd448: emergency_glyph_id = 7'd66;
      10'd449: emergency_glyph_id = 7'd67;
      10'd450: emergency_glyph_id = 7'd68;
      10'd451: emergency_glyph_id = 7'd69;
      10'd452: emergency_glyph_id = 7'd70;
      10'd453: emergency_glyph_id = 7'd71;
      // 15: 暂停室外活动前往室内安全区
      10'd480: emergency_glyph_id = 7'd72;
      10'd481: emergency_glyph_id = 7'd73;
      10'd482: emergency_glyph_id = 7'd34;
      10'd483: emergency_glyph_id = 7'd35;
      10'd484: emergency_glyph_id = 7'd74;
      10'd485: emergency_glyph_id = 7'd75;
      10'd486: emergency_glyph_id = 7'd76;
      10'd487: emergency_glyph_id = 7'd77;
      10'd488: emergency_glyph_id = 7'd34;
      10'd489: emergency_glyph_id = 7'd78;
      10'd490: emergency_glyph_id = 7'd44;
      10'd491: emergency_glyph_id = 7'd45;
      10'd492: emergency_glyph_id = 7'd38;
      // 16: 远离树木和高空坠物
      10'd512: emergency_glyph_id = 7'd58;
      10'd513: emergency_glyph_id = 7'd51;
      10'd514: emergency_glyph_id = 7'd79;
      10'd515: emergency_glyph_id = 7'd80;
      10'd516: emergency_glyph_id = 7'd61;
      10'd517: emergency_glyph_id = 7'd62;
      10'd518: emergency_glyph_id = 7'd81;
      10'd519: emergency_glyph_id = 7'd82;
      10'd520: emergency_glyph_id = 7'd64;
      // 17: 按照现场人员指引有序撤离
      10'd544: emergency_glyph_id = 7'd83;
      10'd545: emergency_glyph_id = 7'd84;
      10'd546: emergency_glyph_id = 7'd85;
      10'd547: emergency_glyph_id = 7'd86;
      10'd548: emergency_glyph_id = 7'd87;
      10'd549: emergency_glyph_id = 7'd88;
      10'd550: emergency_glyph_id = 7'd89;
      10'd551: emergency_glyph_id = 7'd90;
      10'd552: emergency_glyph_id = 7'd48;
      10'd553: emergency_glyph_id = 7'd49;
      10'd554: emergency_glyph_id = 7'd50;
      10'd555: emergency_glyph_id = 7'd51;
      // 18: 前往东区操场集合点
      10'd576: emergency_glyph_id = 7'd76;
      10'd577: emergency_glyph_id = 7'd77;
      10'd578: emergency_glyph_id = 7'd42;
      10'd579: emergency_glyph_id = 7'd38;
      10'd580: emergency_glyph_id = 7'd91;
      10'd581: emergency_glyph_id = 7'd86;
      10'd582: emergency_glyph_id = 7'd92;
      10'd583: emergency_glyph_id = 7'd93;
      10'd584: emergency_glyph_id = 7'd26;
      // 19: 持续时间：
      10'd608: emergency_glyph_id = 7'd94;
      10'd609: emergency_glyph_id = 7'd95;
      10'd610: emergency_glyph_id = 7'd16;
      10'd611: emergency_glyph_id = 7'd96;
      10'd612: emergency_glyph_id = 7'd21;
      // 20: 告警尚未解除
      10'd640: emergency_glyph_id = 7'd2;
      10'd641: emergency_glyph_id = 7'd3;
      10'd642: emergency_glyph_id = 7'd97;
      10'd643: emergency_glyph_id = 7'd98;
      10'd644: emergency_glyph_id = 7'd99;
      10'd645: emergency_glyph_id = 7'd100;
      // 21: 仅管理员可解除告警
      10'd672: emergency_glyph_id = 7'd101;
      10'd673: emergency_glyph_id = 7'd102;
      10'd674: emergency_glyph_id = 7'd103;
      10'd675: emergency_glyph_id = 7'd88;
      10'd676: emergency_glyph_id = 7'd104;
      10'd677: emergency_glyph_id = 7'd99;
      10'd678: emergency_glyph_id = 7'd100;
      10'd679: emergency_glyph_id = 7'd2;
      10'd680: emergency_glyph_id = 7'd3;
      // 22: 按键四切换告警类型
      10'd704: emergency_glyph_id = 7'd83;
      10'd705: emergency_glyph_id = 7'd105;
      10'd706: emergency_glyph_id = 7'd106;
      10'd707: emergency_glyph_id = 7'd107;
      10'd708: emergency_glyph_id = 7'd108;
      10'd709: emergency_glyph_id = 7'd2;
      10'd710: emergency_glyph_id = 7'd3;
      10'd711: emergency_glyph_id = 7'd109;
      10'd712: emergency_glyph_id = 7'd110;
      // 23: 0123456789：
      10'd736: emergency_glyph_id = 7'd111;
      10'd737: emergency_glyph_id = 7'd112;
      10'd738: emergency_glyph_id = 7'd113;
      10'd739: emergency_glyph_id = 7'd114;
      10'd740: emergency_glyph_id = 7'd115;
      10'd741: emergency_glyph_id = 7'd116;
      10'd742: emergency_glyph_id = 7'd117;
      10'd743: emergency_glyph_id = 7'd118;
      10'd744: emergency_glyph_id = 7'd119;
      10'd745: emergency_glyph_id = 7'd120;
      10'd746: emergency_glyph_id = 7'd21;
      default: emergency_glyph_id = 7'h7f;
    endcase
  end
endfunction
function [4:0] emergency_text_len; input [4:0] text_id; begin
  case(text_id)
    5'd0: emergency_text_len = 5'd4;
    5'd1: emergency_text_len = 5'd4;
    5'd2: emergency_text_len = 5'd4;
    5'd3: emergency_text_len = 5'd4;
    5'd4: emergency_text_len = 5'd4;
    5'd5: emergency_text_len = 5'd7;
    5'd6: emergency_text_len = 5'd7;
    5'd7: emergency_text_len = 5'd7;
    5'd8: emergency_text_len = 5'd10;
    5'd9: emergency_text_len = 5'd9;
    5'd10: emergency_text_len = 5'd10;
    5'd11: emergency_text_len = 5'd12;
    5'd12: emergency_text_len = 5'd6;
    5'd13: emergency_text_len = 5'd9;
    5'd14: emergency_text_len = 5'd6;
    5'd15: emergency_text_len = 5'd13;
    5'd16: emergency_text_len = 5'd9;
    5'd17: emergency_text_len = 5'd12;
    5'd18: emergency_text_len = 5'd9;
    5'd19: emergency_text_len = 5'd5;
    5'd20: emergency_text_len = 5'd6;
    5'd21: emergency_text_len = 5'd9;
    5'd22: emergency_text_len = 5'd9;
    5'd23: emergency_text_len = 5'd11;
    default: emergency_text_len = 5'd0;
  endcase
end endfunction
