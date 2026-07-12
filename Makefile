SHELL := /usr/bin/env bash

.PHONY: check validate render publish-b2 rollback-b2 configure-github bootstrap-cilium bootstrap-flux sync-flux-secret status b2-init b2-validate b2-plan b2-apply b2-import

check:
	mise run check

validate:
	mise run validate

render:
	mise run render

publish-b2:
	mise run publish-b2

rollback-b2:
	@test -n "$(RELEASE_ID)" || { echo "set RELEASE_ID=<git-sha>" >&2; exit 1; }
	mise run rollback-b2 "$(RELEASE_ID)"

configure-github:
	mise run configure-github

bootstrap-cilium:
	mise run bootstrap-cilium

bootstrap-flux:
	mise run bootstrap-flux

sync-flux-secret:
	mise run sync-flux-secret

status:
	mise run status

b2-init:
	mise run b2:tf:init

b2-validate:
	mise run b2:tf:validate

b2-plan:
	mise run b2:tf:plan

b2-apply:
	mise run b2:tf:apply

b2-import:
	@test -n "$(BUCKET_ID)" || { echo "set BUCKET_ID=<b2-bucket-id>" >&2; exit 1; }
	mise run b2:tf:import-manual "$(BUCKET_ID)"
