# Usa bash come shell predefinita per l'esecuzione dei comandi
SHELL = /bin/bash

# Nome del file .env
ENV_FILE := .env

# Carica le variabili dal file .env
ifneq (,$(wildcard $(ENV_FILE)))
    include $(ENV_FILE)
    export $(shell sed 's/=.*//' $(ENV_FILE))
endif

# Target di default: mostra la lista dei comandi disponibili
.PHONY: help
help:
	@echo "Comandi disponibili:"
	@echo "  make start                     Avvia il container con la versione NVIDIA di default (575)"
	@echo "  make start-nvidia-<version>    Avvia il container con una versione NVIDIA specifica (es. 550, 570)"
	@echo "  make enter                     Entra nel container con la versione NVIDIA di default (575)"
	@echo "  make enter-nvidia-<version>    Entra nel container con una versione NVIDIA specifica (es. 550, 570)"
	@echo "  make build                     Costruisce l'immagine con la versione NVIDIA di default (575)"
	@echo "  make build-nvidia-<version>    Costruisce l'immagine con una versione NVIDIA specifica"
	@echo "  make build-all                 Costruisce tutte le immagini per le versioni NVIDIA definite"
	@echo "  make push-all                  Esegue il push di tutte le immagini NVIDIA"
	@echo "  make push-nvidia-<version>     Esegue il push di una singola immagine NVIDIA"
	@echo "  make registry_push             Esegue il push dell'immagine di default (575)"
	@echo "  make stop                      Ferma e rimuove i container Docker Compose"
	@echo "  make logs                      Visualizza i log dei container"
	@echo "  make clean                     Rimuove tutte le immagini locali"

# Target per avviare i container con una versione NVIDIA specifica
start-nvidia-%:
	@echo "Consentire connessioni Wayland locali"
	@chmod 700 ${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY} || true
	@echo "Avvio container per NVIDIA_MAJOR_VERSION=$*"
	@IMAGE_TAG=latest-nvidia$* NVIDIA_MAJOR_VERSION=$* docker compose run --remove-orphans ${SERVICE_NAME} /bin/bash

# Target per avviare i container (default)
start:
	@echo "Consentire connessioni Wayland locali"
	@chmod 700 ${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY} || true
	@echo "Avvio container per NVIDIA_MAJOR_VERSION=${NVIDIA_MAJOR_VERSION} (default)"
	@IMAGE_TAG=latest-nvidia${NVIDIA_MAJOR_VERSION} NVIDIA_MAJOR_VERSION=${NVIDIA_MAJOR_VERSION} docker compose run --remove-orphans ${SERVICE_NAME} /bin/bash

# Target per fermare i container
stop:
	@echo "Fermo e rimuovo i container Docker Compose"
	docker compose down
	docker compose rm -f

# Target per la build di tutte le immagini
build-all: $(addprefix build-nvidia-,$(NVIDIA_VERSIONS))

# Target per la build di una singola versione NVIDIA
build-nvidia-%:
	@echo "Build dell'immagine per NVIDIA_MAJOR_VERSION=$*"
	@FALLBACK_VAR=NVIDIA_FALLBACK_$*; \
	FALLBACK_VALUE=$${!FALLBACK_VAR:-}; \
	if [ -z "$$FALLBACK_VALUE" ]; then \
		echo "Errore: NVIDIA_FALLBACK_$* non definito nel file .env"; \
		exit 1; \
	fi; \
	docker build \
	--build-arg CONTAINER_USERNAME=${CONTAINER_USERNAME} \
	--build-arg NVIDIA_MAJOR_VERSION=$* \
	--build-arg NVIDIA_FALLBACK_VERSION=$$FALLBACK_VALUE \
	-t ${IMAGE_OWNER}/${IMAGE_NAME}:latest-nvidia$* .
	@echo "Immagine costruita: ${IMAGE_OWNER}/${IMAGE_NAME}:latest-nvidia$*"

