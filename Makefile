SHELL := /bin/zsh
SCRIPTS := scripts
BRANCH ?= dev

.PHONY: clone build assemble deploy all clean

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
deploy:
	netlify deploy --dir=netlify_dist --prod

# Full pipeline: build clients, assemble, deploy
all: build assemble deploy

# Remove build output
clean:
	rm -rf netlify_dist
