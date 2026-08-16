# Package A of the customer demo: the layer that sits directly on the stack.
#
#     base stack (petsc -> libmesh)  ->  gust-core  ->  gust-app
#                                        ^^^^^^^^^      package B
#
# PKG_DEPS is the entire dependency declaration.  It becomes a stamp
# prerequisite in mk/pkg.mk, so gust-core cannot start before libmesh's stamp
# exists, and gust-app cannot start before gust-core's -- correct under
# 'make -jN' without any of the three packages knowing about the others.

# Kept in its own name because declare_pkg CLEARS every PKG_* variable at the
# end of this file, and the URLs below are recursively expanded: a $(PKG_VERSION)
# inside them would expand to nothing by the time it was used.
GUST_CORE_VERSION := 0.3.0

PKG_NAME    := gust-core
PKG_VERSION := $(GUST_CORE_VERSION)

#-------------------------------------------------------------------------------
# Where the sources come from.  Three modes; see customer/README.md.
#
#   local     (default) the src/ directory beside this file
#   tarball   PKG_URL, via the framework's download_src
#   git       PKG_GIT_URL @ PKG_GIT_REF, via the framework's fetch_git
#
# tarball and git are the framework's own PKG_SOURCE mechanism, untouched --
# mk/common.mk snapshots these three names and mk/pkg.mk passes them to
# build.sh.  Only 'local' is ours; customer/common/gust_source.sh adds it.
#
#     make SITE_DIRS=customer build
#     make SITE_DIRS=customer GUST_SOURCE=git build
#     make SITE_DIRS=customer GUST_CORE_SOURCE=tarball \
#          GUST_CORE_URL=https://internal.example/gust-core-0.3.0.tar.gz build
#
# GUST_SOURCE sets both demo packages at once; the per-package name overrides it
# for one of them.  '?=' is safe on these because they are OUR names -- unlike
# the PKG_* names, which declare_pkg leaves defined-but-empty and which
# therefore have to be assigned with ':='.  (See the note above declare_pkg in
# mk/common.mk; a '?=' on a PKG_* name in a second pkg.mk silently does nothing.)
GUST_SOURCE       ?= local
GUST_CORE_SOURCE  ?= $(GUST_SOURCE)
GUST_CORE_URL     ?= https://downloads.example.invalid/gust/gust-core-$(GUST_CORE_VERSION).tar.gz
GUST_CORE_GIT_URL ?= https://git.example.invalid/gust/gust-core.git
GUST_CORE_GIT_REF ?= v$(GUST_CORE_VERSION)

PKG_SOURCE  := $(GUST_CORE_SOURCE)
PKG_URL     := $(GUST_CORE_URL)
PKG_GIT_URL := $(GUST_CORE_GIT_URL)
PKG_GIT_REF := $(GUST_CORE_GIT_REF)

# libmesh, and only libmesh.  petsc arrives transitively -- libmesh's own
# pkg.mk depends on it -- and MPI, BLAS and HDF5 need no entry at all: the
# conda env is an implicit dependency of every package.
PKG_DEPS    := libmesh
PKG_STAGE   := build

$(eval $(call declare_pkg))
