PKG_NAME    := petsc
PKG_VERSION := $(PETSC_VERSION)
# v0 fetched from ftp.mcs.anl.gov, which ANL has since retired -- it 404s for
# every version now.  web.cels.anl.gov is where the release snapshots moved.
PKG_URL     := https://web.cels.anl.gov/projects/petsc/download/release-snapshots/petsc-$(PETSC_VERSION).tar.gz

# Nothing.  MPI and BLAS come from conda, which is an implicit dependency of
# every package.  In the v0 static stack PETSc was also Trilinos' dependency,
# but only so Trilinos could scavenge PETSc's from-source libfblas.a -- with
# BLAS from conda that reason is gone and the two build concurrently.
PKG_DEPS    :=
PKG_STAGE   := build

$(eval $(call declare_pkg))
