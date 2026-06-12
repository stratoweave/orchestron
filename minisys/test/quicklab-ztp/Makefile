TESTENV=mini-quicklab-ztp

# Build the mini binary natively: the sweave container (debian) runs on the
# same architecture as the build host.
ACTON_TARGET ?=

# Keep containerlab's lab state (XRd xr-storage is root-owned) out of the
# source tree so acton builds and docker build contexts keep working with a
# deployed lab.
CLAB_LABDIR_BASE=/tmp/$(TESTENV)-lab

include ../common/clab.mk
include ../common/quicklab.mk

labdir:
	mkdir -p $(CLAB_LABDIR_BASE)

start: certs labdir

# The OPI sztp-agent insists on having device identity certificates even in
# plain-HTTP lab mode; generate self-signed throwaways.
certs/private_key.pem:
	mkdir -p certs
	openssl req -x509 -newkey rsa:2048 -keyout certs/private_key.pem \
	    -out certs/my_cert.pem -days 365 -nodes -subj "/CN=first-serial-number"
	cp certs/my_cert.pem certs/opi.pem

.PHONY: certs
certs: certs/private_key.pem

.PHONY: ztp-status
ztp-status:
	curl -s http://localhost:$(RESTCONF_PORT)/ztp | python3 -m json.tool

.PHONY: ztp-xrd1 ztp-sztp-dev1
ztp-xrd1:
	curl -s http://localhost:$(RESTCONF_PORT)/device/xrd1/ztp | python3 -m json.tool

ztp-sztp-dev1:
	curl -s http://localhost:$(RESTCONF_PORT)/device/sztp-dev1/ztp | python3 -m json.tool

.PHONY: xrd1-console
xrd1-console:
	docker logs -f $(TESTENV)-xrd1

.PHONY: kea-leases
kea-leases:
	curl -s -X POST -H "Content-Type: application/json" \
	    -d '{ "command": "lease4-get-all", "service": [] }' http://172.31.255.11:8000/ | python3 -m json.tool

# Change the hostname of the ZTP-onboarded xrd1 through the normal
# northbound API; the RFS transform renders it into XR config and the
# device manager pushes it over NETCONF.
.PHONY: set-hostname
HOSTNAME?=ztp-was-here
set-hostname:
	curl -X PATCH -H "Content-Type: application/yang-data+xml" \
	    -d '<data><netinfra xmlns="http://example.com/netinfra"><router><name>xrd1</name><id>1</id><type>xr</type><ztp>true</ztp><hostname>$(HOSTNAME)</hostname></router></netinfra></data>' \
	    http://localhost:$(RESTCONF_PORT)/restconf/data
