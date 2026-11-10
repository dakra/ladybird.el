# Targets for the Emacs Lisp package and the mock server.  Included by
# the Makefile; also usable alone: make -f mk/elisp.mk TARGET

EMACS      ?= emacs
PYTHON     ?= python3
EMACSFLAGS ?=

ELISP_SOURCES := lisp/ladybird-keys.el lisp/ladybird-conn.el lisp/ladybird.el
ELISP_TESTS   := test/ladybird-keys-test.el test/ladybird-conn-test.el \
                 test/ladybird-render-test.el
ELISP_ELC_DIR := .build/elc
ELISP_EMACS    = $(EMACS) --batch $(EMACSFLAGS) -Q -L lisp -L test
ELISP_RUN_TESTS = $(ELISP_EMACS) -l ert $(foreach test,$(ELISP_TESTS),-l $(test))
# Directory of a native module built with the test accessors.
ELISP_TEST_MODULE_DIR ?= $(CURDIR)/.build/test-module

EXTRA_TEST_TARGETS += test-elisp

.PHONY: byte-compile test-elisp test-mock test-mock-native checkdoc lint-elisp \
        package-lint selftest-mock mock elate live

# The compiled files go to $(ELISP_ELC_DIR), so the tests load the sources.
byte-compile:
	@mkdir -p $(ELISP_ELC_DIR)
	$(ELISP_EMACS) \
		--eval "(setq byte-compile-error-on-warn t)" \
		--eval "(setq byte-compile-dest-file-function \
		          (lambda (file) (expand-file-name \
		            (concat (file-name-nondirectory file) \"c\") \
		            \"$(ELISP_ELC_DIR)\")))" \
		-f batch-byte-compile $(ELISP_SOURCES)

# The stream fixtures are generated; the Makefile's `fixtures' target
# makes them too.
ELISP_FIXTURE := test/fixtures/basic-raw-full.ladybird
$(ELISP_FIXTURE): test/fixtures/gen_stream.py tools/ladybird_protocol.py
	$(PYTHON) -I test/fixtures/gen_stream.py test/fixtures/

# ERT with the fake module, without the tests that start the mock server.
test-elisp: $(ELISP_FIXTURE)
	$(ELISP_RUN_TESTS) \
		--eval "(ert-run-tests-batch-and-exit '(not (tag mock)))"

# ERT against tools/mock-server.py, with the fake module.
test-mock: selftest-mock
	$(ELISP_RUN_TESTS) \
		--eval "(ert-run-tests-batch-and-exit '(tag mock))"

# The same with the native module of $(ELISP_TEST_MODULE_DIR).
test-mock-native:
	LADYBIRD_TEST_MODULE=1 LADYBIRD_MODULE_DIR=$(ELISP_TEST_MODULE_DIR) \
	$(ELISP_RUN_TESTS) \
		--eval "(ert-run-tests-batch-and-exit '(tag mock))"

selftest-mock:
	$(PYTHON) -I tools/ladybird_protocol.py --selftest
	$(PYTHON) -I tools/mock-server.py --selftest

checkdoc:
	$(ELISP_EMACS) \
		--eval "(require 'checkdoc)" \
		--eval "(let ((sentence-end-double-space nil) \
		              (checkdoc-verb-check-experimental-flag nil) \
		              (ok t)) \
		  (ignore-errors (kill-buffer \"*Warnings*\")) \
		  (let ((inhibit-message t)) \
		    (dolist (file '($(foreach file,$(ELISP_SOURCES),\"$(file)\"))) \
		      (checkdoc-file file))) \
		  (when (get-buffer \"*Warnings*\") \
		    (setq ok nil) \
		    (with-current-buffer \"*Warnings*\" (message \"%s\" (buffer-string)))) \
		  (unless ok (kill-emacs 1)))"

XDG_CACHE_HOME   ?= $(HOME)/.cache
LINT_ELPA_DIR    ?= $(XDG_CACHE_HOME)/ladybird-lint-elpa
LINT_DEPS_STAMP  := $(LINT_ELPA_DIR)/.deps-installed

$(LINT_DEPS_STAMP):
	$(EMACS) --batch $(EMACSFLAGS) -Q \
		--eval "(setq package-user-dir \"$(LINT_ELPA_DIR)\")" \
		--eval "(package-initialize)" \
		--eval "(add-to-list 'package-archives '(\"melpa\" . \"https://melpa.org/packages/\"))" \
		--eval "(package-refresh-contents)" \
		--eval "(package-install 'package-lint)"
	@touch $@

# Warnings are shown and do not fail: requiring an Emacs that is not
# released yet is one.
package-lint: $(LINT_DEPS_STAMP)
	$(EMACS) --batch $(EMACSFLAGS) -Q -L lisp \
		--eval "(setq package-user-dir \"$(LINT_ELPA_DIR)\")" \
		--eval "(package-initialize)" \
		--eval "(require 'package-lint)" \
		--eval "(setq package-lint-main-file \"lisp/ladybird.el\" \
		              package-lint-batch-fail-on-warnings nil)" \
		-f package-lint-batch-and-exit $(ELISP_SOURCES)

lint-elisp: byte-compile checkdoc package-lint

# Run the mock server on a Unix socket; MOCK_FLAGS adds options.
MOCK_SOCKET ?= /tmp/ladybird-mock.sock
MOCK_FLAGS  ?=
mock:
	$(PYTHON) -I tools/mock-server.py --socket $(MOCK_SOCKET) $(MOCK_FLAGS)

# The end-to-end scenarios of test/elate, in sandboxed Emacs sessions,
# against the mock server.
elate:
	test/elate/run.sh

# The scenarios of test/elate/live against a real Ladybird server; see
# test/elate/README.md for the variables.  They read canvas pixels with
# the module that has the test accessors.
live: $(TEST_MODULE)
	test/elate/run-live.sh
