.PHONY: help dev up up-% down down-% clean check _check_% test build audit outdated %_cache
.DEFAULT_GOAL := help

include Makefile.config

# Generate image name if unsupplied and expose for hook scripts
export IMAGE_NAME ?= $(VENDOR)/$(DOCKER_REPO)

help: ## Documentation of available targets
	@awk -F ':|##' '/^[^\t].+:.*##/ {printf "\033[36m%-15s\033[0m %s\n", $$1, $$NF }' $(MAKEFILE_LIST) | sort


########################################
## Tasks - PHONY
########################################

debug:
	@echo $(IMAGE_NAME)

webserver: $(PUBLIC)/bundles $(PUBLIC)/dist var/cache
	$(if not $(PARALLEL),@echo Tip: Use "make up -j2" for improved performance)
	$(call style,"Starting containers...",$(STYLE_success))
	@$(COMPOSE) up -d --no-recreate $@

$(APP): $(DC)
	$(call style,"Starting $@ container...",$(STYLE_success))
	@$(COMPOSE) up -d --no-deps $@

up: webserver ## Start local development environment
	@printf "\033[0;32mStarted on port \033[1;32m%d\033[0m\n" $(shell $(COMPOSE) port webserver $(PORT) | cut -f 2 -d :)

up-%: docker-compose.%.yml
	@$(MAKE) -j2 --no-print-directory up DC=$< ENV=$*

down: $(DC) ## Stop local development environment
	@printf "\033[33m%s\033[0m\n" "Stopping containers and tidying up..."
	@$(COMPOSE) down -v --rmi $(RMI_FLAG) --remove-orphans

down-%: docker-compose.%.yml
	@$(MAKE) --no-print-directory down DC=$<

clean: ## Remove generated environment files
	$(call style,"Removing $(shell find -name ".*env" -type f -printf %f\\n | xargs -n1 --no-run-if-empty rm -v | sed -E "s/removed '(.+?)'/\1/g")",$(STYLE_error))

clobber: RMI_FLAG := all
clobber: down clean ## Remove everything not under version control
	rm -rf node_modules var vendor $(PUBLIC)/dist

_check_config: $(CONFIG) $(APP) composer.lock bin/console
	@echo Linting config
	@$(CONSOLE) lint:yaml $<

_check_js: ~/.npm/passwd .eslintrc src/Resources/assets/js
	@echo Linting JS
#	@$(NPM)

_check_sass: ~/.npm/passwd .sasslintrc src/Resources/assets/sass
	@echo Linting Sass
	@$(NPM) sass-lint

_check_php: src .php.cs
	@echo Linting PHP syntax
	@$(shell find $< -type f -name "*.php" -print0 | xargs -0 -n1 -P8 php -l | grep -v ^No)
	@echo Checking against coding standards
	@echo Running static analysis

_check_twig: src/Resources/views $(APP) composer.lock bin/console
	@echo Linting Twig
	@$(CONSOLE) lint:twig $<

check: _check_config _check_js _check_sass _check_php _check_twig ## Lint codebase

test: .test.env $(DC) ## Test the application
	@$(COMPOSE) run --rm --entrypoint nginx $(APP) -t

build: ENV := prod
build: check Dockerfile hooks/build ## Build the production image
	@printf "\033[33m%s\033[0m\n" "Building image..."
	@./hooks/build

clear_app_cache: bin/console
	@$(CONSOLE) cache:clear --env=$(if $(PRODUCTION),prod,dev)

clear_composer_cache:
	@$(COMPOSER) clear-cache

verify_npm_cache: ~/.npm/passwd
	@$(NPM) cache verify --cache /home/node/cache

audit: ~/.npm/passwd ## Audit npm dependencies
	@$(NPM) $@

outdated: ~/.npm/passwd ## List outdated dependencies from npm and Composer
	@$(NPM) $@
	@$(COMPOSER) $@


########################################
## Dependencies
########################################

docker-compose.yml: .env
docker-compose.ci.yml: .ci.env

%: %.dist # Pattern rule to generate environment files from dist versions
	$(call style,"Generating $@",$(STYLE_info))
	@$(shell comm -13 <(test -f $@ && cut -sd= -f1 $@ | sort) <(cut -sd= -f1 $< | sort) | xargs printf ^%s=\\n | grep -f - $< | envsubst >> $@)

~/.composer/vendor/hirak/prestissimo:
	@$(COMPOSER) \
		global require \
			--no-progress \
			--prefer-dist \
		hirak/prestissimo

vendor: ACTION := $(shell if [ -d vendor ]; then echo update; else echo install; fi)
vendor: ~/.composer/vendor/hirak/prestissimo composer.json
	@$(COMPOSER) \
		$(ACTION) \
			--ignore-platform-reqs \
			--classmap-authoritative \
			--no-scripts \
			--no-suggest \
			--no-progress \
			--prefer-dist \
			$(if $(ANSI),--ansi,--no-ansi) \
			$(if $(PARALLEL),--quiet,--profile) \
			$(if $(PRODUCTION),--no-dev)

composer.lock: vendor

$(PUBLIC)/bundles: composer.lock bin/console
	@$(CONSOLE) assets:install $(@D) --symlink --env=$(if $(PRODUCTION),prod --no-debug,dev)

var/cache: src composer.lock bin/console
	@$(CONSOLE) cache:warmup --env=$(if $(PRODUCTION),prod --no-debug,dev)

~/.npm:
	@mkdir $@

# https://lebenplusplus.de/2018/03/15/how-to-run-npm-install-as-non-root-from-a-docker-container/
~/.npm/passwd: ~/.npm
	@echo "node:x:$$(id -u):$$(id -g)::/home/node:/bin/sh" > $@

node_modules: ACTION := $(if $(findstring dev,$(ENV)),install,ci)
node_modules: ~/.npm/passwd package.json
	$(NPM) \
		$(ACTION) \
			--cache /home/node/cache \
			--ignore-scripts \
			$(if $(ANSI),--ansi,--no-ansi) \
			$(if $(PARALLEL),--no-progress) \
			$(if $(PRODUCTION),--production)

package-lock.json: node_modules

$(PUBLIC)/dist: ~/.npm/passwd webpack.$(ENV).js package-lock.json src/Resources/assets
	@$(NPM) $(if $(PRODUCTION),build,start)
