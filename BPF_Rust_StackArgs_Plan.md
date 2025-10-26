# BPF Stack Arguments Enablement Plan

## Goals
- Lift the 5-argument ceiling that blocks Rust BPF from Tier-2 while keeping existing C-centric ecosystems stable.
- Implement stack-argument lowering behind an opt-in switch that can later be made default once assumptions hold.
- Document legacy constraints so future maintainers know which questions to resolve before toggling the default.

## Current Understanding
- **Enforced Limit**: `llvm/lib/Target/BPF/BPFISelLowering.cpp` rejects stack arguments and caps calls at five registers.
- **Calling Convention**: `llvm/lib/Target/BPF/BPFCallingConv.td` does not currently spill, even though it hints stacks slots *could* exist.
- **Verifier Constraints**: Linux verifier bounds stack use to 512 bytes, interacts with helper ABI (still register-only).
- **Tests**: `llvm/test/CodeGen/BPF/many_args*.ll` hard-code the rejection behaviour; will need migration strategy.
- **Assumptions We Must Validate**:
  1. Kernel verifiers accept stack arguments for BPF-to-BPF calls when spills stay within frame bounds.
  2. Kernel helper ABI must remain register-only or gain an opt-in path; Rust must avoid breaking helper calls.
  3. Existing JITs/assemblers (libbpf, iproute2, tc, etc.) ignore or safely handle stack arguments emitted by LLVM.
  4. Frame layout interactions (prologue/epilogue, BTF emission, preserve_access_index) remain correct with extra stack traffic.

## Phase Plan
1. **Historical Survey**
   - Mine LLVM, Clang, and kernel commit history for rationale of the original restriction.
   - Gather kernel verifier documentation covering argument handling and stack limits.
   - Summarize in this document, aligning each fact with the numbered assumptions above.
2. **Design & Switch Definition**
   - Choose opt-in mechanism (new calling convention vs. function attribute) and prototype minimal lowering guarded by it.
   - Draft clear invariants for the opt-in switch; record them in a section below.
3. **Implementation**
   - Extend `BPFCallingConv.td`, `BPFISelLowering.cpp`, and frame lowering to spill/load extra args within guardrails.
   - Update or duplicate tests to cover both legacy rejection and opt-in success paths.
4. **Rust Integration**
   - Teach rustc to mark non-helper functions/calls with the opt-in switch.
   - Ensure helper shims remain register-only (may require intrinsics or attributes).
5. **Validation**
   - Unit tests via `llc`/Clang lit.
   - End-to-end evaluation with rustc + Linux VM via aya-rs integration suite.
6. **Default-Toggle Checklist**
   - Once assumptions 1-4 are satisfied, update this doc with evidence and flip the default.

## Resource Requests
1. **Repository Availability**
   - Ensure up-to-date clones of the Linux kernel (`~/src/linux`) and Rust compiler (`~/src/rust`) are available locally so I can inspect history and source.
2. **Deep Research Mediation**
   - When we identify targeted questions, run a ChatGPT “deep research” session using the prompt we craft together and share the result verbatim.
3. **E2E Test Harness**
   - When we reach the validation phase, help spin up the Linux VM + aya-rs integration harness and execute the scripted tests.

## Switch Guardrails (WIP)
- Opt-in identifier: _TBD_.
- Preconditions to enable by default:
  - [ ] Verified kernel version range supporting stack arguments.
  - [ ] Helper-call story documented and enforced.
  - [ ] External tool audit completed.
  - [ ] Performance and register pressure impact assessed.

## Phase 1 Notes (in progress)
- **Initial design intent (2015-01-24, commit e4c8c807bb609daa9be3fb9977703355b119fe8c)**
  - Introduced the backend with only register-based argument passing; diagnostics explicitly reject functions “defined with too many args” when CC analysis allocates a stack slot.
  - Commit message cites kernel verifier requirements and highlights that only R0–R10 registers are architecturally usable, with R1–R5 reserved for argument passing.
  - Tests `many_args1.ll`, `many_args2.ll`, and `byval.ll` were added alongside the backend to lock in the limitation on >5 arguments, stack slots, and by-value aggregates.
- **Calling convention description (same commit)**
  - `llvm/lib/Target/BPF/BPFCallingConv.td` assigns i64 arguments to `R1–R5`; the comment notes stack assignment is theoretically possible but “unsupported” (no lowering provided).
  - Varargs and struct returns are rejected in lowering because the verifier couldn’t guarantee safety under the initial model.
- **Stack size alignment with kernel verifier**
  - `llvm/lib/Target/BPF/BPFRegisterInfo.cpp` wires `-bpf-stack-size` default to 512 bytes, matching the kernel’s hard stack bound and emitting diagnostics if offsets exceed it. This reinforces the assumption that stack usage is tightly constrained and monitored.
