FROM debian:bullseye-slim as base
WORKDIR /app

RUN apt-get update && apt-get install -y openssh-server jq zsh curl sshpass

COPY . /app/

# Instantiate Anka runner after dependencies are installed
CMD [ "zsh", "/app/codebase/main_orchestrator.zsh"]
