# Compiler wrappers

Build-time only. These never enter the shipped tarball.

`generate.sh` writes a small wrapper for each compiler in `$STACK/bin` into
`$WORK/wrappers/bin`, and `lib/build_common.sh` puts that directory **ahead of
`$STACK/bin`** on `PATH` for every source build. Each wrapper appends
`-march=$ISA_BASELINE` to the command line and execs the real compiler.

## Why appending, and why last

`-march` is last-wins on a gcc command line. Every way we have of *setting* a
flag — `CFLAGS`, conda's `activate.d`, a `configure` argument — injects it
first. So a build system that appends its own `-march` beats us every time, and
several do: Kokkos autodetects the host architecture and arrives with Trilinos,
and each of PETSc's `--download-` TPLs brings its own build system.

Appending after the caller is the only position that wins, and it wins by the
same rule that was defeating us.

**This is a cap, not a floor.** `-mavx2 -march=x86-64-v2` produces no AVX2,
because `-march=` resets the whole feature set and ours is last. That is the
intent: the baseline declares what the artifact may contain. Raising it is a
decision about the artifact, so it belongs in `ISA_BASELINE`, not in a package
recipe.

## What is wrapped

The compilers, under both conda's triplet names and bare `cc` / `gcc` / `c++` /
`g++` / `gfortran`.

The bare aliases are not a convenience. The builder image has its own system
gcc, so a build system falling back to plain `cc` would otherwise compile
against the **host** toolchain — host libstdc++, host glibc headers, no
baseline. It would link, and it would run on the build machine. Our `cc` being
first on `PATH` means that fallback lands on the conda compiler instead.

**`mpicc` and friends are deliberately not wrapped.** `mpicc` invokes the
triplet-named compiler, which is already wrapped; wrapping both would inject
twice. `env.sh` sets `MPICH_CC`/`OMPI_CC` and friends as a second route, because
whether `mpicc` resolves its compiler through `PATH` or by absolute path is
mpich's choice, not ours. `cpp` is not wrapped — a preprocessor emits no
instructions.

## `-march=native`

Refused, with an explanation. The baseline appended afterwards would neutralise
it anyway, so this is about visibility rather than correctness: a build reaching
for `native` is doing host detection, and that is rarely confined to one flag.
`WRAPPER_ON_NATIVE=warn` — a make knob, and also readable at run time — downgrades
it to a warning.

## The self-test

`selftest.sh` runs as part of `make wrappers`, so it cannot be forgotten, and
`make wrappers-check` runs it on demand.

Every assertion is made against **object files**, via `relocate/isa-scan.py`.
Checking the command line would only prove we appended a flag; the flag is not
the claim, the emitted instructions are.

The negative control is the load-bearing part. "No above-baseline instructions"
is also what a broken test prints — a source that does not vectorise, a regex
that never matches, a compiler that ignored the flag. So each case is compiled
twice from the same source with the same permissive `-march`: once through the
real compiler, which **must** produce above-baseline code, and once through the
wrapper, which must not. If the control does not trip, the self-test fails
rather than passing vacuously.

Measured on `linux-aarch64`: the control emits SVE and dot-product instructions
in all three languages at `-march=armv8.2-a+sve+dotprod`; the same command line
through the wrappers emits none.