- **Later clean-ups**
  - 2016-05-23 (commit b2da61196ea8491ef88b0325cf3dee963aface1c) introduced `MaxArgs = 5` to avoid crashes when extra args were present; behavior remained rejection rather than spilling.
  - 2023-07-31 (commit d542a56c1c2cc5d14a15aa6326e5a39414cd22e2) refactored diagnostics but kept the hard errors, confirming no functional change since the original design.
- **Kernel-side expectations**
  - `linux/Documentation/bpf/standardization/abi.rst` reiterates the calling convention: R1–R5 carry function arguments, R10 is the stack frame pointer, and R0 is the sole return register.
  - `linux/Documentation/bpf/bpf_design_QA.rst` states future support for more than five arguments is “NO”, citing the fixed ABI and reliance on helper calls.
  - `include/linux/filter.h` defines helper shim macros only up to `BPF_CALL_5`, and `include/linux/bpf.h` sets `MAX_BPF_FUNC_REG_ARGS` to 5, cementing the kernel helper ABI at five registers.
  - The verifier docs (`Documentation/bpf/verifier.rst`) specify stack accesses must stay within `[-MAX_BPF_STACK, 0)`, with `MAX_BPF_STACK` defined as 512 bytes in `include/linux/filter.h`; exceeding this limit triggers diagnostics.
  - `kernel/bpf/verifier.c:13021` rejects any helper or kfunc prototype whose arity exceeds `MAX_BPF_FUNC_REG_ARGS`, so the five-register assumption is baked into verifier semantics.
  - `kernel/bpf/verifier.c:10431-10435` shows callee frames inherit the caller’s stack (“callee can read/write into caller's stack”), so arguments spilled by the caller remain accessible down-stack; stack-depth accounting (`check_max_stack_depth`, `round_up_stack_depth`) spans the entire call chain.

## Phase 2: Opt-in Design (candidate)

### Mechanism
- Introduce a new LLVM calling-convention ID (`CallingConv::BPF_Stack`, exposed in IR as `bpf_stackcc`). When a function or call site is tagged with this ID, `BPFTargetLowering` is permitted to spill arguments to the stack once registers `R1–R5` are exhausted; otherwise behaviour matches today’s strict path.
- Existing C/BPF code continues to use `CallingConv::C`/`Fast` and remains unchanged.

### Invariants the opt-in CC must guarantee
1. **Scope**: Only BPF-to-BPF direct calls can use stack arguments; helper calls and trampolines must remain register-only. Ensure lowering reverts to register-only when callee is marked as helper (e.g., external symbol without opt-in CC).
2. **Stack depth**: Caller-reserved argument area + callee local stack must stay within `MAX_BPF_STACK`. We will define a per-call spill footprint function (e.g. `round_up(arg_bytes, 8)`) and add verifier-aligned comments documenting the bound.
3. **Frame layout**: Spilled arguments must live at negative offsets below the caller’s locals, matching verifier expectations that callees may read/write caller stack. Document the exact offset scheme (e.g. first spill at `-(local_size + 8)`).
4. **Register hygiene**: Ensure we preserve current behaviour for `R0`-`R5` in prologue/epilogue, and that stack-based args don’t clobber callee-saved registers usage recorded in `BPFCallLowering`.
5. **Helper segregation**: Confirm clang/rustc enforce that helper intrinsics remain on the old CC, preventing accidental emission of stack arguments to kernel helpers.

### LLVM touch points
- `llvm/lib/Target/BPF/BPFCallingConv.td`: confirm/adjust TableGen so the existing `CCAssignToStack<8,8>` entry is honoured for the new CC path (no change needed if we simply stop rejecting stack slots).
- `llvm/lib/Target/BPF/BPFISelLowering.cpp`:
  - Allow stack locs when the LLVM calling-convention ID is the new opt-in; compute offsets and generate loads/stores for spills.
  - Remove global `MaxArgs` check for opt-in CC while leaving existing path untouched.
  - Extend `LowerFormalArguments`, `LowerCall`, and `LowerReturn` to share spill-layout helpers.
- `llvm/lib/Target/BPF/BPFFrameLowering.cpp`: ensure frame setup accounts for extra argument area so prologue reserves sufficient space.

### Rust touch points
- Extend the BPF target spec to expose an opt-in feature flag (e.g., `+stack-args`).
- Update `compiler/rustc_codegen_llvm/src/abi.rs` so `to_llvm_calling_convention` maps `CanonAbi::Rust` to `CallingConv::BPFStack` when that feature is active; helpers and `extern "C"` continue to use `CallingConv::C`.
- Keep helper shims register-only (wrapper functions can marshal stack args into registers before invoking kernel helpers).

### Checklist before flipping default
- Kernel version matrix showing stack-argument usage validated on major architectures (x86 JIT, arm64 JIT, interpreter).
- Confirmation that libbpf/bpftool can load programs with new calling convention (no enforcement change needed).
- End-to-end integration tests (rustc + aya-rs) demonstrate success under opt-in mode.
- Documented instructions for clang users to opt in (even if unsupported) so the path isn’t Rust-only forever.