# Target per la build di una singola immagine (senza versione NVIDIA specifica)
build:
	@echo "Build dell'immagine per NVIDIA_MAJOR_VERSION=${NVIDIA_MAJOR_VERSION}"
	@FALLBACK_VAR=NVIDIA_FALLBACK_${NVIDIA_MAJOR_VERSION}; \
	FALLBACK_VALUE=$${!FALLBACK_VAR:-}; \
	if [ -z "$$FALLBACK_VALUE" ]; then \
		echo "Errore: NVIDIA_FALLBACK_${NVIDIA_MAJOR_VERSION} non definito nel file .env"; \
		exit 1; \
	fi; \
	docker build \
	--build-arg CONTAINER_USERNAME=${CONTAINER_USERNAME} \
	--build-arg NVIDIA_MAJOR_VERSION=${NVIDIA_MAJOR_VERSION} \
	--build-arg NVIDIA_FALLBACK_VERSION=$$FALLBACK_VALUE \
	-t ${IMAGE_OWNER}/${IMAGE_NAME}:latest-nvidia${NVIDIA_MAJOR_VERSION} .
	@echo "Immagine costruita: ${IMAGE_OWNER}/${IMAGE_NAME}:latest-nvidia${NVIDIA_MAJOR_VERSION}"

# Target per il push di tutte le immagini
push-all: $(addprefix push-nvidia-,$(NVIDIA_VERSIONS))

# Target per il push di una singola versione NVIDIA
push-nvidia-%:
	@echo "Push dell'immagine per NVIDIA_MAJOR_VERSION=$*"
	docker push ${IMAGE_OWNER}/${IMAGE_NAME}:latest-nvidia$*

# Target per il push dell'immagine di default
registry_push:
	@echo "Push dell'immagine di default (NVIDIA_MAJOR_VERSION=${NVIDIA_MAJOR_VERSION})"
	docker push ${IMAGE_OWNER}/${IMAGE_NAME}:latest-nvidia${NVIDIA_MAJOR_VERSION}

# Target per visualizzare i log
logs:
	@echo "Container logs"
	docker compose logs -f

# Target per entrare nel container con una versione NVIDIA specifica
enter-nvidia-%:
	@echo "Consentire connessioni Wayland locali"
	@chmod 700 ${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY} || true
	@echo "Enter Container per NVIDIA_MAJOR_VERSION=$*"
	@IMAGE_TAG=latest-nvidia$* NVIDIA_MAJOR_VERSION=$* docker compose run \
	-e ENTRYPOINT_DEBUG=${ENTRYPOINT_DEBUG} \
	-e SUDO_NOPASSWD=${SUDO_NOPASSWD} \
	-e LANG=${LANG} \
	-e TZ=${TZ} \
	-e WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-wayland-0} \
	--remove-orphans ${SERVICE_NAME} /bin/bash

# Target per entrare nel container (default)
enter:
	@echo "Consentire connessioni Wayland locali"
	@chmod 700 ${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY} || true
	@echo "Enter Container per NVIDIA_MAJOR_VERSION=${NVIDIA_MAJOR_VERSION} (default)"
	@IMAGE_TAG=latest-nvidia${NVIDIA_MAJOR_VERSION} NVIDIA_MAJOR_VERSION=${NVIDIA_MAJOR_VERSION} docker compose run \
	-e ENTRYPOINT_DEBUG=${ENTRYPOINT_DEBUG} \
	-e SUDO_NOPASSWD=${SUDO_NOPASSWD} \
	-e LANG=${LANG} \
	-e TZ=${TZ} \
	-e WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-wayland-0} \
	--remove-orphans ${SERVICE_NAME} /bin/bash

# Target per pulire le immagini
clean:
	@echo "Rimozione delle immagini locali"
	@docker rmi $(foreach ver,$(NVIDIA_VERSIONS),${IMAGE_OWNER}/${IMAGE_NAME}:latest-nvidia$(ver)) || true
	@docker rmi ${IMAGE_OWNER}/${IMAGE_NAME}:latest || true
	@docker rmi $(shell docker images -q ${IMAGE_OWNER}/${IMAGE_NAME}:[0-9]*) || true
