PKG_NAME    := libmesh
PKG_VERSION := $(LIBMESH_VERSION)
PKG_URL     := https://github.com/libMesh/libmesh/releases/download/v$(LIBMESH_VERSION)/libmesh-$(LIBMESH_VERSION).tar.gz

# Tarball by default -- it is what this stack has always built and what the
# version pins in profiles/ are chosen for.  'make LIBMESH_SOURCE=git build'
# clones instead, initialises the contrib submodules and runs ./bootstrap, which
# is how you reach a tag that publishes no release asset (1.7.6, say).  The
# default ref builds the SAME version as the tarball, so the two modes are a
# cross-check on each other rather than two different libMeshes.
LIBMESH_SOURCE  ?= tarball
LIBMESH_GIT_URL ?= https://github.com/libMesh/libmesh.git
LIBMESH_GIT_REF ?= v$(LIBMESH_VERSION)

# ':=' and not '?=': declare_pkg clears these to defined-but-empty after each
# package, so a '?=' here would silently do nothing.  See mk/common.mk.
PKG_SOURCE  := $(LIBMESH_SOURCE)
PKG_GIT_URL := $(LIBMESH_GIT_URL)
PKG_GIT_REF := $(LIBMESH_GIT_REF)

# PETSc only.  Note what is NOT here: v0's libMesh did not depend on Trilinos
# and did not configure against it -- Trilinos was built as a sibling for
# downstream consumers, not as a libMesh backend.  Adding --enable-trilinos
# would be a change in what this stack provides, not a port of it.
PKG_DEPS    := petsc
PKG_STAGE   := build

$(eval $(call declare_pkg))
