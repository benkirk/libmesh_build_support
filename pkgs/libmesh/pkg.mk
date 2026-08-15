PKG_NAME    := libmesh
PKG_VERSION := $(LIBMESH_VERSION)
PKG_URL     := https://github.com/libMesh/libmesh/releases/download/v$(LIBMESH_VERSION)/libmesh-$(LIBMESH_VERSION).tar.gz

# PETSc only.  Note what is NOT here: v0's libMesh did not depend on Trilinos
# and did not configure against it -- Trilinos was built as a sibling for
# downstream consumers, not as a libMesh backend.  Adding --enable-trilinos
# would be a change in what this stack provides, not a port of it.
PKG_DEPS    := petsc
PKG_STAGE   := build

$(eval $(call declare_pkg))
