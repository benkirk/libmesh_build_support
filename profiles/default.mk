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
# chosen.  Building 1.7.6 would mean an unbootstrapped tag archive plus
# autoconf/automake/libtool in the env, which is a bigger change, not a smaller
# one.
LIBMESH_VERSION  ?= 1.7.9
TRILINOS_VERSION ?= 14-4-0
