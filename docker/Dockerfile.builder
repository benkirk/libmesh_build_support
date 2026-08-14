# The builder image.
#
# This file is the executable statement of the project's minimal-host claim:
# it installs ONLY what a bare host genuinely needs, because conda supplies the
# compilers, cmake and patchelf.  If this ever needs a dev package added, that
# is a regression in the premise -- not a fix to the image.
ARG BASE_IMAGE=almalinux:9
FROM ${BASE_IMAGE}

SHELL ["/bin/bash", "-c"]

# curl + ca-certificates to fetch miniforge; tar/bzip2 to unpack it;
# make to drive the build; findutils/which for the shell plumbing.
RUN if   command -v dnf     >/dev/null 2>&1; then \
      dnf -y install curl ca-certificates tar bzip2 make findutils which procps-ng && dnf clean all; \
    elif command -v zypper  >/dev/null 2>&1; then \
      zypper --non-interactive install curl ca-certificates tar bzip2 make findutils which procps && zypper clean -a; \
    elif command -v apt-get >/dev/null 2>&1; then \
      apt-get update && apt-get install -y --no-install-recommends \
        curl ca-certificates tar bzip2 make findutils procps && rm -rf /var/lib/apt/lists/*; \
    else echo "unsupported base image" >&2; exit 1; fi

WORKDIR /src
CMD ["make", "help"]
