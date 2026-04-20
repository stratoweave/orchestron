GENERATED_ACT := src/stratoweave/device_meta_config.act src/stratoweave/ietf_restconf_monitoring.act

.PHONY: build
build: $(GENERATED_ACT)
	acton build $(DEP_OVERRIDES)

.PHONY: build-ldep
build-ldep: $(GENERATED_ACT)
	$(MAKE) build DEP_OVERRIDES="--dep yang=../acton-yang --dep netconf=../netconf --dep http_router=../http-router --dep actmf=../actmf"

.PHONY: gen
gen: $(GENERATED_ACT)

.PHONY: gen-ldep
gen-ldep: DEP_OVERRIDES=--dep yang=../acton-yang
gen-ldep: $(GENERATED_ACT)
	$(MAKE) --always-make gen DEP_OVERRIDES="--dep yang=../acton-yang"

.NOTPARALLEL: $(GENERATED_ACT)
$(GENERATED_ACT): gen_adata/out/bin/gen_adata src/stratoweave/yang.act
	@if [ ! -f "$@" ] || [ "$@" -ot gen_adata/out/bin/gen_adata ] || [ "$@" -ot src/stratoweave/yang.act ]; then \
		gen_adata/out/bin/gen_adata; \
	fi

gen_adata/out/bin/gen_adata: gen_adata/src/gen_adata.act src/stratoweave/yang.act
	cp -a src/stratoweave/yang.act gen_adata/src/swyang.act
	cd gen_adata && acton build $(subst ../,../../,$(DEP_OVERRIDES))

.PHONY: test
test:
	acton test $(DEP_OVERRIDES)

.PHONY: test-ldep
test-ldep:
	$(MAKE) test DEP_OVERRIDES="--dep yang=../acton-yang --dep netconf=../netconf --dep http_router=../http-router --dep actmf=../actmf"

.PHONY: pkg-upgrade
pkg-upgrade:
	acton pkg upgrade
	cd gen_adata && acton pkg upgrade
	cd minisys && acton pkg upgrade
	cd minisys/gen && acton pkg upgrade

.PHONY: check-dep-consistency
check-dep-consistency:
	@python3 scripts/check_dep_consistency.py

.PHONY: test-mini
test-mini: check-mini-is-up-to-date
	cd minisys && acton test
	bash minisys/test/test_persistence_restart.sh

.PHONY: test-mini-ldep
test-mini-ldep: check-mini-is-up-to-date
	cd minisys && acton test --dep yang=../../acton-yang --dep netconf=../../netconf --dep http_router=../../http-router --dep actmf=../../actmf
	ACTON_BUILD_ARGS="--dep yang=../acton-yang --dep netconf=../netconf --dep http_router=../http-router --dep actmf=../actmf" bash minisys/test/test_persistence_restart.sh

.PHONY: check-mini-is-up-to-date
check-mini-is-up-to-date:
	$(MAKE) gen-mini
	git diff --exit-code

.PHONY: build-mini
build-mini:
	cd minisys && acton build

.PHONY: build-mini-ldep
build-mini-ldep:
	cd minisys && acton build --dep yang=../../acton-yang --dep netconf=../../netconf --dep http_router=../../http-router --dep actmf=../../actmf

.PHONY: gen-mini
gen-mini:
	cd minisys/gen && acton build && out/bin/gen

.PHONY: gen-mini-ldep
gen-mini-ldep:
	cd minisys/gen && acton build --dep yang=../../../acton-yang --dep netconf=../../../netconf --dep http_router=../../../http-router --dep actmf=../../../actmf && out/bin/gen
