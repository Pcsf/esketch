# esketch --- build, test and audit
#
# Runtime needs Emacs 27.1+ with SVG support, and any browser.  bun and gh are
# only for generating test oracles and fetching the corpus, at home.

EMACS ?= emacs
BUN   ?= bun
BATCH  = $(EMACS) -Q --batch -L .
EL     = esketch-json.el esketch-model.el
BUILD  = build

.PHONY: all compile test test-el audit corpus test-corpus clean

all: compile test audit

compile:
	$(BATCH) --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile $(EL)

test: test-el

test-el: compile
	$(BATCH) -l test/esketch-test.el -f ert-run-tests-batch-and-exit

# Runtime files must not reach outside Emacs, nor use functions newer than
# Emacs 27.1.  Each scan also runs against a planted file and must hit it,
# so an empty result cannot come from a broken pattern.  browse-url is the one
# sanctioned exit, on an explicit command.
FORBIDDEN_CALLS = (call-process|process-file|start-process|make-process|shell-command|url-retrieve|open-network-stream|make-network-process)
EMACS28_FNS     = (string-search|string-replace|length[<>=]|ensure-list|string-pad|string-fill|string-chop-newline|file-name-concat|take |ntake |pos-bol|pos-eol|json-parse|json-serialize|json-insert|seq-keep|plistp|always |named-let|text-property-search)
audit: | $(BUILD)
	@printf '(call-process "x")\n(string-search "a" "b")\n' > $(BUILD)/planted.txt
	@test "$$(grep -cE '$(FORBIDDEN_CALLS)' $(BUILD)/planted.txt)" = 1 || { echo "audit: process pattern is broken"; exit 1; }
	@test "$$(grep -cE '\($(EMACS28_FNS)' $(BUILD)/planted.txt)" = 1 || { echo "audit: version pattern is broken"; exit 1; }
	@if grep -nE '$(FORBIDDEN_CALLS)' $(EL); then echo "audit: runtime reaches outside Emacs"; exit 1; fi
	@if grep -nE '\($(EMACS28_FNS)' $(EL); then echo "audit: runtime needs Emacs 28+"; exit 1; fi
	@if grep -nE "^\(require '" $(EL) | grep -vE "'(cl-lib|subr-x|esketch-json|esketch-model|browse-url)\)"; then \
	  echo "audit: unexpected require"; exit 1; fi
	@echo "audit: planted cases caught, runtime clean"

# Public .excalidraw files listed in test/corpus.txt (repo path blob-sha),
# fetched with gh.  They are third-party, so they live in build/ only.
corpus: | $(BUILD)
	mkdir -p $(BUILD)/corpus
	while read -r repo path sha; do \
	  out="$(BUILD)/corpus/$$sha.excalidraw"; \
	  test -s "$$out" || gh api "repos/$$repo/git/blobs/$$sha" --jq .content | base64 -d > "$$out"; \
	done < test/corpus.txt
	@echo "corpus: $$(ls $(BUILD)/corpus | wc -l) files"

# Each corpus file is saved by esketch unmodified and compared with what
# JavaScript's JSON.stringify(data, null, 2) writes, plus the source's final
# newline if it had one.
test-corpus: compile
	@test -n "$$(ls $(BUILD)/corpus 2>/dev/null)" || { echo "test-corpus: run make corpus first"; exit 1; }
	$(BUN) tools/canon-corpus.ts $(BUILD)/corpus $(BUILD)/corpus-js
	$(BATCH) -L test -l test/esketch-corpus.el -f esketch-corpus-run $(BUILD)/corpus $(BUILD)/corpus-js

$(BUILD):
	mkdir -p $(BUILD)

clean:
	rm -rf $(BUILD) *.elc test/*.elc
