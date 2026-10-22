# Build and test the libarchive binding.
#
#   make test       -- run the FiveAM suite
#   make fuzz       -- test, with 5000 damaged archives per format (FUZZ=N for more)
#   make check      -- test, then load everything and report the library version
#   make examples   -- run every program in examples/ (each checks its own output)
#   make example NAME=quickstart  -- run one
#   make la         -- build the la archive tool at bin/la
#   make docs       -- bin/la.1, bin/_la (zsh) and bin/la.bash
#   make cli-test   -- la's FiveAM suite, then ci/cli-smoke.sh against bin/la
#   make generate   -- regenerate the raw layer from the installed headers
#   make clean      -- drop this tree's fasl caches
#
# LISP=ccl or LISP=ecl runs test, check and examples on another implementation.
#
# There is no binary to build: this is a library.

# LISP picks the implementation for test, check and examples: sbcl (the
# default), ccl or ecl. The la binary is SBCL only.
LISP       ?= sbcl
SBCL       ?= sbcl
SBCL_FLAGS := --noinform --non-interactive --no-userinit --no-sysinit
ifeq ($(LISP),sbcl)
  LISP_FLAGS := $(SBCL_FLAGS)
else ifneq (,$(findstring ccl,$(LISP))$(findstring lx86cl,$(LISP)))
  LISP_FLAGS := --no-init --batch --quiet
else ifneq (,$(findstring ecl,$(LISP)))
  LISP_FLAGS := --norc
else
  $(error LISP=$(LISP): say how to run it without init files in the Makefile)
endif
QUIT := --eval "(uiop:quit 0)"
PYTHON     ?= python3

# The headers the raw layer is generated from. Homebrew's libarchive is keg-only.
LIBARCHIVE_INCLUDE ?= $(shell brew --prefix libarchive 2>/dev/null || echo /usr)/include

# Hermetic: this tree and its vendored ocicl/ dependencies, nothing inherited. If
# something is missing we want a loud failure, not a neighbour's copy.
BOOT := --eval "(require :asdf)" \
        --eval "(asdf:initialize-source-registry \`(:source-registry (:tree ,(truename \"./\")) :ignore-inherited-configuration))"

.PHONY: test fuzz check examples example la docs cli-test generate clean help
.DEFAULT_GOAL := test

# Each example in its own fresh image, so none can lean on another's definitions.
EXAMPLES := $(wildcard examples/*.lisp)
RUN_EXAMPLE = $(LISP) $(LISP_FLAGS) $(BOOT) --eval "(asdf:load-system :libarchive)" \
                --load $(1) $(QUIT) </dev/null

test:
	$(LISP) $(LISP_FLAGS) $(BOOT) \
	  --eval "(asdf:test-system :libarchive)" $(QUIT) </dev/null

FUZZ ?= 5000
fuzz:
	LIBARCHIVE_FUZZ_ITERATIONS=$(FUZZ) $(MAKE) test

check: test
	$(LISP) $(LISP_FLAGS) $(BOOT) \
	  --eval "(asdf:load-system :libarchive)" \
	  --eval "(format t \"~&~A loaded: ~D exported symbols~%\" \
	            (libarchive:version-string) \
	            (let ((n 0)) (do-external-symbols (s :libarchive) (declare (ignore s)) (incf n)) n))" \
	  $(QUIT) </dev/null

examples:
	@set -e; for f in $(EXAMPLES); do \
	  echo "==> $$f"; $(call RUN_EXAMPLE,$$f); echo; \
	done

example:
	$(call RUN_EXAMPLE,examples/$(NAME).lisp)

# bin/la: the libarchive/cli system dumped as an executable. libarchive itself
# is opened when la first runs, not in the image, so the binary uses whatever
# libarchive the machine it runs on has.
LA_SOURCES := $(wildcard cli/*.lisp src/*.lisp) libarchive.asd

la: bin/la

bin/la: $(LA_SOURCES)
	@mkdir -p bin
	$(SBCL) $(SBCL_FLAGS) $(BOOT) --eval "(asdf:make :libarchive/cli)" $(QUIT)
	@ls -lh bin/la

# The man page and shell completions, from the command definitions.
docs: bin/la.1

bin/la.1: $(LA_SOURCES)
	@mkdir -p bin
	$(SBCL) $(SBCL_FLAGS) $(BOOT) --eval "(asdf:load-system :libarchive/cli)" \
	  --eval "(libarchive/cli::write-docs \"bin/\")" $(QUIT)

cli-test: bin/la
	$(SBCL) $(SBCL_FLAGS) $(BOOT) \
	  --eval "(asdf:test-system :libarchive/cli)" $(QUIT)
	ci/cli-smoke.sh bin/la

generate:
	$(PYTHON) -I tools/gen-ffi.py $(LIBARCHIVE_INCLUDE) src/

clean:
	rm -rf bin
	rm -rf $(HOME)/.cache/common-lisp/*/$(subst /,_,$(CURDIR))
	rm -rf $(HOME)/.cache/common-lisp/*$(CURDIR)

help:
	@grep -E '^#   ' Makefile | sed 's/^#   //'
