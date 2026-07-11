SHELL := /usr/bin/env bash

.PHONY: check render publish-b2 rollback-b2 configure-github bootstrap-cilium bootstrap-flux status

check:
	./scripts/check.sh

render:
	./scripts/render.sh

publish-b2:
	./scripts/publish-b2.sh

rollback-b2:
	@test -n "$(RELEASE_ID)" || { echo "set RELEASE_ID=<git-sha>" >&2; exit 1; }
	./scripts/rollback-b2.sh "$(RELEASE_ID)"

configure-github:
	./scripts/configure-github.sh

bootstrap-cilium:
	./scripts/bootstrap-cilium.sh

bootstrap-flux:
	./scripts/bootstrap-flux-b2.sh

status:
	kubectl get nodes
	flux get all -A
