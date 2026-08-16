#!/usr/bin/env bash
# Source acquisition for the Gust Dynamics demo packages.
#
# The framework already does most of this.  lib/build_common.sh provides
# fetch_src, which dispatches on PKG_SOURCE to download_src (tarball) or
# fetch_git (a cached bare mirror, detached checkout, submodules), and
# mk/pkg.mk passes PKG_SOURCE / PKG_GIT_URL / PKG_GIT_REF into every recipe.
# A customer switching a package from a release tarball to a git tag needs
# nothing from this file:
#
#     PKG_SOURCE  := git
#     PKG_GIT_URL := https://git.example.invalid/gust/gust-core.git
#     PKG_GIT_REF := v0.3.0
#
# What this file adds is the ONE mode the framework does not have: 'local',
# meaning "the code is vendored in the recipe directory, in src/".
#
# That mode earns its place because it is where nearly every customer package
# starts.  Before there is a release tarball or a tag to point at, there is a
# directory of source files sitting next to the recipe -- and the alternative
# the tree offers today is examples/site-package/build.sh, which emits its
# sources from heredocs inside the build script.  That works, but it is not
# where a customer's code actually lives, and it cannot be compiled, linted or
# diffed on its own.
#
# So: real files under src/, and one function that makes 'local' behave like
# the other two modes -- same destination, same contract -- so the rest of a
# recipe never branches on where the code came from.
#
# shellcheck shell=bash

# The single source location, identical to fetch_src's, in all three modes.
_gust_srcdir () { printf '%s/%s-%s' "${BUILD_TMP}" "${PKG_NAME}" "${PKG_VERSION}"; }

# gust_fetch_src -- fetch_src, plus PKG_SOURCE=local.
#
# Deliberately thin, and deliberately delegating: everything except 'local'
# goes straight to the framework, so there is exactly one implementation of
# tarball and git fetching in this tree and one place for a bug in them to be
# fixed.  This branch rides on top of main; a shim that reimplemented
# fetch_git would quietly rot the first time main improved it.
gust_fetch_src () {
  local mode="${PKG_SOURCE:-local}" dest vendored
  dest="$(_gust_srcdir)"

  if [ "${mode}" != local ]; then
    log "source mode: ${mode} (framework fetch_src)"
    fetch_src
    [ -d "${dest}" ] || {
      echo "${PKG_NAME}: ${mode} fetch left no ${dest}" >&2
      echo "  ${BUILD_TMP} contains: $(ls -1 "${BUILD_TMP}" 2>/dev/null | tr '\n' ' ')" >&2
      echo "  a tarball must unpack to a single ${PKG_NAME}-${PKG_VERSION}/ root" >&2
      exit 1
    }
    return 0
  fi

  # PKG_DIR arrives relative to TOPDIR with a trailing slash.  Recipes resolve
  # it to PKG_DIR_ABS before cd'ing anywhere; require that here rather than
  # guessing, so a recipe that forgot gets a clear message instead of copying
  # from a path that happens not to exist.
  : "${PKG_DIR_ABS:?gust_fetch_src: PKG_DIR_ABS must be set by the recipe}"
  vendored="${PKG_DIR_ABS}/src"
  [ -d "${vendored}" ] || {
    echo "${PKG_NAME}: PKG_SOURCE=local but no vendored sources at ${vendored}" >&2
    exit 1
  }

  log "source mode: local (${vendored#"${TOPDIR}"/})"
  mkdir -p "${dest}"
  # '/.' so the CONTENTS land in dest, rather than the directory being nested
  # one level deeper inside it.
  cp -R "${vendored}/." "${dest}/"
}
