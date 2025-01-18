# Nome del file di default per Docker Compose
DOCKER_COMPOSE_FILE := docker-compose.yml
CONTAINER_NAME := manzolo-ubuntu
SERVICE_NAME := manzolo-ubuntu
IMAGE_NAME := manzolo/ubuntu

# Target per avviare i container
start:
	@echo "Consentire connessioni X11 locali"
	@xhost +SI:localuser:$(shell id -un)
	@echo "Riavvio i container Docker Compose"
	docker compose run --remove-orphans ${SERVICE_NAME} /usr/bin/emulationstation

# Target per fermare i container
stop:
	@echo "Fermo e rimuovo i container Docker Compose"
	docker compose down

# Target per avviare i container
restart:
	@echo "Consentire connessioni X11 locali"
	@xhost +SI:localuser:$(shell id -un)
	@echo "Riavvio i container Docker Compose"
	docker compose down
	docker compose rm -f
	docker compose run --remove-orphans ${SERVICE_NAME} /usr/bin/emulationstation 

# Target per la build dell'immagine
build:
	@echo "Build dell'immagine"
	$(eval TAG := $(shell date +'%Y%m%d-%H%M%S'))
	docker build --progress=plain -t ${IMAGE_NAME}:$(TAG) .
	@echo "Immagine costruita: ${IMAGE_NAME}:$(TAG)"
	docker tag ${IMAGE_NAME}:$(TAG) ${IMAGE_NAME}:22.04
	@echo "Immagine taggata come latest: ${IMAGE_NAME}:22.04"

# Target per la build dell'immagine
logs:
	@echo "Container logs"
	docker compose logs -f

# Target per la build dell'immagine
enter:
	@echo "Consentire connessioni X11 locali"
	@xhost +SI:localuser:$(shell id -un)
	@echo "Enter Container"
	docker compose run --remove-orphans $(SERVICE_NAME) /bin/bash
