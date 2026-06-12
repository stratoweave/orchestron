PROJECT_DIR:=$(realpath $(dir $(lastword $(MAKEFILE_LIST)))/../../)
# Set this env var to empty string if you have local cRPD, XRd container images
export IMAGE_PATH?=ghcr.io/stratoweave/

ifeq (true,$(REMOTE_CONTAINERS))
CLAB_BIN:=containerlab
else ifeq (true,$(CODESPACES))
CLAB_BIN:=containerlab
else

# Optionally redirect containerlab's lab state directory (clab-<name>/) out
# of the source tree. Useful when node state is root-owned (e.g. XRd
# xr-storage), which breaks source-tree scanning and docker build contexts.
export CLAB_LABDIR_BASE?=
ifneq ($(strip $(CLAB_LABDIR_BASE)),)
CLAB_LABDIR_ARGS:=-e CLAB_LABDIR_BASE=$(CLAB_LABDIR_BASE) -v $(CLAB_LABDIR_BASE):$(CLAB_LABDIR_BASE)
endif

CLAB_VERSION?=0.69.3
CLAB_CONTAINER_IMAGE?=ghcr.io/srl-labs/clab:$(CLAB_VERSION)
CLAB_BIN:=docker run --rm $(INTERACTIVE) --privileged \
    --network host \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v /var/run/netns:/var/run/netns \
    -v /etc/hosts:/etc/hosts \
    -v /var/lib/docker/containers:/var/lib/docker/containers \
	-v ${HOME}/.docker:/root/.docker \
    --pid="host" \
    -v $(PROJECT_DIR):$(PROJECT_DIR) \
    -e IMAGE_PATH=$(IMAGE_PATH) \
    $(CLAB_LABDIR_ARGS) \
    -w $(CURDIR) \
    $(CLAB_CONTAINER_IMAGE) containerlab
endif
