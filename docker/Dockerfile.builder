# The builder image.
#
# This file is the executable statement of the project's minimal-host claim:
# it installs ONLY what a bare host genuinely needs, because conda supplies the
# compilers, cmake and patchelf.  If this ever needs a dev package added, that
# is a regression in the premise -- not a fix to the image.
#
# The line between the two sides is FETCHING versus BUILDING.  Getting the
# sources onto the disk is the host's job -- curl, git, and the decompressors
# tar execs.  Anything that then compiles or generates is the conda env's --
# make, cmake, m4, the autotools.  git sits here rather than in the env for the
# same reason curl does: it is a transport, it is not version-sensitive to the
# sources it fetches, and keeping it out of the env keeps it out of the
# artifact-prune story entirely.  conda/bootstrap.sh states the other half.
#
# The per-manager package names below are not cosmetic.  'git' on the RHEL
# family is a metapackage that drags in perl and openssh-clients -- 76 packages,
# measured on almalinux:9 -- where 'git-core' is the porcelain alone at 6.4 MB
# and handles everything this project asks of it: a bare mirror, a detached
# checkout, and recursive submodules (measured, not assumed).  Debian has no
# meaningful git-core, so there it is 'git'.
#
# It installs only what is genuinely MISSING, rather than naming a fixed
# package list.  Asking for a package the base image already satisfies is how
# you end up fighting it: almalinux:9 ships curl-minimal, and a bare
# 'dnf install curl' fails outright with a package conflict rather than being
# a no-op.  Probing for the command keeps this file an honest statement of the
# claim -- and the build log then prints exactly what each base image lacked,
# which is the number we actually care about.
ARG BASE_IMAGE=almalinux:9
FROM ${BASE_IMAGE}

SHELL ["/bin/bash", "-c"]

RUN set -eo pipefail; \
    if   command -v dnf     >/dev/null 2>&1; then PM=dnf;    PS=procps-ng; XZ=xz;       GIT=git-core; \
    elif command -v zypper  >/dev/null 2>&1; then PM=zypper; PS=procps;    XZ=xz;       GIT=git-core; \
    elif command -v apt-get >/dev/null 2>&1; then PM=apt;    PS=procps;    XZ=xz-utils; GIT=git; \
    else echo "unsupported base image" >&2; exit 1; fi; \
    have () { command -v "$1" >/dev/null 2>&1; }; \
    need=(); \
    have curl  || need+=(curl);        `# fetch miniforge and source tarballs` \
    have git   || need+=("$GIT");      `# fetch source REPOS: PKG_SOURCE=git, and PETSc's --download-*` \
    have tar   || need+=(tar);         `# unpack both` \
    have gzip  || need+=(gzip);        `# tar execs it: every source tarball is .tar.gz, and so is ours` \
    have bzip2 || need+=(bzip2);       `# the miniforge installer needs it` \
    have xz    || need+=("$XZ");       `# tar execs it for .tar.xz; xz-utils on apt, xz elsewhere` \
    have make  || need+=(make);        `# drive the build` \
    have find  || need+=(findutils);   `# shell plumbing` \
    have which || need+=(which); \
    have ps    || need+=("$PS"); \
    { [ -e /etc/pki/tls/certs/ca-bundle.crt ] || \
      [ -e /etc/ssl/certs/ca-certificates.crt ]; } || need+=(ca-certificates); \
    echo "==> base image lacks: ${need[*]:-nothing}"; \
    if [ ${#need[@]} -gt 0 ]; then \
      case "$PM" in \
        dnf)    dnf -y install "${need[@]}" && dnf clean all ;; \
        zypper) zypper --non-interactive install "${need[@]}" && zypper clean -a ;; \
        apt)    apt-get update && apt-get install -y --no-install-recommends "${need[@]}" \
                  && rm -rf /var/lib/apt/lists/* ;; \
      esac; \
    fi

WORKDIR /src
CMD ["make", "help"]
