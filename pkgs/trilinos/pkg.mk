PKG_NAME    := trilinos
PKG_VERSION := $(TRILINOS_VERSION)
PKG_URL     := https://github.com/trilinos/Trilinos/archive/refs/tags/trilinos-release-$(TRILINOS_VERSION).tar.gz

# Empty, and that is a change from v0, where Trilinos depended on PETSc.  That
# dependency was never about Trilinos needing PETSc: it existed so the Trilinos
# recipe could scavenge ${PETSC_DIR}/lib/libfblas.a, PETSc's from-source
# reference BLAS.  With BLAS coming from conda there is nothing to scavenge, so
# the two now build concurrently -- which is what the stamp-based dependency
# graph in mk/pkg.mk was built to allow.
PKG_DEPS    :=
PKG_STAGE   := build

$(eval $(call declare_pkg))
