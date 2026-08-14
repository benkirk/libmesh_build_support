# Version profiles

`PROFILE=<name>` selects `profiles/<name>.mk`, which pins the versions of the
**source-built** packages. Versions of conda-provided packages (compilers, MPI,
BLAS, HDF5, zlib) are pinned in `conda/env/*.yml` and frozen in `conda/lock/`.

```sh
make PROFILE=stable all
```

| profile | intent |
|---|---|
| `default` | what we build and test by default |
| `stable` | conservative; the fallback when `default` breaks |
| `bleeding` | newest; expect breakage, that is the point |

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
