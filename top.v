`timescale 1ns / 1ps

//================================================
// SYNTHESIZABLE DESIGN
// Configurable 4-Lane SIMD Vector Processing Engine
// Data: signed. RESULT_WIDTH = 2*DATA_WIDTH+1 (MUL needs 2W bits, MAC adds C -> 2W+1, no truncation)
// Operation: 2'b00 ADD, 2'b01 MUL, 2'b10 MAC (A*B+C), 2'b11 -> 0
// Vectors are flattened: element i = A_flat[i*DATA_WIDTH +: DATA_WIDTH]
// Pipeline timing for a group issued in cycle t (group_cnt = g, issue_valid = 1):
//   t   : lane operands muxed from input buffers (combinational)
//   t+1 : S1 - PE input regs hold operands; v1=1, g1=g   (PE computes combinationally from them)
//   t+2 : S2 - PE result reg y valid;         v2=1, g2=g (pe_result and its group tag arrive together)
//   t+3 : S3 - output_buffer holds the group  (written at the end of cycle t+2)
// So v1/v2/g1/g2 are delayed copies of issue_valid/group_cnt in lockstep with the PE registers.
// start is only accepted in IDLE; the pipeline is always empty in IDLE (DRAIN waits for v1=v2=0),
// so clearing output_buffer on start can never race with an in-flight result.
// vector_length = 0: no groups are issued, FSM goes COMPUTE->DRAIN->DONE, Y reads all zeros.
// vector_length > MAX_VECTOR_LENGTH is clamped to MAX_VECTOR_LENGTH.
// Handshake: start (1 cycle pulse in IDLE) -> busy=1 -> done=1 for exactly 1 cycle (busy=0) -> IDLE.
// Result Y holds stable after done until next start (cleared on next start) or reset.
//================================================

// One Processing Element: input regs -> arithmetic -> result reg
module simd_pe #(
    parameter W  = 16,
    parameter RW = 33
)(
    input  clk,
    input  rst,
    input  [1:0] op,
    input  signed [W-1:0] a, b, c,
    output reg signed [RW-1:0] y
);
    reg signed [W-1:0] a_r, b_r, c_r;   // stage 1
    reg [1:0] op_r;
    always @(posedge clk) begin
        if (rst) begin
            a_r <= 0; b_r <= 0; c_r <= 0; op_r <= 0; y <= 0;
        end else begin
            a_r <= a; b_r <= b; c_r <= c; op_r <= op;
            case (op_r)                  // stage 2
                2'b00:   y <= a_r + b_r;
                2'b01:   y <= a_r * b_r;
                2'b10:   y <= a_r * b_r + c_r;
                default: y <= 0;
            endcase
        end
    end
endmodule

module simd_vector_engine #(
    parameter DATA_WIDTH        = 16,
    parameter LANES             = 4,
    parameter MAX_VECTOR_LENGTH = 16,
    parameter RESULT_WIDTH      = 2*DATA_WIDTH + 1
)(
    input  clk,
    input  rst,
    input  start,
    input  [1:0] operation,
    input  [4:0] vector_length,
    input  [DATA_WIDTH*MAX_VECTOR_LENGTH-1:0]   A_flat,
    input  [DATA_WIDTH*MAX_VECTOR_LENGTH-1:0]   B_flat,
    input  [DATA_WIDTH*MAX_VECTOR_LENGTH-1:0]   C_flat,
    output reg busy,
    output reg done,
    output [RESULT_WIDTH*MAX_VECTOR_LENGTH-1:0] Y_flat
);
    localparam IDLE = 2'd0, COMPUTE = 2'd1, DRAIN = 2'd2, DONE = 2'd3;

    reg [1:0] state, next_state;

    // input buffers (captured at start)
    reg [DATA_WIDTH*MAX_VECTOR_LENGTH-1:0] input_buffer_a, input_buffer_b, input_buffer_c;
    reg [1:0] op_r;
    reg [4:0] len_r;
    // output buffer
    reg [RESULT_WIDTH*MAX_VECTOR_LENGTH-1:0] output_buffer;
    assign Y_flat = output_buffer;

    wire [5:0] len_sum  = len_r + LANES - 1;   // 6 bits: max 16+LANES-1 cannot overflow for LANES<=16
    wire [4:0] ngroups  = len_sum / LANES;     // ceil(len_r / LANES)
    reg  [4:0] group_cnt;
    wire issue_valid = (state == COMPUTE) && (group_cnt < ngroups);

    // pipeline tags aligned with PE stages
    reg v1, v2;
    reg [4:0] g1, g2;

    // lane operand mux (elements beyond vector length are zeroed)
    reg [DATA_WIDTH*LANES-1:0] lane_a, lane_b, lane_c;
    integer l, mi, idx;
    always @(*) begin
        lane_a = 0; lane_b = 0; lane_c = 0;
        for (mi = 0; mi < LANES; mi = mi + 1) begin
            if (group_cnt*LANES + mi < len_r) begin
                lane_a[mi*DATA_WIDTH +: DATA_WIDTH] = input_buffer_a[(group_cnt*LANES+mi)*DATA_WIDTH +: DATA_WIDTH];
                lane_b[mi*DATA_WIDTH +: DATA_WIDTH] = input_buffer_b[(group_cnt*LANES+mi)*DATA_WIDTH +: DATA_WIDTH];
                lane_c[mi*DATA_WIDTH +: DATA_WIDTH] = input_buffer_c[(group_cnt*LANES+mi)*DATA_WIDTH +: DATA_WIDTH];
            end
        end
    end

    // LANES parallel processing elements
    wire [RESULT_WIDTH*LANES-1:0] pe_result;
    genvar gl;
    generate
        for (gl = 0; gl < LANES; gl = gl + 1) begin : PE
            simd_pe #(.W(DATA_WIDTH), .RW(RESULT_WIDTH)) u_pe (
                .clk(clk), .rst(rst), .op(op_r),
                .a(lane_a[gl*DATA_WIDTH +: DATA_WIDTH]),
                .b(lane_b[gl*DATA_WIDTH +: DATA_WIDTH]),
                .c(lane_c[gl*DATA_WIDTH +: DATA_WIDTH]),
                .y(pe_result[gl*RESULT_WIDTH +: RESULT_WIDTH])
            );
        end
    endgenerate

    // FSM
    always @(posedge clk) begin
        if (rst) state <= IDLE;
        else     state <= next_state;
    end

    always @(*) begin
        next_state = state;
        case (state)
            IDLE:    if (start) next_state = COMPUTE;
            COMPUTE: if (group_cnt + 1 >= ngroups) next_state = DRAIN;  // last group issued
            DRAIN:   if (!v1 && !v2) next_state = DONE;                 // pipeline empty
            DONE:    next_state = IDLE;
        endcase
    end

    always @(*) begin
        busy = (state == COMPUTE) || (state == DRAIN);
        done = (state == DONE);
    end

    // input capture, group counter, pipeline tags
    always @(posedge clk) begin
        if (rst) begin
            input_buffer_a <= 0; input_buffer_b <= 0; input_buffer_c <= 0;
            op_r <= 0; len_r <= 0; group_cnt <= 0;
            v1 <= 0; v2 <= 0; g1 <= 0; g2 <= 0;
        end else begin
            if (state == IDLE && start) begin
                input_buffer_a <= A_flat;
                input_buffer_b <= B_flat;
                input_buffer_c <= C_flat;
                op_r  <= operation;
                len_r <= (vector_length > MAX_VECTOR_LENGTH) ? MAX_VECTOR_LENGTH : vector_length;
                group_cnt <= 0;
            end else if (issue_valid) begin
                group_cnt <= group_cnt + 1;
            end
            v1 <= issue_valid; g1 <= group_cnt;
            v2 <= v1;          g2 <= g1;
        end
    end

    // stage 3: output buffer write
    always @(posedge clk) begin
        if (rst || (state == IDLE && start))
            output_buffer <= 0;
        else if (v2) begin
            for (l = 0; l < LANES; l = l + 1) begin
                idx = g2*LANES + l;
                if (idx < len_r)
                    output_buffer[idx*RESULT_WIDTH +: RESULT_WIDTH] <= pe_result[l*RESULT_WIDTH +: RESULT_WIDTH];
            end
        end
    end
endmodule

