SHELL := /bin/zsh
SCRIPTS := scripts
BRANCH ?= dev
SIBLING := $(shell cd .. && pwd)

# Client repo → netlify_dist directory name
client_dir = $(if $(filter core-client-dashboard,$(1)),main,\
  $(if $(filter core-client-content,$(1)),content,\
  $(if $(filter core-client-i18n-editor,$(1)),i18n-editor,\
  $(if $(filter core-client-remote-repos,$(1)),download,\
  $(if $(filter core-client-settings,$(1)),settings,\
  $(if $(filter core-client-workspace,$(1)),core-local-workspace,\
  $(1)))))))

.PHONY: clone build assemble deploy all clean quick

# Clone all sibling repos (clients + assets)
clone:
	cd $(SCRIPTS) && ./clone.zsh

# Build all clients (pulls latest, runs npm ci && npm run build)
build:
	cd $(SCRIPTS) && ./build_clients.zsh $(BRANCH) -d

# Assemble netlify_dist/ from built clients + assets
assemble:
	cd $(SCRIPTS) && ./build_for_netlify.sh

# Deploy to Netlify (requires `netlify link` first time)
# Omit --dir so the CLI reads netlify.toml and picks up edge functions
deploy:
	netlify deploy --prod

# Full pipeline: build clients, assemble, deploy
all: build assemble deploy

# Quick update: rebuild one client and deploy (skips full assemble)
# Usage: make quick CLIENT=core-client-dashboard
quick:
ifndef CLIENT
	$(error Usage: make quick CLIENT=core-client-dashboard)
endif
	cd $(SIBLING)/$(CLIENT) && npm run build
	rm -rf netlify_dist/clients/$(call client_dir,$(CLIENT))
	cp -R $(SIBLING)/$(CLIENT)/build netlify_dist/clients/$(call client_dir,$(CLIENT))
	@test -f globalBuildResources/favicon.ico && \
		cp globalBuildResources/favicon.ico netlify_dist/clients/$(call client_dir,$(CLIENT))/ || true
	netlify deploy --prod

# Remove build output
clean:
	rm -rf netlify_dist
