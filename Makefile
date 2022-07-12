.PHONY: deps

#
# Use Bash as shell for evaluating expressions by make
#
SHELL=/bin/bash

BASE_DIR         = $(shell pwd)

#
# Setup Git repository URL. By default Git URL from this repository
# is used. In case ONEDATA_GIT_URL environment variable is defined,
# use it instead of the default.
#
GIT_URL := $(shell git config --get remote.origin.url | sed -e 's/\(\/[^/]*\)$$//g')
GIT_URL := $(shell if [ "${GIT_URL}" = "file:/" ]; then echo 'ssh://git@git.onedata.org:7999/vfs'; else echo ${GIT_URL}; fi)
ONEDATA_GIT_URL := $(shell if [ "${ONEDATA_GIT_URL}" = "" ]; then echo ${GIT_URL}; else echo ${ONEDATA_GIT_URL}; fi)
export ONEDATA_GIT_URL


all: rel

upgrade:
	./rebar3 upgrade --all

compile:
	./rebar3 compile

rel: compile
	./rebar3 release

start:
	_build/default/rel/appmock/bin/appmock console

clean:
	#
	# Restore the rebar.lock if backup exists after failed build
	#
	@ if [ -f ./rebar.lock.bak ]; then \
		mv ./rebar.lock.bak rebar.lock; \
	fi
	./rebar3 clean

distclean: clean
	./rebar3 clean --all

##
## Submodules
##

submodules:
	git submodule sync --recursive ${submodule}
	git submodule update --init --recursive ${submodule}


##
## Dialyzer targets local
##

# Dialyzes the project.
dialyzer:
	./rebar3 dialyzer
