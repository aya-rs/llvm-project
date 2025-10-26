; RUN: llc -mtriple=bpfel -mcpu=v2 < %s | FileCheck %s

define bpf_stackcc i64 @callee(i64 %a0, i64 %a1, i64 %a2, i64 %a3, i64 %a4,
                               i64 %a5, i64 %a6) {
; CHECK-LABEL: callee:
; CHECK: r1 = *(u64 *)(r10 - 8)
; CHECK: r0 = *(u64 *)(r10 - 16)
; CHECK: r0 += r1
  %sum = add i64 %a5, %a6
  ret i64 %sum
}

define bpf_stackcc i64 @caller(i64 %a0, i64 %a1, i64 %a2, i64 %a3, i64 %a4, i64 %a5,
                   i64 %a6) {
; CHECK-LABEL: caller:
; CHECK: r6 = *(u64 *)(r10 - 8)
; CHECK: *(u64 *)(r10 - 8) = r6
; CHECK: *(u64 *)(r10 - 16) = r0
; CHECK: call callee
  %call = call bpf_stackcc i64 @callee(i64 %a0, i64 %a1, i64 %a2, i64 %a3,
                                       i64 %a4, i64 %a5, i64 %a6)
  ret i64 %call
}
