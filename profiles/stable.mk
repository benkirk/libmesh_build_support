# profiles/stable.mk -- conservative versions, the fallback when default breaks.
# See profiles/README.md for the v0 compatibility notes behind these choices.
PETSC_VERSION    ?= 3.19.6
LIBMESH_VERSION  ?= 1.7.1
TRILINOS_VERSION ?= 13-4-1

# As 'default': v0's answer, unchanged.  See mk/common.mk.
TRILINOS_KOKKOS  ?= off

# As 'default'.  See mk/common.mk.
TRILINOS_OPENMP  ?= off
