AIRLOCK_ENGINE ?= docker
IMAGE ?= airlock:latest

.PHONY: build run

build:
	$(AIRLOCK_ENGINE) build -t $(IMAGE) .

# make run ARGS="--shell"
run: build
	AIRLOCK_IMAGE=$(IMAGE) ./airlock $(ARGS)
