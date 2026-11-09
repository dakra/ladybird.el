EMACS      ?= emacs
PYTHON     ?= python3
# Extra flags injected before every Emacs invocation.
EMACSFLAGS ?=

UNAME := $(shell uname 2>/dev/null)
ifeq ($(UNAME),Darwin)
  MODULE := ladybird-module.dylib
else
  MODULE := ladybird-module.so
endif

ZIG_BUILD_FLAGS := -Doptimize=ReleaseFast -Dcpu=baseline $(ZIG_TARGET_FLAG)
ZIG_SOURCES := $(wildcard src/*.zig src/*.h build.zig build.zig.zon symbols.map) \
               $(wildcard vendor/*.h vendor/zstd/*)

# The module with the test-only Lisp functions, loaded by `test-native'.
TEST_MODULE_DIR := .build/test-module
TEST_MODULE     := $(TEST_MODULE_DIR)/$(MODULE)

FIXTURES_STAMP  := .build/fixtures.stamp
FIXTURE_SOURCES := test/fixtures/gen_stream.py tools/ladybird_protocol.py

# Test targets that other makefiles add to `test'.
EXTRA_TEST_TARGETS :=

.PHONY: all build test test-zig test-native test-module fixtures clean

all: build

build: $(MODULE)

$(MODULE): $(ZIG_SOURCES)
	zig build --prefix . $(ZIG_BUILD_FLAGS)

$(TEST_MODULE): $(ZIG_SOURCES)
	zig build --prefix $(TEST_MODULE_DIR) -Dtest-helpers=true $(ZIG_BUILD_FLAGS)

fixtures: $(FIXTURES_STAMP)

$(FIXTURES_STAMP): $(FIXTURE_SOURCES)
	$(PYTHON) -I test/fixtures/gen_stream.py test/fixtures/
	@mkdir -p $(@D) && touch $@

test-zig: fixtures
	zig build $(ZIG_TARGET_FLAG) test --summary all

test-native: build $(TEST_MODULE) fixtures
	LADYBIRD_MODULE_DIR=$(TEST_MODULE_DIR) $(EMACS) --batch $(EMACSFLAGS) -Q -L lisp -L test \
		-l ert -l test/ladybird-test-helpers.el -l test/ladybird-module-test.el \
		-f ert-run-tests-batch-and-exit

test-module: test-zig test-native

-include mk/elisp.mk

test: test-module $(EXTRA_TEST_TARGETS)

clean:
	rm -rf .build .zig-cache zig-out ladybird-module.dylib ladybird-module.so ladybird-module.version
