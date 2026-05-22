# LLDPq-IB - Network Monitoring for NVIDIA InfiniBand Switches (MLNX-OS)
# Single container: nginx + fcgiwrap + python3 + ssh + cron + InfiniBand diagnostic tools
FROM ubuntu:22.04

LABEL maintainer="ali@lldpq.dev"
LABEL description="LLDPq InfiniBand Edition - Network Monitoring for MLNX-OS Switches"
LABEL version="0.1.0"

# Prevent interactive prompts
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

# Install all dependencies in one layer
# bsdmainutils + bsdextrautils: 'column' command (moved in Ubuntu 22.04)
# openssh-client + sshpass: SSH to switches
# python3-yaml: devices.yaml parsing
# ruamel.yaml via pip: comment-preserving YAML editing
# infiniband-diags, ibverbs-utils: ibnetdiscover, iblinkinfo, sminfo, perfquery, ibtracert, saquery
RUN apt-get update && apt-get install -y --no-install-recommends \
    nginx fcgiwrap \
    python3 python3-yaml python3-pip python3-netaddr \
    openssh-client sshpass \
    sudo cron \
    iproute2 iputils-ping dnsutils tcpdump \
    curl jq git bsdmainutils bsdextrautils \
    dos2unix bash-completion colordiff net-tools bzip2 nano vim \
    tmux openssh-server \
    isc-dhcp-server \
    infiniband-diags ibverbs-utils \
    && pip3 install --no-cache-dir ruamel.yaml requests \
    && rm -rf /var/lib/apt/lists/*

# Shell usability tools (eza as exa, syntax-highlighted nano, custom bashrc)
ARG TARGETARCH
COPY docker/dotf/exa-${TARGETARCH} /usr/bin/exa
COPY docker/dotf/nanorc /etc/nanorc
COPY docker/dotf/bashrc /etc/bash.bashrc
COPY docker/dotf/UTC /etc/localtime
COPY etc/tmux.conf /etc/tmux.conf
RUN chmod 755 /usr/bin/exa && chmod 644 /etc/nanorc /etc/bash.bashrc /etc/tmux.conf && echo "UTC" > /etc/timezone

# SSH server (port 2033 for container access)
RUN mkdir -p /run/sshd && \
    sed -i 's/^#Port 22/Port 2033/' /etc/ssh/sshd_config && \
    sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config && \
    sed -i 's/^#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config

# Create lldpq user (no Ansible -- LLDPq-IB is monitoring-only)
RUN useradd -m -s /bin/bash -G www-data lldpq \
    && echo "lldpq ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/lldpq \
    && rm -f /home/lldpq/.bashrc /home/lldpq/.profile /home/lldpq/.bash_logout \
    && rm -f /root/.bashrc /root/.profile /root/.bash_logout

# Allow www-data to run only the commands needed by CGI workflows.
RUN echo "www-data ALL=(lldpq) NOPASSWD: /usr/bin/timeout, /usr/bin/ssh, /usr/bin/scp, /usr/bin/mkdir, /usr/bin/rm, /usr/bin/tee, /usr/bin/cat, /usr/bin/ssh-keygen" > /etc/sudoers.d/www-data-lldpq \
    && echo "www-data ALL=(root) NOPASSWD: /usr/bin/systemctl start isc-dhcp-server, /usr/bin/systemctl stop isc-dhcp-server, /usr/bin/systemctl restart isc-dhcp-server, /usr/bin/systemctl disable isc-dhcp-server, /usr/bin/systemctl enable isc-dhcp-server, /usr/bin/tee /etc/dhcp/dhcpd.conf, /usr/bin/tee /etc/dhcp/dhcpd.hosts, /usr/bin/tee /etc/default/isc-dhcp-server, /usr/bin/tee /etc/lldpq.conf, /usr/bin/cp, /usr/bin/mkdir, /usr/bin/rm, /usr/bin/pkill -x dhcpd, /usr/sbin/dhcpd, /usr/bin/cat /etc/dhcp/dhcpd.conf, /usr/bin/chmod, /usr/bin/chown" > /etc/sudoers.d/www-data-provision \
    && chmod 440 /etc/sudoers.d/www-data-lldpq /etc/sudoers.d/www-data-provision

# Create directory structure (no ansible dir, monitoring-only)
RUN mkdir -p /home/lldpq/lldpq/monitor-results/fabric-tables \
    && mkdir -p /var/www/html/hstr \
    && mkdir -p /var/www/html/configs \
    && mkdir -p /var/www/html/monitor-results \
    && mkdir -p /var/www/html/topology \
    && mkdir -p /var/www/html/generated_config_folder \
    && mkdir -p /home/lldpq/.ssh \
    && chmod 700 /home/lldpq/.ssh

# Copy web content
COPY html/ /var/www/html/
COPY VERSION /var/www/html/

# Download Monaco Editor + js-yaml (not in repo, installed at runtime on native)
RUN MONACO_VERSION="0.45.0" && TMP_DIR=$(mktemp -d) && \
    curl -sL "https://registry.npmjs.org/monaco-editor/-/monaco-editor-${MONACO_VERSION}.tgz" -o "$TMP_DIR/monaco.tgz" && \
    mkdir -p "$TMP_DIR/monaco" && \
    tar -xzf "$TMP_DIR/monaco.tgz" -C "$TMP_DIR/monaco" --strip-components=1 && \
    mkdir -p /var/www/html/monaco && \
    cp -r "$TMP_DIR/monaco/min/vs" /var/www/html/monaco/ && \
    rm -rf "$TMP_DIR" && \
    curl -sL "https://cdn.jsdelivr.net/npm/js-yaml@4.1.0/dist/js-yaml.min.js" \
        -o /var/www/html/css/js-yaml.min.js

# Copy lldpq scripts
COPY lldpq/ /home/lldpq/lldpq/
COPY bin/ /usr/local/bin/
# Test fixtures + demo-data generator (LLDPQ_IB_MOCK=1 offline tests
# AND LLDPQ_DEMO=true pre-populated showcase fabric).
COPY tests/ /home/lldpq/tests/

# Pre-populate /var/www/html/monitor-results + assets.ini + topology.dot
# + topology/topology.js with the demo fabric (4 spine + 8 leaf + 16 HCA).
# The entrypoint copies this baseline into the runtime volume only when
# LLDPQ_DEMO=true. We also pre-bake topology.js so the cytoscape view is
# populated on first page load (without waiting for any cron pass).
RUN mkdir -p /opt/lldpq-demo \
    && python3 /home/lldpq/tests/generate_demo_data.py \
        --target /opt/lldpq-demo/monitor-results \
        --web-root /opt/lldpq-demo \
    && cp /home/lldpq/tests/fixtures/demo-devices.yaml /opt/lldpq-demo/devices.yaml \
    && python3 /home/lldpq/lldpq/generate_ib_topology.py \
        --lldpq-dir /opt/lldpq-demo \
        --web-root  /opt/lldpq-demo \
    && chown -R lldpq:www-data /opt/lldpq-demo \
    && find /opt/lldpq-demo -type d -exec chmod 775 {} \; \
    && find /opt/lldpq-demo -type f -exec chmod 664 {} \;

# Copy nginx config
COPY etc/nginx/sites-available/lldpq /etc/nginx/sites-available/lldpq
RUN rm -f /etc/nginx/sites-enabled/default \
    && ln -sf /etc/nginx/sites-available/lldpq /etc/nginx/sites-enabled/lldpq

# Set ALL permissions explicitly (never rely on host umask or chmod +x)
# /var/www/html: lldpq:www-data, dirs=775, files=664, scripts=775
RUN chown -R lldpq:www-data /var/www/html/ \
    && find /var/www/html -type d -exec chmod 775 {} \; \
    && find /var/www/html -type f -exec chmod 664 {} \; \
    && find /var/www/html -name '*.sh' -exec chmod 775 {} \;
# /usr/local/bin: root-owned, readable+executable by ALL users (755)
RUN chmod 755 /usr/local/bin/*
# /home/lldpq: lldpq-owned, scripts=755
RUN chown -R lldpq:lldpq /home/lldpq/ \
    && find /home/lldpq/lldpq -name '*.sh' -exec chmod 755 {} \; \
    && find /home/lldpq/lldpq -name '*.py' -exec chmod 755 {} \;

# Setup topology files: real files in web root, symlinks in lldpq dir
# Same pattern as native install - web UI edits files in /var/www/html/
# Scripts access them via symlink in /home/lldpq/lldpq/
RUN mv /home/lldpq/lldpq/topology.dot /var/www/html/topology.dot \
    && mv /home/lldpq/lldpq/topology_config.yaml /var/www/html/topology_config.yaml \
    && ln -sf /var/www/html/topology.dot /home/lldpq/lldpq/topology.dot \
    && ln -sf /var/www/html/topology_config.yaml /home/lldpq/lldpq/topology_config.yaml \
    && chown lldpq:www-data /var/www/html/topology.dot /var/www/html/topology_config.yaml \
    && chmod 664 /var/www/html/topology.dot /var/www/html/topology_config.yaml \
    && chown lldpq:www-data /home/lldpq/lldpq/devices.yaml \
    && chmod 664 /home/lldpq/lldpq/devices.yaml

# Prepare DHCP server directories and config
RUN mkdir -p /etc/dhcp /var/lib/dhcp /var/run \
    && touch /var/lib/dhcp/dhcpd.leases \
    && touch /etc/dhcp/dhcpd.hosts \
    && chown lldpq:www-data /etc/dhcp/dhcpd.hosts \
    && chmod 664 /etc/dhcp/dhcpd.hosts

# Create lldpq-ib config (no Ansible, IB-specific defaults)
RUN printf '%s\n' \
    '# LLDPq-IB Configuration (Docker)' \
    'LLDPQ_DIR=/home/lldpq/lldpq' \
    'LLDPQ_USER=lldpq' \
    'WEB_ROOT=/var/www/html' \
    'DHCP_HOSTS_FILE=/etc/dhcp/dhcpd.hosts' \
    'DHCP_CONF_FILE=/etc/dhcp/dhcpd.conf' \
    'DHCP_LEASES_FILE=/var/lib/dhcp/dhcpd.leases' \
    'ZTP_SCRIPT_FILE=/var/www/html/mlnxos-ztp.sh' \
    'EDITOR_ROOT=/home/lldpq' \
    'MONITOR_MAX_PARALLEL=100' \
    'IB_DISCOVERY_MAX_PARALLEL=100' \
    'ASSETS_MAX_PARALLEL=50' \
    'GET_CONFIGS_MAX_PARALLEL=50' \
    'SEND_CMD_MAX_PARALLEL=25' \
    'TELEMETRY_MAX_PARALLEL=25' \
    'TRANSCEIVER_FW_MAX_PARALLEL=10' \
    'TRANSCEIVER_FW_MIN_INTERVAL=1800' \
    'TRANSCEIVER_FW_SSH_TIMEOUT=300' \
    'TRANSCEIVER_FW_UNKNOWN_MODEL_POLICY=skip' \
    'UFM_URL=' \
    'UFM_TOKEN=' \
    'UFM_VERIFY_TLS=false' \
    > /etc/lldpq.conf

# Create auth users file + sessions directory
# Entrypoint also recreates these if missing (self-healing)
RUN ADMIN_HASH=$(echo -n "admin" | openssl dgst -sha256 | awk '{print $2}') \
    && OPERATOR_HASH=$(echo -n "operator" | openssl dgst -sha256 | awk '{print $2}') \
    && echo "admin:$ADMIN_HASH:admin" > /etc/lldpq-users.conf \
    && echo "operator:$OPERATOR_HASH:operator" >> /etc/lldpq-users.conf \
    && chmod 600 /etc/lldpq-users.conf \
    && chown www-data:www-data /etc/lldpq-users.conf \
    && mkdir -p /var/lib/lldpq/sessions /var/lib/lldpq/upgrade-jobs \
    && chown -R www-data:www-data /var/lib/lldpq \
    && chown lldpq:www-data /var/lib/lldpq/upgrade-jobs \
    && chmod 700 /var/lib/lldpq/sessions \
    && chmod 775 /var/lib/lldpq/upgrade-jobs

# Create cache files with correct permissions (assets, provision, AI need these)
RUN for f in device-cache.json discovery-cache.json inventory.json ai-analysis.json; do \
        echo '{}' > /var/www/html/$f; \
    done \
    && chown lldpq:www-data /var/www/html/device-cache.json \
       /var/www/html/discovery-cache.json /var/www/html/inventory.json /var/www/html/ai-analysis.json \
    && chmod 664 /var/www/html/device-cache.json \
       /var/www/html/discovery-cache.json /var/www/html/inventory.json /var/www/html/ai-analysis.json

# Copy entrypoint
COPY docker/docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

EXPOSE 80 2033

ENTRYPOINT ["/docker-entrypoint.sh"]
