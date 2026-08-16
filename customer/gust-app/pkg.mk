# Package B of the customer demo: depends on the customer's OWN package A,
# not on the base stack.
#
#     base stack (petsc -> libmesh)  ->  gust-core  ->  gust-app
#                                                       ^^^^^^^^
#
# PKG_DEPS names gust-core and nothing else.  Not libmesh, not petsc -- B does
# not include them, does not link them, and so must not claim them.  Declaring
# what you actually use is the difference between a dependency graph and a
# wish: if A ever changes what it is built on, nothing here has to change.
#
# The stamp prerequisite this creates is what makes 'make -jN' correct.  B's
# build.sh cannot start until A's has finished installing its header, its
# library and its .pc file -- which B reads at configure time, so an
# unsynchronised build would not merely be wrong, it would fail outright.

GUST_APP_VERSION := 0.2.1

PKG_NAME    := gust-app
PKG_VERSION := $(GUST_APP_VERSION)

# The same three source modes as package A, sharing the GUST_SOURCE default.
# The versions differ on purpose: the two packages release independently, which
# is the normal case and the reason each carries its own set of knobs.
GUST_SOURCE      ?= local
GUST_APP_SOURCE  ?= $(GUST_SOURCE)
GUST_APP_URL     ?= https://downloads.example.invalid/gust/gust-app-$(GUST_APP_VERSION).tar.gz
GUST_APP_GIT_URL ?= https://git.example.invalid/gust/gust-app.git
GUST_APP_GIT_REF ?= v$(GUST_APP_VERSION)

PKG_SOURCE  := $(GUST_APP_SOURCE)
PKG_URL     := $(GUST_APP_URL)
PKG_GIT_URL := $(GUST_APP_GIT_URL)
PKG_GIT_REF := $(GUST_APP_GIT_REF)

PKG_DEPS    := gust-core
PKG_STAGE   := build

$(eval $(call declare_pkg))
