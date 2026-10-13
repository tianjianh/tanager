// TileLink message types as the C++ models see them. Opcodes and parameters mirror tg_tl_pkg
// (TileLink 1.8.1; docs/spec/interfaces.md §2).
#pragma once

#include <cstdint>
#include <string>

namespace tg {

enum : uint8_t {
  A_PUT_FULL = 0, A_PUT_PARTIAL = 1, A_ARITH = 2, A_LOGIC = 3, A_GET = 4, A_INTENT = 5,
  A_ACQUIRE_BLOCK = 6, A_ACQUIRE_PERM = 7,
};
enum : uint8_t { B_PROBE_BLOCK = 6, B_PROBE_PERM = 7 };
enum : uint8_t { C_PROBE_ACK = 4, C_PROBE_ACK_DATA = 5, C_RELEASE = 6, C_RELEASE_DATA = 7 };
enum : uint8_t {
  D_ACCESS_ACK = 0, D_ACCESS_ACK_DATA = 1, D_GRANT = 4, D_GRANT_DATA = 5, D_RELEASE_ACK = 6,
};

// Permission parameters
enum : uint8_t { CAP_TO_T = 0, CAP_TO_B = 1, CAP_TO_N = 2 };                        // B probe, D grant
enum : uint8_t { GROW_N_TO_B = 0, GROW_N_TO_T = 1, GROW_B_TO_T = 2 };               // A acquire
enum : uint8_t {
  SHRINK_T_TO_B = 0, SHRINK_T_TO_N = 1, SHRINK_B_TO_N = 2,                          // C release, probe ack
  REPORT_T_TO_T = 3, REPORT_B_TO_B = 4, REPORT_N_TO_N = 5,                          // C probe ack
};

// Permissions a client holds on a line, ordered N < B < T.
enum perm_e : uint8_t { PERM_N = 0, PERM_B = 1, PERM_T = 2 };

constexpr unsigned BEAT_BYTES = 16;
constexpr unsigned LINE_BYTES = 64;
constexpr unsigned LINE_BEATS = LINE_BYTES / BEAT_BYTES;

struct beat_t {
  uint64_t d[2] = {0, 0};  // little-endian: d[0] = bytes 0..7 of the beat
};

struct tl_a_t {
  uint8_t opcode = 0, param = 0, size = 0;
  uint32_t source = 0;
  uint64_t address = 0;
  uint16_t mask = 0;
  beat_t data;
  bool corrupt = false;
  bool operator==(const tl_a_t& o) const {
    return opcode == o.opcode && param == o.param && size == o.size && source == o.source &&
           address == o.address && mask == o.mask && data.d[0] == o.data.d[0] &&
           data.d[1] == o.data.d[1] && corrupt == o.corrupt;
  }
};

struct tl_b_t {
  uint8_t opcode = 0, param = 0, size = 0;
  uint32_t source = 0;
  uint64_t address = 0;
};

struct tl_c_t {
  uint8_t opcode = 0, param = 0, size = 0;
  uint32_t source = 0;
  uint64_t address = 0;
  beat_t data;
  bool corrupt = false;
  bool operator==(const tl_c_t& o) const {
    return opcode == o.opcode && param == o.param && size == o.size && source == o.source &&
           address == o.address && data.d[0] == o.data.d[0] && data.d[1] == o.data.d[1] &&
           corrupt == o.corrupt;
  }
};

struct tl_d_t {
  uint8_t opcode = 0, param = 0, size = 0;
  uint32_t source = 0, sink = 0;
  bool denied = false;
  beat_t data;
  bool corrupt = false;
};

inline const char* a_op_name(unsigned op) {
  static const char* n[] = {"PutFullData", "PutPartialData", "ArithmeticData", "LogicalData",
                            "Get", "Intent", "AcquireBlock", "AcquirePerm"};
  return op < 8 ? n[op] : "?";
}
inline const char* c_op_name(unsigned op) {
  switch (op) {
    case C_PROBE_ACK: return "ProbeAck";
    case C_PROBE_ACK_DATA: return "ProbeAckData";
    case C_RELEASE: return "Release";
    case C_RELEASE_DATA: return "ReleaseData";
    default: return "?";
  }
}
inline const char* perm_name(unsigned p) { return p == PERM_T ? "T" : p == PERM_B ? "B" : "N"; }

// Beats a message with `size` (log2 bytes) takes on a 16-byte channel.
inline unsigned beats_of(unsigned size) {
  return size <= 4 ? 1u : (1u << size) / BEAT_BYTES;
}

}  // namespace tg
