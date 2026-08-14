# Archived: the all-static stack

Until 2026 this repo built an **all-static** stack — gcc, zlib, hdf5, mpich,
PETSc, libMesh and Trilinos, every one of them `--enable-static
--disable-shared` — so that a libMesh development environment could be stood up
on a very minimal host.

That generation is preserved at the tag **`v0-static-stack`**:

```sh
git checkout v0-static-stack
```

It is unmaintained. Bug reports against it will not be acted on.

## Why it was retired

Fully static builds of this stack stopped being practical:

- glibc's static NSS makes "statically linked" less absolute than it sounds;
- several PETSc `--download-*` packages no longer honour static requests — the
  `3.17*` special case in the old `petsc/build.sh`, which had to disable ML
  outright, was the visible symptom;
- upstreams increasingly do not test static configurations at all, so breakage
  arrives without warning and lands on us to diagnose.

The replacement ships **shared** libraries in a tree that is relocatable via
`$ORIGIN`-relative RPATHs, and validates that property end to end rather than
asserting it. See [`docs/RELOCATABLE-STACK-PLAN.md`](docs/RELOCATABLE-STACK-PLAN.md).
