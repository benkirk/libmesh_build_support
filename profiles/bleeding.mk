# profiles/bleeding.mk -- the newer pairing, and the first profile other than
# 'default' that CI actually builds.
#
# "Expect breakage, that is the point" was true while nothing built this; it is
# now a claim CI checks on both platforms.  The three versions were chosen as a
# PAIRING somebody runs rather than as the newest of everything -- PETSc is at
# 3.25.4 and Trilinos at 16-2-2 as this lands.
#
# Measured on linux-aarch64 before the bump (see
# docs/plans/OPTIONAL-PACKAGES-AND-SECOND-PROFILE.md):
#
#   PETSc 3.23.7    needed ONE addition to the recipe's v0 option set, and the
#                   first reading of this measurement was wrong: the run was
#                   reported green when only its wrapper had exited 0.  PETSc
#                   3.23 downloads a SuiteSparse whose CHOLMOD builds demo
#                   programs under BUILD_TESTING, and linking one of them fails
#                   for want of an -rpath-link.  pkgs/petsc/build.sh now passes
#                   --download-suitesparse-cmake-arguments=-DBUILD_TESTING=OFF,
#                   which is a no-op for the older SuiteSparse that 3.20.5
#                   downloads.  See that file for the error and the reasoning.
#   Trilinos 16-1-0 builds with the recipe unchanged, INCLUDING
#                   -DTrilinos_ENABLE_Kokkos=OFF.  profiles/README.md predicted
#                   that flag would not survive a version bump; it did.  Sacado's
#                   Kokkos dependence is optional ("Setting Sacado_ENABLE_Kokkos
#                   =OFF because Sacado has an optional library dependence on
#                   disabled package Kokkos"), and the final package set is the
#                   same four as 14-4-0: Teuchos, Sacado, Epetra, Pliris.
#   libMesh 1.8.4   publishes a .tar.gz release asset, which is what pkg.mk's
#                   URL wants.  It is also the first version this stack builds
#                   that HAS --with-xdr-include, so it exercises the other half
#                   of the XDR branch in pkgs/libmesh/build.sh.
PETSC_VERSION    ?= 3.23.7
LIBMESH_VERSION  ?= 1.8.4
TRILINOS_VERSION ?= 16-1-0

# Let Trilinos decide about Kokkos here rather than carrying v0's answer
# forward.  A customer building 16.1.0 today passes no Kokkos flag at all, so
# 'auto' is the configuration that matches what they have; 'default' keeps
# 'off', because 14-4-0's artifact must not move.  See mk/common.mk.
TRILINOS_KOKKOS  ?= auto

# OpenMP on, because measuring it found no cost: on linux-aarch64 at b6e8328,
# against a same-commit control differing only in this flag, it added no file to
# the artifact, no conda package, and -3,571 bytes net -- libkokkoscore and
# libepetra grow, libteuchosparameterlist and libteuchoscomm shrink by about as
# much.  validate stayed at 0 failures with all objects inside armv8.1-a.
#
# What it does change is the CONTRACT: KokkosConfig.cmake gains
# FIND_DEPENDENCY(OpenMP REQUIRED COMPONENTS CXX), so a consumer whose compiler
# has no OpenMP now fails at find_package(Kokkos).  That is the real cost, it is
# not measurable in bytes, and 'bleeding' is the profile that exists to carry
# it first.  See mk/common.mk for why this is not -DKokkos_ENABLE_OPENMP=ON.
TRILINOS_OPENMP  ?= on
