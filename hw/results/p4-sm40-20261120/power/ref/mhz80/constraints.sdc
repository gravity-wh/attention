# 由 run_syn.sh 生成，勿手改（改了下次 make syn 就被覆盖）
# 目标频率 80 MHz → 周期 12.500000 ns
# 输入/输出延迟各 25% 周期，时钟不确定性 5% 周期
# 驱动单元 BUFH_X4M_A9TR40，输出负载 0.016 pF
create_clock -name clk -period 12.500000 [get_ports clk]
set_clock_uncertainty 0.625000 [get_clocks clk]

# 输入侧：外面有一级寄存器 + 25% 周期的路径延迟。
# 时钟端口本身不设驱动单元（它由时钟树驱动，不是数据）。
set_driving_cell -lib_cell BUFH_X4M_A9TR40 -pin Y     [remove_from_collection [all_inputs] [get_ports clk]]
set_input_delay 3.125000 -clock clk     [remove_from_collection [all_inputs] [get_ports clk]]
set_input_transition 0.05 [all_inputs]

set_load 0.016 [all_outputs]
set_output_delay 3.125000 -clock clk [all_outputs]

# rst_n 是异步复位，不做时序检查（否则会被当成一条跨时钟路径）
set_false_path -from [get_ports rst_n]
