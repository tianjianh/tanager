/* A small bytecode interpreter for M9's indirect-target predictor (docs/spec/m9-plan.md, fpu-2's question, 10-23): a
   stack machine running a loop of arithmetic, compares, a data-dependent branch and a call, dispatched as Lua's or
   Python's main loop is. THREADED 0: a switch in a loop, so one indirect jump (the jump table's) takes every opcode;
   1: computed goto, an indirect jump at the end of every opcode's handler, as CPython builds with GCC. The program
   runs N iterations; REPS runs of it in the region. The program is read through a volatile pointer: with a constant
   program in view, GCC took run() for a constant function and left the region all but empty. */
#include "memsuite.h"
#ifndef THREADED
#define THREADED 0
#endif
#ifndef N
#define N 1000
#endif
#ifndef REPS
#define REPS 8
#endif

enum { PUSHI, LOAD, STORE, ADD, SUB, MUL, AND, XOR, SHR, LT, JZ, JMP, DUP, CALL, RET, HALT };

/* i = 0; acc = 0; while (i < N) { t = i * 7 + 3; acc = t & 1 ? acc + (t >> 1) : acc - (t & 15);
   acc = f(acc); i++; }   with f(x) = x ^ (x >> 3) */
static int program[] = {
  PUSHI, 0, STORE, 0, PUSHI, 0, STORE, 1,                        /* 0: i = 0; acc = 0 */
  LOAD, 0, PUSHI, N, LT, JZ, 68,                                 /* 8: loop: if !(i < N) goto end */
  LOAD, 0, PUSHI, 7, MUL, PUSHI, 3, ADD, DUP, STORE, 2,          /* 15: t = i * 7 + 3 */
  PUSHI, 1, AND, JZ, 43,                                         /* 26: if !(t & 1) goto even */
  LOAD, 1, LOAD, 2, PUSHI, 1, SHR, ADD, STORE, 1, JMP, 53,       /* 31: acc += t >> 1; goto join */
  LOAD, 1, LOAD, 2, PUSHI, 15, AND, SUB, STORE, 1,               /* 43: even: acc -= t & 15 */
  LOAD, 1, CALL, 69, STORE, 1,                                   /* 53: join: acc = f(acc) */
  LOAD, 0, PUSHI, 1, ADD, STORE, 0, JMP, 8,                      /* 59: i++; goto loop */
  HALT,                                                          /* 68: end */
  DUP, PUSHI, 3, SHR, XOR, RET,                                  /* 69: f */
};
static int *volatile prog = program;

static long __attribute__((noinline)) run(const int *code) {
  long stack[16], vars[4] = {0, 0, 0, 0};
  int rets[8], sp = 0, rp = 0, pc = 0;
#if THREADED
  static void *const op[] = {&&L_PUSHI, &&L_LOAD, &&L_STORE, &&L_ADD, &&L_SUB, &&L_MUL, &&L_AND, &&L_XOR,
                             &&L_SHR, &&L_LT, &&L_JZ, &&L_JMP, &&L_DUP, &&L_CALL, &&L_RET, &&L_HALT};
#define NEXT goto *op[code[pc++]]
  NEXT;
L_PUSHI: stack[sp++] = code[pc++]; NEXT;
L_LOAD: stack[sp++] = vars[code[pc++]]; NEXT;
L_STORE: vars[code[pc++]] = stack[--sp]; NEXT;
L_ADD: sp--; stack[sp - 1] += stack[sp]; NEXT;
L_SUB: sp--; stack[sp - 1] -= stack[sp]; NEXT;
L_MUL: sp--; stack[sp - 1] *= stack[sp]; NEXT;
L_AND: sp--; stack[sp - 1] &= stack[sp]; NEXT;
L_XOR: sp--; stack[sp - 1] ^= stack[sp]; NEXT;
L_SHR: sp--; stack[sp - 1] >>= stack[sp]; NEXT;
L_LT: sp--; stack[sp - 1] = stack[sp - 1] < stack[sp]; NEXT;
L_JZ: { int t = code[pc++]; if (!stack[--sp]) pc = t; } NEXT;
L_JMP: pc = code[pc]; NEXT;
L_DUP: stack[sp] = stack[sp - 1]; sp++; NEXT;
L_CALL: rets[rp++] = pc + 1; pc = code[pc]; NEXT;
L_RET: pc = rets[--rp]; NEXT;
L_HALT: return vars[1];
#else
  for (;;) {
    switch (code[pc++]) {
      case PUSHI: stack[sp++] = code[pc++]; break;
      case LOAD: stack[sp++] = vars[code[pc++]]; break;
      case STORE: vars[code[pc++]] = stack[--sp]; break;
      case ADD: sp--; stack[sp - 1] += stack[sp]; break;
      case SUB: sp--; stack[sp - 1] -= stack[sp]; break;
      case MUL: sp--; stack[sp - 1] *= stack[sp]; break;
      case AND: sp--; stack[sp - 1] &= stack[sp]; break;
      case XOR: sp--; stack[sp - 1] ^= stack[sp]; break;
      case SHR: sp--; stack[sp - 1] >>= stack[sp]; break;
      case LT: sp--; stack[sp - 1] = stack[sp - 1] < stack[sp]; break;
      case JZ: { int t = code[pc++]; if (!stack[--sp]) pc = t; } break;
      case JMP: pc = code[pc]; break;
      case DUP: stack[sp] = stack[sp - 1]; sp++; break;
      case CALL: rets[rp++] = pc + 1; pc = code[pc]; break;
      case RET: pc = rets[--rp]; break;
      default: return vars[1];
    }
  }
#endif
}

int main(void) {
  long sum = run(prog);   /* warm */
  tg_region_start();
  for (int r = 0; r < REPS; r++) sum += run(prog);
  tg_region_stop();
  printf("interp threaded=%d n=%d check=%ld\n", THREADED, N, sum);
  return 0;
}
