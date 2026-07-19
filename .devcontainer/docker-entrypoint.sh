#!/bin/bash
set -e

readonly USER=node

# ── Realinhar UID/GID do node com o dono do /workspaces (bind mount do host) ─
# Assim não depende de saber o UID/GID do host antecipadamente nem de rebuild.
HOST_UID=$(stat -c '%u' /workspaces)
HOST_GID=$(stat -c '%g' /workspaces)
CURRENT_UID=$(id -u "$USER")
CURRENT_GID=$(id -g "$USER")

#echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor

sudo echo "[entrypoint] /workspaces pertence a UID:GID ${HOST_UID}:${HOST_GID}"
sudo echo "[entrypoint] usuário '$USER' atualmente é UID:GID ${CURRENT_UID}:${CURRENT_GID}"

# -o (non-unique) evita falha caso o UID/GID alvo já esteja em uso por outro
# usuário/grupo do sistema dentro da imagem (ex: colidir com root, UID 0).
if [ "$HOST_GID" != "$CURRENT_GID" ]; then
    sudo echo "[entrypoint] ajustando GID de '$USER' para $HOST_GID"
    sudo groupmod -o -g "$HOST_GID" "$USER"
fi

if [ "$HOST_UID" != "$CURRENT_UID" ]; then
    sudo echo "[entrypoint] ajustando UID de '$USER' para $HOST_UID"
    sudo usermod -o -u "$HOST_UID" "$USER"
fi

sudo mkdir -p \
    /home/$USER/.vscode-server/bin \
    /home/$USER/.vscode-server/extensions \
    /home/$USER/.vscode-server/extensionsCache

# /home/node e o volume nomeado do vscode-server são gerenciados pelo Docker
# (não são arquivos reais do host), então chown -R aqui é seguro.
sudo chown -R "$USER:$USER" /home/$USER
sudo chown -R "$USER:$USER" /workspaces/.angular
sudo chown -R "$USER:$USER" /workspaces/node_modules
sudo chown -R "$USER:$USER" /workspaces/.vscode
# /workspaces é bind mount do host: depois do realinhamento acima o dono já
# deve bater. Evitamos chown -R recursivo nele (mexeria nos arquivos reais
# do projeto no host e pode ser lento em diretórios grandes); só corrigimos
# o ponto de montagem em si, como fallback.
if [ "$(stat -c '%u:%g' /workspaces)" != "$HOST_UID:$HOST_GID" ]; then
    sudo chown "$USER:$USER" /workspaces
fi

# Criar aplicação Angular se ainda não existir
if [ ! -f /workspaces/angular.json ]; then
    echo "[entrypoint] Criando aplicação Angular..."

    cd /workspaces

    ng new angular-app \
        --routing \
        --style=scss \
        --skip-git \
        --skip-install

    chown -R node:node /workspaces/angular-app
else
    echo "[entrypoint] Aplicação Angular já existe."
fi

exec "$@"
