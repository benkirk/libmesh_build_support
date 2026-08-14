# profiles/default.mk -- the version set built by default.
# Successor to utils/versions/{default,devel}.sh from the v0 static stack.
#
# Only source-built packages are pinned here; conda-provided versions are
# pinned in conda/env/*.yml and locked in conda/lock/.
# See profiles/README.md for the v0 compatibility notes behind these choices.
PETSC_VERSION    ?= 3.20.5
LIBMESH_VERSION  ?= 1.7.6
TRILINOS_VERSION ?= 14-4-0
