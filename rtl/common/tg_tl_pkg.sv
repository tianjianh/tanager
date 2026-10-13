// TileLink channel types for the core <-> L2 / MMIO ports (docs/spec/interfaces.md §2).
// Message semantics, opcodes and permission parameters follow the public TileLink spec 1.8.1.
// Fields TileLink defines but we never use on a channel are omitted (noted per struct).
package tg_tl_pkg;
  import tg_pkg::*;

  localparam int LINE_BYTES = 64;
  localparam int TL_ADDR_W  = PA_W;
  localparam int TL_DATA_W  = 128;                     // one beat; 4 beats per line
  localparam int TL_MASK_W  = TL_DATA_W / 8;
  localparam int TL_BEATS   = LINE_BYTES * 8 / TL_DATA_W;
  localparam int TL_SIZE_W  = 3;                       // log2(bytes), up to 128 B
  localparam int TL_SRC_W   = 10;                      // core drives [5:0]; the interconnect owns [9:6]
  localparam int TL_SRC_LOCAL_W = 6;
  localparam int TL_SINK_W  = 6;

  typedef enum logic [2:0] {
    A_PUT_FULL      = 3'd0,
    A_PUT_PARTIAL   = 3'd1,
    A_ARITH         = 3'd2,  // not used
    A_LOGIC         = 3'd3,  // not used
    A_GET           = 3'd4,
    A_INTENT        = 3'd5,  // not used
    A_ACQUIRE_BLOCK = 3'd6,
    A_ACQUIRE_PERM  = 3'd7
  } tl_a_op_e;

  typedef enum logic [2:0] {
    B_PROBE_BLOCK = 3'd6,
    B_PROBE_PERM  = 3'd7
  } tl_b_op_e;

  typedef enum logic [2:0] {
    C_PROBE_ACK      = 3'd4,
    C_PROBE_ACK_DATA = 3'd5,
    C_RELEASE        = 3'd6,
    C_RELEASE_DATA   = 3'd7
  } tl_c_op_e;

  typedef enum logic [2:0] {
    D_ACCESS_ACK      = 3'd0,
    D_ACCESS_ACK_DATA = 3'd1,
    D_GRANT           = 3'd4,
    D_GRANT_DATA      = 3'd5,
    D_RELEASE_ACK     = 3'd6
  } tl_d_op_e;

  // Permission parameters
  localparam logic [2:0] TL_CAP_TO_T = 3'd0, TL_CAP_TO_B = 3'd1, TL_CAP_TO_N = 3'd2;      // B probe, D grant
  localparam logic [2:0] TL_GROW_N_TO_B = 3'd0, TL_GROW_N_TO_T = 3'd1, TL_GROW_B_TO_T = 3'd2; // A acquire
  localparam logic [2:0] TL_SHRINK_T_TO_B = 3'd0, TL_SHRINK_T_TO_N = 3'd1, TL_SHRINK_B_TO_N = 3'd2, // C release, probe ack
                         TL_REPORT_T_TO_T = 3'd3, TL_REPORT_B_TO_B = 3'd4, TL_REPORT_N_TO_N = 3'd5;  // C probe ack

  typedef struct packed {
    tl_a_op_e               opcode;
    logic [2:0]             param;
    logic [TL_SIZE_W-1:0]   size;
    logic [TL_SRC_W-1:0]    source;
    logic [TL_ADDR_W-1:0]   address;
    logic [TL_MASK_W-1:0]   mask;
    logic [TL_DATA_W-1:0]   data;
    logic                   corrupt;
  } tl_a_t;

  // Probes only: TileLink's mask, data and corrupt are omitted.
  typedef struct packed {
    tl_b_op_e               opcode;
    logic [2:0]             param;
    logic [TL_SIZE_W-1:0]   size;
    logic [TL_SRC_W-1:0]    source;
    logic [TL_ADDR_W-1:0]   address;
  } tl_b_t;

  typedef struct packed {
    tl_c_op_e               opcode;
    logic [2:0]             param;
    logic [TL_SIZE_W-1:0]   size;
    logic [TL_SRC_W-1:0]    source;
    logic [TL_ADDR_W-1:0]   address;
    logic [TL_DATA_W-1:0]   data;
    logic                   corrupt;
  } tl_c_t;

  typedef struct packed {
    tl_d_op_e               opcode;
    logic [1:0]             param;
    logic [TL_SIZE_W-1:0]   size;
    logic [TL_SRC_W-1:0]    source;
    logic [TL_SINK_W-1:0]   sink;
    logic                   denied;
    logic [TL_DATA_W-1:0]   data;
    logic                   corrupt;
  } tl_d_t;

  typedef struct packed {
    logic [TL_SINK_W-1:0]   sink;
  } tl_e_t;
endpackage
