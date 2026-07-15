.PHONY: help run test test-mac test-relay check-js package web relay deploy-config

help:
	@echo "MacPet development commands"
	@echo "  make run           Run the macOS app from source"
	@echo "  make test          Run all tests and syntax checks"
	@echo "  make package       Build outputs/MacPet.app"
	@echo "  make web           Serve the local web companion"
	@echo "  make relay         Run the relay locally"
	@echo "  make deploy-config Validate Docker Compose configuration"

run:
	swift run MacPet

test: test-mac test-relay check-js

test-mac:
	swift test

test-relay:
	npm test --prefix relay

check-js:
	node --check relay/server.mjs
	node --check web/app.js

package:
	./packaging/package-app.sh

web:
	python3 -m http.server 4173 --directory .

relay:
	npm start --prefix relay

deploy-config:
	docker compose -f deploy/compose.yaml config
