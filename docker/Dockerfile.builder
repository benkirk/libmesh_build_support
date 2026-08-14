# The builder image.
#
# This file is the executable statement of the project's minimal-host claim:
# it installs ONLY what a bare host genuinely needs, because conda supplies the
# compilers, cmake and patchelf.  If this ever needs a dev package added, that
# is a regression in the premise -- not a fix to the image.
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
    if   command -v dnf     >/dev/null 2>&1; then PM=dnf;    PS=procps-ng; \
    elif command -v zypper  >/dev/null 2>&1; then PM=zypper; PS=procps; \
    elif command -v apt-get >/dev/null 2>&1; then PM=apt;    PS=procps; \
    else echo "unsupported base image" >&2; exit 1; fi; \
    have () { command -v "$1" >/dev/null 2>&1; }; \
    need=(); \
    have curl  || need+=(curl);        `# fetch miniforge and source tarballs` \
    have tar   || need+=(tar);         `# unpack both` \
    have bzip2 || need+=(bzip2);       `# the miniforge installer needs it` \
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
