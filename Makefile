IMAGE      ?= pi-sandbox
DOCKERFILE ?= Dockerfile.pi
SEVERITY   ?= HIGH,CRITICAL
DIR        ?=
TASK       ?=
MODEL      ?= minimax/minimax-m3
THINK      ?= high
PROVIDER   ?= llmbase
export MODEL THINK PROVIDER

.DEFAULT_GOAL := help

.PHONY: build run up chat sh down trivy clean help

build: ## Build the pi sandbox image
	docker build -t $(IMAGE) -f $(DOCKERFILE) .

run: ## One-shot: make run DIR=/path [TASK="..."] [MODEL=.. THINK=..] (interactive if no TASK)
	@test -n "$(DIR)" || { echo 'usage: make run DIR=/path [TASK="..."]'; exit 1; }
	./run.sh once "$(DIR)" "$(TASK)"

up: ## Start a persistent container on a folder: make up DIR=/path
	@test -n "$(DIR)" || { echo 'usage: make up DIR=/path'; exit 1; }
	./run.sh up "$(DIR)"

chat: ## Attach interactive pi chat (honors MODEL/THINK): make chat [MODEL=.. THINK=..]
	./run.sh chat

sh: ## Open a shell inside the running container
	./run.sh sh

down: ## Stop & remove the persistent container
	./run.sh down

trivy: ## Scan the built image for vulns (fails on HIGH/CRITICAL, fixable only)
	trivy image --severity $(SEVERITY) --ignore-unfixed --exit-code 1 $(IMAGE)
# No local trivy? swap the line above for the dockerized scanner:
#	docker run --rm -v /var/run/docker.sock:/var/run/docker.sock aquasec/trivy:latest \
#		image --severity $(SEVERITY) --ignore-unfixed --exit-code 1 $(IMAGE)

clean: ## Remove the container, image and pi's named state volume
	-docker rm -f pi-box
	-docker rmi $(IMAGE)
	-docker volume rm pi-agent-home

help: ## Show this help
	@grep -hE '^[a-z].*:.*##' $(MAKEFILE_LIST) | sed 's/:.*##/\t/' | sort
