# SPDX-License-Identifier: MIT
# cross-test settings profile for luajit.
#
# `cross-test` looks for this file at the root of the project it is run from
# (or names it with --profile; --no-profile ignores it). It is trusted Bash that
# the harness `source`s, so this file is *settings only*: ordinary variable
# assignments and nothing else. No command runs, no compiler is probed, and no
# path in here names a host.
#
# There is deliberately no CROSS_MATRIX. The published 53-platform Zig 0.16
# Tier 1/2 table is the matrix this package is checked against, and a matrix
# named here would replace it. There is no TARGETS array either, for the same
# reason: a subset selected here would narrow the run rather than add to it.
# Both belong on the command line, where --targets selects from the active
# matrix and never adds to it.
#
# CROSS_BUILD_STEP stays the standard `test` step, which this profile states
# explicitly. There are no `cross_build_command` / `cross_artifact` hooks here,
# so the harness keeps its standard Zig-build mode and runs
# `zig build test -Dtarget=TARGET` per target with a fresh cache. What that
# means for a given target is the harness's decision, not this package's: a
# host target runs, a foreign target runs under whatever executor the harness
# detects (QEMU user mode, Wine, wasmtime), and a foreign target with no
# executor is reported as build-only coverage -- compiled, never executed, and
# never counted as a pass. `build.zig` gives the test binary a Run step for
# every target, which is what leaves that choice open.
#
# ## What a target's graph costs here
#
# Unlike most packages in this workspace, a LuaJIT target graph builds **host**
# programs and runs them, four times over, before it compiles anything for the
# target:
#
#   * `luajit-minilua` from `src/host/minilua.c` -- a 170 KB single-file
#     amalgamation of Lua 5.1.5, which is by far the slowest single compile in
#     the graph;
#   * `genversion` and `dynasm`, both of which run that interpreter;
#   * `luajit-buildvm`, built against the two files just generated, which
#     compiles five `lj_*.h` internals plus the DynASM backend;
#   * six `buildvm` invocations, which scan the library sources and write the
#     VM, `lj_bcdef.h`, `lj_ffdef.h`, `lj_libdef.h`, `lj_recdef.h`,
#     `lj_folddef.h` and `jit/vmdef.lua`;
#   * and only then the 68 target translation units of `libluajit-5.1` plus
#     `lj_vm.S`.
#
# Two of those six invocations scan the same twelve library sources, and three
# run programs over the same text, so a cell is much longer than a single-header
# package's. Three jobs are therefore not enough to keep a core busy; eight keep
# the generator chain overlapped without oversubscribing the machine the
# harness is sharing.
#
# ## Architectures LuaJIT 2.1 does not support
#
# The published table contains targets whose CPU architecture is not in the
# chain at `lj_arch.h:54-70` -- RISC-V and WebAssembly among them. What this
# harness runs, `zig build test -Dtarget=TARGET`, gives those no
# architecture-refusal check: `build.zig:310-317` turns `abi.select`'s
# `error.ArchitectureNotSupported` (`abi.zig:312-313`) into a
# `std.debug.panic` while the build function is still running, so the cell
# dies during configuration and its build is reported failed. Observed in the
# 20261004-232427 matrix run: `thread N panic: luajit: <arch>: Architecture not
# supported (in this version) ... (lj_arch.h:69)` for hexagon-linux,
# riscv32-linux and armeb-linux.
#
# That is a build failure and nothing more. It is not a pass, not build-only
# coverage, and not a refusal this package observed and accepted. The refusal
# check the graph does own -- `addArchitectureRefusalCheck`
# (`build.zig:761-813`) -- belongs to the `check` step (`build.zig:475-479`),
# which this harness does not run. A cell in this class is read from its own
# log; the matrix must not report it as coverage of that target.
#
# The timeouts below are sized for the real cells, and a cell that dies at
# configuration like this one takes almost nothing, so it cannot be mistaken
# for a hang.
#
# ## Emulation is enabled for every cell
#
# A 32-bit target needs a 32-bit `buildvm`, so this package builds a generator
# of the build machine's own family at that width (`generatorHostTarget` in
# `build_support/graph.zig`). On Linux that generator links statically, so it
# has no loader to look for, but the build machine's kernel need not run the
# family's 32-bit execution mode at all: one observed here refuses a direct
# 32-bit ELF with exit 126, with `CONFIG_IA32_EMULATION` compiled in and
# disabled by default. The same static generator runs to completion under the
# qemu-user binary its CPU architecture names, which is what `-fqemu` asks for.
#
# Without it the sixteen 32-bit cells stop before compiling anything, so the
# profile asks for it here: `CROSS_BUILD_ARGS` is settings, it is appended to
# the `zig build` line every cell runs, and it is the only switch this file
# sets that changes what a cell does rather than how long it may take. It is an
# opt-in for real emulation, never a substitute executor: a cell still runs
# under qemu or not at all, and a cell with no usable interpreter stays
# build-only.

CROSS_BUILD_STEP=test
CROSS_BUILD_ARGS=(-fqemu)
CROSS_BUILD_JOBS=8
CROSS_BUILD_TIMEOUT=3600
CROSS_TIMEOUT=1800