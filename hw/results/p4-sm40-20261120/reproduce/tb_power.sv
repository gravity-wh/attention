// Functional gate simulation for a single, explicitly bounded power window.
`timescale 1ns/1ps

module tb_power;
  integer clock_mhz;
  real half_ns;
  reg clk = 0;
  reg rst_n = 1;
  reg start = 0;
  reg ld_en = 0;
  reg [1:0] ld_sel = 0;
  reg [7:0] ld_addr = 0;
  reg [15:0] ld_data = 0;
  wire busy, done, o_vld;
  wire [7:0] o_addr;
  wire [15:0] o_data;
  reg [15:0] inputs [0:767];
  reg [15:0] expected [0:255];
  string input_file, expected_file, vcd_file;
  realtime window_start;
  integer index, received, cycles;
  reg saw_done;

  initial begin
    if (!$value$plusargs("CLK_MHZ=%d", clock_mhz)) clock_mhz = 100;
    if (clock_mhz <= 0) $fatal(1, "Clock frequency must be positive");
    half_ns = 500.0 / clock_mhz;
    forever #(half_ns) clk = ~clk;
  end
  `DUT dut (
    .clk(clk), .rst_n(rst_n), .start(start), .ld_en(ld_en),
    .ld_sel(ld_sel), .ld_addr(ld_addr), .ld_data(ld_data),
    .busy(busy), .done(done), .o_vld(o_vld), .o_addr(o_addr), .o_data(o_data)
  );

  initial begin
    if (!$value$plusargs("INPUT=%s", input_file) ||
        !$value$plusargs("EXPECTED=%s", expected_file) ||
        !$value$plusargs("VCD=%s", vcd_file))
      $fatal(1, "Specify +INPUT, +EXPECTED and +VCD");
    $readmemh(input_file, inputs);
    $readmemh(expected_file, expected);
    #1 rst_n = 0;
    repeat (5) @(posedge clk);
    @(negedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);

    @(negedge clk);
    window_start = $realtime + half_ns;
    $dumpfile(vcd_file);
    $dumpvars(1, dut);
    for (index = 0; index < 768; index = index + 1) begin
      ld_en = 1;
      ld_sel = index / 256;
      ld_addr = index % 256;
      ld_data = inputs[index];
      @(negedge clk);
    end
    ld_en = 0;
    @(negedge clk);
    start = 1;
    @(negedge clk);
    start = 0;

    received = 0;
    cycles = 0;
    saw_done = 0;
    while (received < 256 && cycles < 30000) begin
      @(posedge clk);
      #0.001;
      cycles = cycles + 1;
      if (done === 1'b1) saw_done = 1;
      if (o_vld === 1'b1) begin
        if (o_addr !== received[7:0] || o_data !== expected[received])
          $fatal(1, "Output %0d: address=%0d output=%04x expected=%04x",
                 received, o_addr, o_data, expected[received]);
        received = received + 1;
      end
    end
    if (!saw_done || received != 256)
      $fatal(1, "Incomplete task: received=%0d done=%0d", received, saw_done);
    $dumpflush;
    $display("P4_WINDOW PASS start_ns=%.3f end_ns=%.3f duration_ns=%.3f outputs=%0d",
             window_start, $realtime - 0.001, $realtime - 0.001 - window_start, received);
    $finish;
  end
endmodule
