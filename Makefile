# Build and test the libarchive binding.
#
#   make test       -- run the FiveAM suite
#   make check      -- test, then load everything and report the library version
#   make generate   -- regenerate the raw layer from the installed headers
#   make clean      -- drop this tree's SBCL fasl cache
#
# There is no binary to build: this is a library.

SBCL       ?= sbcl
SBCL_FLAGS := --noinform --non-interactive --no-userinit --no-sysinit
PYTHON     ?= python3

# The headers the raw layer is generated from. Homebrew's libarchive is keg-only.
LIBARCHIVE_INCLUDE ?= $(shell brew --prefix libarchive 2>/dev/null || echo /usr)/include

# Hermetic: this tree and its vendored ocicl/ dependencies, nothing inherited. If
# something is missing we want a loud failure, not a neighbour's copy.
BOOT := --eval "(require :asdf)" \
        --eval "(asdf:initialize-source-registry \`(:source-registry (:tree ,(truename \"./\")) :ignore-inherited-configuration))"

.PHONY: test check generate clean help
.DEFAULT_GOAL := test

test:
	$(SBCL) $(SBCL_FLAGS) $(BOOT) \
	  --eval "(asdf:test-system :libarchive)" --eval "(sb-ext:exit)"

check: test
	$(SBCL) $(SBCL_FLAGS) $(BOOT) \
	  --eval "(asdf:load-system :libarchive)" \
	  --eval "(format t \"~&~A loaded: ~D exported symbols~%\" \
	            (libarchive:version-string) \
	            (let ((n 0)) (do-external-symbols (s :libarchive) (declare (ignore s)) (incf n)) n))" \
	  --eval "(sb-ext:exit)"

generate:
	$(PYTHON) -I tools/gen-ffi.py $(LIBARCHIVE_INCLUDE) src/

clean:
	rm -rf $(HOME)/.cache/common-lisp/*/$(subst /,_,$(CURDIR))

help:
	@grep -E '^#   ' Makefile | sed 's/^#   //'
