SYSNAME=mini
build-sweave-image:
	docker build -t $(SYSNAME)-sweave-base -f ../common/Dockerfile.sweave .

.PHONY: start
start: build-sweave-image
	$(CLAB_BIN) deploy --topo $(TESTENV:$(SYSNAME)-%=%).clab.yml --log-level debug --reconfigure

.PHONY: stop
stop:
	$(CLAB_BIN) destroy --topo $(TESTENV:$(SYSNAME)-%=%).clab.yml --log-level debug

.PHONY: wait $(addprefix wait-,$(ROUTERS_XR))
WAIT?=60
wait: $(addprefix platform-wait-,$(ROUTERS_XR))

.PHONY: copy
copy:
	docker cp ../../out/bin/$(SYSNAME) $(TESTENV)-sweave:/$(SYSNAME)
	docker cp netinfra.xml $(TESTENV)-sweave:/netinfra.xml

ifndef CI
INTERACTIVE=-it
endif

.PHONY: run
run: copy
	docker exec $(INTERACTIVE) $(TESTENV)-sweave /$(SYSNAME) --rts-bt-dbg

.PHONY: run-and-configure
run-and-configure: copy
	docker exec $(INTERACTIVE) -e EXIT_ON_DONE=$(CI) $(TESTENV)-sweave /$(SYSNAME) netinfra.xml --rts-bt-dbg

.PHONY: configure
configure:
	$(MAKE) FILE="netinfra.xml" send-config

.PHONY: shell
shell:
	docker exec -it $(TESTENV)-sweave bash -l

.PHONY: send-config-async
send-config-async:
	curl -X PUT -H "Content-Type: application/yang-data+xml" -H "Async: true" -d @$(FILE) http://localhost:$(shell docker inspect -f '{{(index (index .NetworkSettings.Ports "80/tcp") 0).HostPort}}' $(TESTENV)-sweave)/restconf/data

.PHONY: send-config-wait
send-config-wait:
	curl -X PUT -H "Content-Type: application/yang-data+xml" -d @$(FILE) http://localhost:$(shell docker inspect -f '{{(index (index .NetworkSettings.Ports "80/tcp") 0).HostPort}}' $(TESTENV)-sweave)/restconf/data

.PHONY: get-config0 get-config1 get-config2
get-config0 get-config1 get-config2:
	curl -H "Accept: application/yang-data+xml" http://localhost:$(shell docker inspect -f '{{(index (index .NetworkSettings.Ports "80/tcp") 0).HostPort}}' $(TESTENV)-sweave)/layer/$(subst get-config,,$@)

.PHONY: get-config-adata0 get-config-adata1 get-config-adata2
get-config-adata0 get-config-adata1 get-config-adata2:
	@curl -H "Accept: application/yang-data+acton-adata" http://localhost:$(shell docker inspect -f '{{(index (index .NetworkSettings.Ports "80/tcp") 0).HostPort}}' $(TESTENV)-sweave)/layer/$(subst get-config-adata,,$@)

.PHONY: delete-rtr1
delete-rtr1:
	curl -X DELETE http://localhost:$(shell docker inspect -f '{{(index (index .NetworkSettings.Ports "80/tcp") 0).HostPort}}' $(TESTENV)-sweave)/restconf/data/netinfra:netinfra/router=rtr1
