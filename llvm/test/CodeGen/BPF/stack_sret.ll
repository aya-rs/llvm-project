; RUN: llc -mtriple=bpfel -mcpu=v2 < %s | FileCheck %s

%struct.S = type { i64, i64 }

; CHECK-LABEL: init:
; CHECK: *(u64 *)(r1 + 8) = r3
; CHECK: *(u64 *)(r1 + 0) = r2

define bpf_stackcc void @init(%struct.S* noalias sret(%struct.S) align 8 %out, i64 %x, i64 %y) {
entry:
  %p0 = getelementptr inbounds %struct.S, %struct.S* %out, i32 0, i32 0
  store i64 %x, i64* %p0, align 8
  %p1 = getelementptr inbounds %struct.S, %struct.S* %out, i32 0, i32 1
  store i64 %y, i64* %p1, align 8
  ret void
}

define bpf_stackcc void @call_init(%struct.S* noalias sret(%struct.S) align 8 %out, i64 %x, i64 %y) {
entry:
  %tmp = alloca %struct.S, align 8
  call bpf_stackcc void @init(%struct.S* sret(%struct.S) align 8 %tmp, i64 %x, i64 %y)
  %src0 = getelementptr inbounds %struct.S, %struct.S* %tmp, i32 0, i32 0
  %v0 = load i64, i64* %src0, align 8
  %dst0 = getelementptr inbounds %struct.S, %struct.S* %out, i32 0, i32 0
  store i64 %v0, i64* %dst0, align 8
  %src1 = getelementptr inbounds %struct.S, %struct.S* %tmp, i32 0, i32 1
  %v1 = load i64, i64* %src1, align 8
  %dst1 = getelementptr inbounds %struct.S, %struct.S* %out, i32 0, i32 1
  store i64 %v1, i64* %dst1, align 8
  ret void
}
; CHECK-LABEL: call_init:
; CHECK: r6 = r1
; CHECK: r1 = r10
; CHECK: r1 += -16
; CHECK: call init
; CHECK: r1 = *(u64 *)(r10 - 16)
; CHECK: *(u64 *)(r6 + 0) = r1
; CHECK: r1 = *(u64 *)(r10 - 8)
; CHECK: *(u64 *)(r6 + 8) = r1
