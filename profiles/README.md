# Version profiles

`PROFILE=<name>` selects `profiles/<name>.mk`, which pins the versions of the
**source-built** packages. Versions of conda-provided packages (compilers, MPI,
BLAS, HDF5, zlib) are pinned in `conda/env/*.yml` and frozen in `conda/lock/`.

```sh
make PROFILE=stable all
```

| profile | PETSc / libMesh / Trilinos | intent |
|---|---|---|
| `default` | 3.20.5 / 1.7.9 / 14-4-0 | what we build and test by default |
| `stable` | 3.19.6 / 1.7.1 / 13-4-1 | conservative; the fallback when `default` breaks. Never built |
| `bleeding` | 3.23.7 / 1.8.4 / 16-1-0 | the newer pairing. Built by `ci.yml` on both platforms since #30 |

Each profile also sets `TRILINOS_KOKKOS` — `off` passes
`-DTrilinos_ENABLE_Kokkos=OFF`, `auto` passes nothing and lets Trilinos decide.
`bleeding` is the one on `auto`. It is assigned here rather than in
`mk/common.mk` because that file is included *before* this one, so a `?=` there
would win over these.

Each `.mk` uses `?=`, so anything set in `config.mk` or on the command line wins.

## Compatibility notes carried over from the v0 static stack

These were recorded in `utils/versions/*.sh` in the autotools generation
(tag `v0-static-stack`) and are preserved here because they are the only
empirical version-compatibility data the project has. **Read them as history,
not as current constraints** — most of the failures described are specific to
static linking, which is exactly the premise this generation abandoned.

- **GCC** — "checked versions 5.5.0 → 11.3.0. 11.3 requires newer linkers and
  can be a problem on CentOS." Moot now: the compiler comes from conda-forge
  with its own `binutils` and `sysroot`, so the host linker is not involved.
  `GCC_VERSION` is a `config.mk` knob, default 14.
- **PETSc** — "checked versions 3.7.7 → 3.16.6. (3.15+ fails to statically link
  on CentOS with old AR.)" The static-link failure cannot recur under
  `--with-shared-libraries=1`. Separately, `petsc/build.sh` had to set
  `--with-ml=0` for 3.17.x because *"ML does not honor shared libs in PETSc
  3.17"* — that workaround is expected to become unnecessary now that the whole
  stack is shared, but PETSc `--download-*` packages have a history of being
  shaky about shared builds, so per-version special-casing may well survive.
- **libMesh** — "checked versions 1.2.1, 1.4.2, 1.6.2."
- **OpenMPI** — "checked versions 1.10.4 → 4.1.4; versions 2.x & 3.x seem to
  require shared libs." Also moot, and inverted: shared is now what we want.
  OpenMPI was `disabled` in every v0 profile and never actually exercised.
- **Trilinos** — every v0 profile pinned `13-0-1` and built a deliberately
  minimal package set (Sacado + Pliris, `-DTrilinos_ENABLE_Kokkos=OFF`). Kokkos
  became a mandatory dependency of Sacado in later Trilinos, so that flag is not
  expected to survive a version bump.
  **Measured, and wrong** (2026-08-17): Trilinos 16-1-0 configures and builds
  with `-DTrilinos_ENABLE_Kokkos=OFF`, because Sacado's Kokkos dependence is
  *optional* — `Setting Sacado_ENABLE_Kokkos=OFF because Sacado has an optional
  library dependence on disabled package Kokkos` — and the enabled set comes out
  as the same four packages as 14-4-0: Teuchos, Sacado, Epetra, Pliris. The flag
  survived. It is now a per-profile choice (`TRILINOS_KOKKOS`) rather than a
  constraint, and `bleeding` takes the other branch on purpose.
