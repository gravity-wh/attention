// =====================================================================
//  top_stub.sv —— 流程自检夹具（**不是设计，不进综合**）
//
//  用途：在三个真实方案还没写出来之前，先证明「流程本身」是通的：
//     · tb 能正确装载 3×256 个元素
//     · start/busy/done 握手能被驱动
//     · 256 个输出能被按地址收齐
//     · 判据会正确判 FAIL，且退出码非 0
//
//  它输出的全是 0，所以**必然 FAIL**。这不是 bug，是设计意图：
//  一个永远 PASS 的夹具证明不了任何事。
//
//  跑法：make flowtest
// =====================================================================
`include "attn_ports.svh"

module top_stub `ATTN_TOP_PORTS;

  localparam int COMPUTE_CYC = 40;   // 假装算 40 拍，让时延统计有内容

  typedef enum logic [2:0] {
    I_IDLE  = 3'd0,
    I_CALC  = 3'd1,
    I_OUT   = 3'd2,
    I_DONE  = 3'd3
  } ist_t;

  ist_t       st;
  logic [7:0] cnt;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st     <= I_IDLE;
      cnt    <= 8'd0;
      busy   <= 1'b0;
      done   <= 1'b0;
      o_vld  <= 1'b0;
      o_addr <= 8'd0;
      o_data <= 16'h0000;
    end else begin
      done <= 1'b0;            // 单周期脉冲

      case (st)
        I_IDLE: begin
          busy  <= 1'b0;
          o_vld <= 1'b0;
          if (start) begin
            busy <= 1'b1;
            cnt  <= 8'd0;
            st   <= I_CALC;
          end
        end

        I_CALC: begin
          if (cnt == COMPUTE_CYC[7:0]) begin
            done   <= 1'b1;
            o_vld  <= 1'b1;
            o_addr <= 8'd0;
            o_data <= 16'h0000;   // 故意全 0
            cnt    <= 8'd0;
            st     <= I_OUT;
          end else begin
            cnt <= cnt + 8'd1;
          end
        end

        I_OUT: begin
          if (cnt == 8'd255) begin
            o_vld <= 1'b0;
            st    <= I_DONE;
          end else begin
            cnt    <= cnt + 8'd1;
            o_addr <= cnt + 8'd1;
            o_data <= 16'h0000;
          end
        end

        I_DONE: begin
          busy <= 1'b0;
          if (!start) st <= I_IDLE;
        end

        default: st <= I_IDLE;
      endcase
    end
  end

  // 装载通道：收下但不存（反正不用）
  always_ff @(posedge clk) begin
    if (rst_n && ld_en) begin
      // 真实设计在这里写 mem[ld_sel][ld_addr] <= ld_data
    end
  end

endmodule
