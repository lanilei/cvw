///////////////////////////////////////////
// abhmulticontroller
//
// Written: Ross Thompson August 29, 2022
// ross1728@gmail.com
// Modified: 
//
// Purpose: AHB multi controller interface to merge LSU and IFU controls.
//          See ARM_HIH0033A_AMBA_AHB-Lite_SPEC 1.0
//          Arbitrates requests from instruction and data streams
//          Connects core to peripherals and I/O pins on SOC
//          Bus width presently matches XLEN
//          Anticipate replacing this with an AXI bus interface to communicate with FPGA DRAM/Flash controllers
// 
// A component of the Wally configurable RISC-V project.
// 
// Copyright (C) 2021 Harvey Mudd College & Oklahoma State University
//
// MIT LICENSE
// Permission is hereby granted, free of charge, to any person obtaining a copy of this 
// software and associated documentation files (the "Software"), to deal in the Software 
// without restriction, including without limitation the rights to use, copy, modify, merge, 
// publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons 
// to whom the Software is furnished to do so, subject to the following conditions:
//
//   The above copyright notice and this permission notice shall be included in all copies or 
//   substantial portions of the Software.
//
//   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, 
//   INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR 
//   PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS 
//   BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, 
//   TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE 
//   OR OTHER DEALINGS IN THE SOFTWARE.
////////////////////////////////////////////////////////////////////////////////////////////////

