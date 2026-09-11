# Development image for a Frappe bench.
#
# Carries the toolchain only. The bench itself lives on a bind mount, created by
# hand with `bench init`, so the developer works exactly as they would on WSL --
# same commands, same `bench start` -- only the interpreter and node live here.
#
# Base and package list follow press/docker/Dockerfile, which is what Frappe
# Cloud builds every production bench image from. Same Ubuntu, same deadsnakes
# PPA, same redis.io repo.
#
# Version floors come from Frappe itself:
#   apps/frappe/pyproject.toml   requires-python = ">=3.14,<3.15"   (v16)
#   apps/frappe/package.json     "engines": {"node": ">=24"}         (v16)
# The Python range is exact, so the interpreter comes from deadsnakes rather
# than whatever Ubuntu ships. Verified available on jammy: 3.14.6-1+jammy1.

FROM ubuntu:22.04

ARG PYTHON_VERSION=3.14
ARG NODE_VERSION=24.13.0
ARG NVM_VERSION=0.40.3
ARG BENCH_VERSION=5.31.0
# Match the host user so files written into the bind-mounted bench stay editable
# from the IDE.
ARG UID=1000
ARG GID=1000

ENV LANG=C.UTF-8
ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1

RUN apt-get update && apt-get install --yes --no-install-recommends \
    build-essential \
    git \
    pkg-config \
    software-properties-common \
    gnupg \
    curl \
    wget \
    ca-certificates \
    mariadb-client \
    libmariadb-dev \
    # weasyprint
    libpango-1.0-0 \
    libharfbuzz0b \
    libpangoft2-1.0-0 \
    libpangocairo-1.0-0 \
    # wkhtmltopdf
    fontconfig \
    libfreetype6 \
    libjpeg-turbo8 \
    libpng16-16 \
    libx11-6 \
    libxcb1 \
    libxext6 \
    libxrender1 \
    xfonts-75dpi \
    xfonts-base \
    # s3-attachment
    libmagic1 \
    # `bench init` writes a crontab for periodic backups and fails outright if
    # /usr/bin/crontab is missing. Press's image sidesteps this with
    # `bench init --no-backups`; here init is typed by hand, so cron is present.
    cron \
    # convenience for anyone exec-ing in
    less \
    nano \
    vim \
    htop \
    iputils-ping \
    procps \
    sudo \
  && rm -rf /var/lib/apt/lists/*

# Redis from the upstream repo, as Press does. `bench start` runs redis_cache
# and redis_queue from the Procfile, so it has to be in the image.
RUN curl -fsSL https://packages.redis.io/gpg | gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg \
  && echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb jammy main" > /etc/apt/sources.list.d/redis.list \
  && apt-get update \
  && apt-get install --yes --no-install-recommends redis-server \
  && rm -rf /var/lib/apt/lists/*

RUN add-apt-repository --yes ppa:deadsnakes/ppa \
  && apt-get update \
  && apt-get install --yes --no-install-recommends \
    python${PYTHON_VERSION} \
    python${PYTHON_VERSION}-dev \
    python${PYTHON_VERSION}-venv \
  && rm -rf /var/lib/apt/lists/*

# Architecture-aware: a hardcoded amd64 .deb fails at build on Apple Silicon
# with a dpkg architecture error, which is a miserable first experience for a
# new engineer. Name the machine instead.
RUN arch="$(dpkg --print-architecture)" \
  && case "$arch" in \
       amd64|arm64) : ;; \
       *) echo "wkhtmltopdf has no release build for $arch" >&2; exit 1 ;; \
     esac \
  && wget -q "https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-2/wkhtmltox_0.12.6.1-2.jammy_${arch}.deb" \
  && dpkg -i "wkhtmltox_0.12.6.1-2.jammy_${arch}.deb" \
  && rm "wkhtmltox_0.12.6.1-2.jammy_${arch}.deb"

RUN groupadd --gid ${GID} frappe 2>/dev/null || true \
  && useradd --uid ${UID} --gid ${GID} --create-home --shell /bin/bash frappe \
  && echo "frappe ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/frappe

USER frappe
WORKDIR /home/frappe

ENV NVM_DIR=/home/frappe/.nvm
RUN mkdir -p ${NVM_DIR} \
  && curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v${NVM_VERSION}/install.sh | bash \
  && . ${NVM_DIR}/nvm.sh \
  && nvm install ${NODE_VERSION} \
  && nvm alias default v${NODE_VERSION} \
  && npm install -g yarn \
  && nvm cache clear

ENV PATH=${NVM_DIR}/versions/node/v${NODE_VERSION}/bin:/home/frappe/.local/bin:${PATH}

# frappe-bench goes into the user site. `bench init` builds the bench's own venv
# later, inside the bind mount.
ENV PYTHON_BIN=/usr/bin/python${PYTHON_VERSION}
RUN ${PYTHON_BIN} -m ensurepip --upgrade \
  && ${PYTHON_BIN} -m pip install --user --no-warn-script-location --upgrade pip setuptools wheel \
  && ${PYTHON_BIN} -m pip install --user --no-warn-script-location frappe-bench==${BENCH_VERSION}

RUN git config --global advice.detachedHead false \
  && git config --global --add safe.directory '*'

# Never block on a credential prompt. Without this an expired or missing
# GITHUB_TOKEN turns bootstrap into a container sitting forever on "Username for
# 'https://github.com':" -- compose runs with tty: true, so it really does wait.
ENV GIT_TERMINAL_PROMPT=0
# Same reasoning for SSH-style URLs in apps.json: an unknown host key otherwise
# blocks forever on "Are you sure you want to continue connecting?" instead of
# failing. accept-new trusts on first contact but still catches a changed key.
ENV GIT_SSH_COMMAND="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new"

# `docker compose exec bench bash` should land inside the bench once it exists.
# Compose cannot express this: a working_dir pointing at a directory that is not
# there yet gets created by Docker as root, inside the bind mount, and then
# `bench init` refuses to write into it.
RUN echo '[ -d /home/frappe/frappe-bench ] && cd /home/frappe/frappe-bench' >> /home/frappe/.bashrc

# Named volumes mounted at a path the image does not already own are created
# root-owned, and pip/yarn then cannot write to them. Create them as frappe.
RUN mkdir -p /home/frappe/.cache/pip /home/frappe/.cache/yarn /home/frappe/frappe-bench

WORKDIR /home/frappe

COPY --chown=root:root entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --chown=root:root bootstrap.sh /usr/local/bin/bootstrap.sh

EXPOSE 8000 9000 6787

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
