FROM node:24.16.0-bookworm
USER root

# Instalar dependências
RUN apt-get update && apt-get install -y \
    sudo \
    python3 \
    python3-pip \
    git \
    curl \
    wget \
    git \
    unzip \
    nano \
    socat \
    iptables \
    ipset \
    iproute2 \
    dnsutils \
    build-essential \
    chromium \
    ca-certificates \
    nano \
    fonts-powerline \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# ── Pacotes globais do npm ──────────────────────────────────────────────────
RUN npm install -g npm@12.0.1 \
    && npm install -g @angular/cli

# ── eza (ls moderno) ────────────────────────────────────────────────────────
ARG EZA_VERSION=0.23.4

RUN curl -fsSL \
        "https://github.com/eza-community/eza/releases/download/v${EZA_VERSION}/eza_x86_64-unknown-linux-musl.tar.gz" \
        | tar -xzf - -C /usr/local/bin \
    && chmod +x /usr/local/bin/eza

# ── Owner dos diretórios globais do npm (antes de instalar pacotes globais) ─
RUN mkdir -p /usr/local/lib/node_modules \
    && chown -R node:node \
        /usr/local/lib/node_modules \
        /usr/local/bin \
        /usr/local/share
# Cache de npm (Melhorar desempenho )
RUN mkdir -p /home/node/.npm-cache && chown -R node:node /home/node/.npm-cache
ENV npm_config_cache=/home/node/.npm-cache

# Permissões sudo para o usuário node (desabilitado)
RUN echo "node ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# ── Bash personalizado (global, para qualquer usuário) ──────────────────────
RUN cat >> /etc/.bashrc <<'EOF'

alias cls='clear'
alias ll='eza -l -h --group --icons'
alias la='eza -la -hs --group'
alias lt='eza --tree --level=2 --group'

function ls() {
    command eza -la --group --group-directories-first "$@"
}

# =========================
# Colorized Path with Branch
# =========================

function parse_git_branch() {
    local branch
    branch=$(git branch --show-current 2>/dev/null)
    [ -n "$branch" ] && echo " ($branch)"
}

PS1='\[\e[0;32m\][\[\e[1;34m\]\u\[\e[0m\]:\[\e[1;36m\]\w\[\e[0m\]\[\e[1;33m\]$(parse_git_branch)\[\e[0m\]\[\e[0;32m\]]\[\e[0m\]\$'
EOF

# ── Firewall ────────────────────────────────────────────────────────────────
COPY init-firewall.sh /usr/local/bin/init-firewall.sh
RUN chmod +x /usr/local/bin/init-firewall.sh

# ── Entrypoint ─────────────────────────────────────────────────────────────
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod 775 /usr/local/bin/docker-entrypoint.sh
# ── Sudoers (regra única para ambos via entrypoint) ────────────────────────
RUN echo "node ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh /usr/local/bin/docker-entrypoint.sh" \
    > /etc/sudoers.d/node-dev \
 && chmod 0440 /etc/sudoers.d/node-dev

# bash profile (opcional)
RUN cp /etc/.bashrc home/node/.bashrc
RUN cp /etc/.bashrc home/node/.bash_profile

USER node
WORKDIR /workspaces
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
