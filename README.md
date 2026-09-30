# Configurable Pipelined SIMD Vector Processing Engine

## Overview
A parameterized Verilog RTL design that performs parallel vector arithmetic using multiple Processing Elements (PEs). The engine supports pipelined execution and configurable data width, lane count, and vector length.

## Features
- Configurable data width, number of lanes, and vector length
- Parallel Processing Elements (PEs)
- ADD, MUL, and MAC operations
- Pipelined datapath
- FSM-based control
- Input and output buffering
- Signed arithmetic support

## Architecture

                 Input Vectors
                  A / B / C
                      |
                Input Buffers
                      |
        +------+------+------+------+
        |      |      |      |
       PE0    PE1    PE2    PE3
        |      |      |      |
        +------+------+------+------+
                      |
                Output Buffer
                      |
                 Output Vector

## Verification
The design was verified using a Verilog testbench covering:
- ADD, MUL and MAC operations
- Signed arithmetic
- Variable vector lengths
- Boundary cases
- Randomized inputs

All implemented test cases passed in Xilinx XSim.

## Tools
**HDL:** Verilog  
**Simulation:** Xilinx XSim  
**EDA Tool:** Xilinx Vivado

## Files
`top.v` — Complete RTL design

`tb.v` - Testbench