`include "wally-config.vh"

module ebu
  (
   input logic                clk, reset,
   // Signals from IFU
   input logic [`PA_BITS-1:0] IFUHADDR, 
   input logic [2:0]          IFUHSIZE,
   input logic [2:0]          IFUHBURST,
   input logic [1:0]          IFUHTRANS,
   output logic               IFUHREADY, 
   // Signals from LSU
   input logic [`PA_BITS-1:0] LSUHADDR,
   input logic [`XLEN-1:0]    LSUHWDATA, // initially support AHBW = XLEN
   input logic [`XLEN/8-1:0]  LSUHWSTRB,
   input logic [2:0]          LSUHSIZE,
   input logic [2:0]          LSUHBURST,
   input logic [1:0]          LSUHTRANS,
   input logic                LSUHWRITE,
   output logic               LSUHREADY,
   // add LSUHWSTRB ***
  
   // AHB-Lite external signals
   (* mark_debug = "true" *) input logic HREADY, HRESP,
   (* mark_debug = "true" *) output logic HCLK, HRESETn,
   (* mark_debug = "true" *) output logic [`PA_BITS-1:0] HADDR, // *** one day switch to a different bus that supports the full physical address
   (* mark_debug = "true" *) output logic [`AHBW-1:0] HWDATA,
   (* mark_debug = "true" *) output logic [`XLEN/8-1:0] HWSTRB,
   (* mark_debug = "true" *) output logic HWRITE, 
   (* mark_debug = "true" *) output logic [2:0] HSIZE,
   (* mark_debug = "true" *) output logic [2:0] HBURST,
   (* mark_debug = "true" *) output logic [3:0] HPROT,
   (* mark_debug = "true" *) output logic [1:0] HTRANS,
   (* mark_debug = "true" *) output logic HMASTLOCK
   );

  typedef enum                logic [1:0] {IDLE, ARBITRATE} statetype;
  statetype CurrState, NextState;

  logic [1:0]                 save, restore, dis, sel;
  logic                       both;

  logic [`PA_BITS-1:0]        IFUHADDROut;
  logic [1:0]                 IFUHTRANSOut;
  logic [2:0]                 IFUHBURSTOut;
  logic [2:0]                 IFUHSIZEOut;
  logic                       IFUHWRITEOut;
  
  logic [`PA_BITS-1:0]        LSUHADDROut;
  logic [1:0]                 LSUHTRANSOut;
  logic [2:0]                 LSUHBURSTOut;
  logic [2:0]                 LSUHSIZEOut;
  logic                       LSUHWRITEOut;

  logic                       IFUReq, LSUReq;
  logic                       IFUActive, LSUActive;

  logic                       BeatCntEn;
  logic [4-1:0]               NextBeatCount, BeatCount, BeatCountDelayed;
  logic                       FinalBeat;
  logic [2:0]                 LocalBurstType;
  logic                       CntReset;
  logic [3:0]                 Threshold;
  logic                       IFUReqD;
  
  
  assign HCLK = clk;
  assign HRESETn = ~reset;


  // if two requests come in at once pick one to select and save the others Address phase
  // inputs.  Abritration scheme is LSU always goes first.

  // input stage IFU
  controllerinputstage IFUInput(.HCLK, .HRESETn, .Save(save[0]), .Restore(restore[0]), .Disable(dis[0]),
    .Request(IFUReq), .Active(IFUActive),
    .HWRITEin(1'b0), .HSIZEin(IFUHSIZE), .HBURSTin(IFUHBURST), .HTRANSin(IFUHTRANS), .HADDRin(IFUHADDR),
    .HWRITEOut(IFUHWRITEOut), .HSIZEOut(IFUHSIZEOut), .HBURSTOut(IFUHBURSTOut), .HREADYOut(IFUHREADY),
    .HTRANSOut(IFUHTRANSOut), .HADDROut(IFUHADDROut), .HREADYin(HREADY));

  // input stage LSU
  // LSU always has priority so there should never be a need to save and restore the address phase inputs.
  controllerinputstage LSUInput(.HCLK, .HRESETn, .Save(save[1]), .Restore(restore[1]), .Disable(dis[1]),
    .Request(LSUReq), .Active(LSUActive),
    .HWRITEin(LSUHWRITE), .HSIZEin(LSUHSIZE), .HBURSTin(LSUHBURST), .HTRANSin(LSUHTRANS), .HADDRin(LSUHADDR), .HREADYOut(LSUHREADY),
    .HWRITEOut(LSUHWRITEOut), .HSIZEOut(LSUHSIZEOut), .HBURSTOut(LSUHBURSTOut),
    .HTRANSOut(LSUHTRANSOut), .HADDROut(LSUHADDROut), .HREADYin(HREADY));

  // output mux //*** rewrite for general number of controllers.
  assign HADDR = sel[1] ? LSUHADDROut : sel[0] ? IFUHADDROut : '0;
  assign HSIZE = sel[1] ? LSUHSIZEOut : sel[0] ? IFUHSIZEOut: '0; 
  assign HBURST = sel[1] ? LSUHBURSTOut : sel[0] ? IFUHBURSTOut : '0; // If doing memory accesses, use LSUburst, else use Instruction burst.
  assign HTRANS = sel[1] ? LSUHTRANSOut : sel[0] ? IFUHTRANSOut: '0; // SEQ if not first read or write, NONSEQ if first read or write, IDLE otherwise
  assign HWRITE = sel[1] ? LSUHWRITEOut : sel[0] ? 1'b0 : '0;
  assign HPROT = 4'b0011; // not used; see Section 3.7
  assign HMASTLOCK = 0; // no locking supported

  // data phase muxing.  This would be a mux if IFU wrote data.
  assign HWDATA = LSUHWDATA;
  assign HWSTRB = LSUHWSTRB;
  // HRDATA is sent to all controllers at the core level.

  // FSM decides if arbitration needed.  Arbitration is held until the last beat of
  // a burst is completed.
  assign both = LSUActive & IFUActive;
  flopenl #(.TYPE(statetype)) busreg(HCLK, ~HRESETn, 1'b1, NextState, IDLE, CurrState);
  always_comb 
    case (CurrState) 
      IDLE: if (both)                    NextState = ARBITRATE; 
      else                               NextState = IDLE;
      ARBITRATE: if (HREADY & FinalBeat & ~(LSUReq & IFUReq)) NextState = IDLE;
      else                               NextState = ARBITRATE;
      default:                           NextState = IDLE;
    endcase

  // This part is only used when burst mode is supported.
  // Controller needs to count beats.
  flopenr #(4) 
  BeatCountReg(.clk(HCLK),
		.reset(~HRESETn | CntReset | FinalBeat),
		.en(BeatCntEn),
		.d(NextBeatCount),
		.q(BeatCount));  
  
  // Used to store data from data phase of AHB.
  flopenr #(4) 
  BeatCountDelayedReg(.clk(HCLK),
		.reset(~HRESETn | CntReset),
		.en(BeatCntEn),
		.d(BeatCount),
		.q(BeatCountDelayed));
  assign NextBeatCount = BeatCount + 1'b1;

  assign CntReset = NextState == IDLE;
  assign FinalBeat = (BeatCountDelayed == Threshold); // Detect when we are waiting on the final access.
  assign BeatCntEn = (NextState == ARBITRATE & HREADY);

  logic [2:0]                 HBURSTD;
  
  flopenr #(3) HBURSTReg(.clk(HCLK), .reset(~HRESETn), .en(HTRANS == 2'b10), .d(HBURST), .q(HBURSTD));

  // unlike the bus fsm in lsu/ifu, we need to derive the number of beats from HBURST.
  always_comb begin
    case(HBURSTD)
      0:        Threshold = 4'b0000;
      3:        Threshold = 4'b0011; // INCR4
      5:        Threshold = 4'b0111; // INCR8
      7:        Threshold = 4'b1111; // INCR16
      default:  Threshold = 4'b0000; // INCR without end.
    endcase
  end
  // end of burst mode.
  
  // basic arb always selects LSU when both
  // replace this block for more sophisticated arbitration as needed.
  // Controller 0 (IFU)
  assign save[0] = CurrState == IDLE & both;
  assign restore[0] = CurrState == ARBITRATE;
  assign dis[0] = CurrState == ARBITRATE;
  assign sel[0] = (NextState == ARBITRATE) ? 1'b0 : IFUReq;
  // Controller 1 (LSU)
  assign save[1] = 1'b0;
  assign restore[1] = 1'b0;
  assign dis[1] = CurrState == ARBITRATE ? 1'b0 : (IFUReqD & ~(HREADY & FinalBeat));
  assign sel[1] = NextState == ARBITRATE ? 1'b1: LSUReq;

  flopr #(1) ifureqreg(clk, ~HRESETn, IFUReq, IFUReqD);
  

endmodule
