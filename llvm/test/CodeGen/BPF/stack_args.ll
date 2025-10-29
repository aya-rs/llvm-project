; RUN: llc -mtriple=bpfel -mcpu=v2 < %s | FileCheck %s
; RUN: llc -mtriple=bpfeb -mcpu=v2 < %s | FileCheck %s
;
; Hand-written LLVM IR for the equivalent C snippet:
;   long stack_args_mix(long a0, long a1, long a2, long a3,
;                      long a4, long a5, long a6, long a7) {
;     return a5 + a6 + a7;
;   }
; using the experimental bpf stack calling convention where the last
; three arguments spill to the stack.

define bpf_stackcc i64 @stack_args_mix(i64 %a0, i64 %a1, i64 %a2, i64 %a3,
                                        i64 %a4, i64 %a5, i64 %a6, i64 %a7) {
; CHECK-LABEL: stack_args_mix:
; CHECK: r1 = *(u64 *)(r10 - 16)
; CHECK: r0 = *(u64 *)(r10 - 24)
; CHECK: r0 += r1
; CHECK: r1 = *(u64 *)(r10 - 8)
; CHECK: r0 += r1
; CHECK: exit
entry:
  %sum = add i64 %a5, %a6
  %res = add i64 %sum, %a7
  ret i64 %res
}
