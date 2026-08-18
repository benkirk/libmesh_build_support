# profiles/default.mk -- the version set built by default.
# Successor to utils/versions/{default,devel}.sh from the v0 static stack.
#
# Only source-built packages are pinned here; conda-provided versions are
# pinned in conda/env/*.yml and locked in conda/lock/.
# See profiles/README.md for the v0 compatibility notes behind these choices.
PETSC_VERSION    ?= 3.20.5
# v0 pinned 1.7.6.  That tag exists, but libMesh publishes dist tarballs for
# only a subset of tags and 1.7.6 is not one of them -- in the whole 1.7 series
# only 1.7.8 and 1.7.9 have release assets, so the v0 download URL 404s.  1.7.9
# is the nearest obtainable release in the same series; staying inside 1.7.x is
# the smallest deviation available, and it is forced by availability rather than
# chosen.
#
# It is no longer a hard blocker on a version, though it is still the default.
# An unobtainable release asset is now reachable with
#
#     make LIBMESH_SOURCE=git LIBMESH_GIT_REF=v1.7.6 build
#
# which clones the tag, initialises the contrib submodules and bootstraps it.
# The autotools that needs live in the conda env and git lives in the builder
# image.  The pin stays at 1.7.9 because the tarball path is what the whole
# matrix exercises; the git path is opt-in and weekly.
LIBMESH_VERSION  ?= 1.7.9
TRILINOS_VERSION ?= 14-4-0

# Kokkos stays off here: it is what v0 shipped and what every artifact this
# stack has ever produced contains.  'bleeding' is where the other answer is
# measured.  See mk/common.mk.
TRILINOS_KOKKOS  ?= off
