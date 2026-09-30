//================================================
// TESTBENCH
//================================================
module tb_simd_vector_engine;
    parameter W = 16, M = 16, RW = 2*W + 1;
 
    reg clk = 0, rst = 1, start = 0;
    reg [1:0] op = 0;
    reg [4:0] len = 0;
    reg [W*M-1:0] A_flat = 0, B_flat = 0, C_flat = 0;
    wire busy, done;
    wire [RW*M-1:0] Y_flat;
 
    simd_vector_engine #(.DATA_WIDTH(W), .LANES(4), .MAX_VECTOR_LENGTH(M)) dut (
        .clk(clk), .rst(rst), .start(start), .operation(op), .vector_length(len),
        .A_flat(A_flat), .B_flat(B_flat), .C_flat(C_flat),
        .busy(busy), .done(done), .Y_flat(Y_flat));
 
    always #5 clk = ~clk;
 
    reg signed [W-1:0]  ta [0:M-1];
    reg signed [W-1:0]  tb [0:M-1];
    reg signed [W-1:0]  tc [0:M-1];
    reg signed [RW-1:0] exp, got;
    integer i, t, errors, total_errors, k;
 
    task run_test(input [1:0] o, input [4:0] n, input [8*14-1:0] name);
        begin
            errors = 0;
            for (i = 0; i < M; i = i + 1) begin
                A_flat[i*W +: W] = ta[i];
                B_flat[i*W +: W] = tb[i];
                C_flat[i*W +: W] = tc[i];
            end
            op = o; len = n;
            @(negedge clk) start = 1;
            @(negedge clk) start = 0;
            t = 0;
            while (!done && t < 100) begin @(posedge clk); #1; t = t + 1; end
            if (!done) begin errors = errors + 1; $display("  TIMEOUT waiting for done"); end
            for (i = 0; i < M; i = i + 1) begin
                got = Y_flat[i*RW +: RW];
                if (i >= n) exp = 0;   // untouched lanes must read 0
                else case (o)
                    2'b00:   exp = ta[i] + tb[i];
                    2'b01:   exp = ta[i] * tb[i];
                    2'b10:   exp = ta[i] * tb[i] + tc[i];
                    default: exp = 0;
                endcase
                if (got !== exp) begin
                    errors = errors + 1;
                    $display("  MISMATCH idx %0d expected %0d actual %0d", i, exp, got);
                end
            end
            if (errors == 0) $display("TEST %0s : PASS", name);
            else             $display("TEST %0s : FAIL", name);
            total_errors = total_errors + errors;
            @(posedge clk); #1;
        end
    endtask
 
    task load(input integer a0, a1, a2, a3, b0, b1, b2, b3);
        begin
            for (k = 0; k < M; k = k + 1) begin ta[k] = 0; tb[k] = 0; tc[k] = 0; end
            ta[0]=a0; ta[1]=a1; ta[2]=a2; ta[3]=a3;
            tb[0]=b0; tb[1]=b1; tb[2]=b2; tb[3]=b3;
        end
    endtask
 
    integer r, rop, rlen;
    initial begin
        total_errors = 0;
        $display("========================================");
        $display("SIMD VECTOR PROCESSING ENGINE TEST");
        $display("========================================");
        repeat (3) @(posedge clk);
        rst = 0;
 
        load(10,20,30,40, 1,2,3,4);        run_test(2'b00, 4, "ADD");
        load(2,3,4,5, 5,4,3,2);            run_test(2'b01, 4, "MUL");
        load(3,-4,5,6, 7,8,-9,10);
        tc[0]=100; tc[1]=-50; tc[2]=7; tc[3]=-1000;  run_test(2'b10, 4, "MAC");
        load(1,2,3,4, 5,6,7,8);            run_test(2'b01, 3, "LENGTH 3");
        for (i = 0; i < 8; i = i + 1) begin ta[i] = i+1; tb[i] = 2*i; tc[i] = 3; end
                                           run_test(2'b10, 8, "LENGTH 8 MAC");
        for (i = 0; i < M; i = i + 1) begin ta[i] = i-8; tb[i] = 5-i; tc[i] = -i; end
                                           run_test(2'b10, 16, "LENGTH 16");
        load(9,9,9,9, 9,9,9,9);            run_test(2'b00, 0, "LENGTH 0");
        load(-5,-20,30,-40, 7,-3,-9,4);    run_test(2'b01, 4, "SIGNED MUL");
        load(-5,-20,30,-40, 7,-3,-9,4);    run_test(2'b00, 4, "SIGNED ADD");
        load(32767,-32768,32767,-32768, 32767,-32768,-32768,32767);
        tc[0]=32767; tc[1]=-32768; tc[2]=-32768; tc[3]=32767;
                                           run_test(2'b00, 4, "LIMITS ADD");
                                           run_test(2'b01, 4, "LIMITS MUL");
                                           run_test(2'b10, 4, "LIMITS MAC");
 
        for (r = 0; r < 40; r = r + 1) begin
            for (k = 0; k < M; k = k + 1) begin
                ta[k] = $random; tb[k] = $random; tc[k] = $random;
            end
            rop  = {$random} % 3;          // 0,1,2 (unsigned concat -> non-negative modulo)
            rlen = ({$random} % 16) + 1;   // 1..16
            run_test(rop[1:0], rlen[4:0], "RANDOM");
        end
 
        $display("========================================");
        if (total_errors == 0) $display("ALL TESTS PASSED");
        else                   $display("FAILED: %0d errors", total_errors);
        $display("========================================");
        $finish;
    end
endmodule
 
