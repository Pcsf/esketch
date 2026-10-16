# esketch --- build, test and audit
#
# Runtime needs Emacs 27.1+ with SVG support, and any browser.  bun and gh are
# only for generating test oracles and fetching the corpus, at home.

EMACS ?= emacs
BUN   ?= bun
BATCH  = $(EMACS) -Q --batch -L .
EL     = esketch-json.el esketch-model.el esketch-rough.el esketch-freehand.el esketch-fonts.el esketch-render.el esketch.el esketch-org.el
BUILD  = build

.PHONY: all compile test test-el test-render ref-basic test-render-corpus audit corpus test-corpus fonts page verify-page verify-firefox clean

all: compile test audit

compile:
	$(BATCH) --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile $(EL)

test: test-el test-render

test-el: compile
	$(BATCH) -L test -l test/esketch-test.el -l test/esketch-rough-test.el -l test/esketch-freehand-test.el -l test/esketch-render-test.el -l test/esketch-editor-test.el -l test/esketch-import-test.el -f ert-run-tests-batch-and-exit

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
	@if grep -nE "^\(require '" $(EL) | grep -vE "'(cl-lib|subr-x|filenotify|org|ol|esketch|esketch-json|esketch-model|esketch-rough|esketch-freehand|esketch-fonts|esketch-render|esketch-org|browse-url)\)"; then \
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

# esketch's SVG for the basic fixture against the one real Excalidraw
# exported from it (test/data/basic.ref.svg, made by make ref-basic).
test-render: compile | $(BUILD)
	$(BATCH) -l esketch-render --eval '(with-temp-file "$(BUILD)/basic.svg" (insert (esketch-render-svg (esketch-file-doc (esketch-read-file "test/data/basic.excalidraw")))))'
	$(BUN) tools/compare-svg.ts $(BUILD)/basic.svg test/data/basic.ref.svg
	$(BATCH) -l esketch-render --eval '(with-temp-file "$(BUILD)/made.svg" (insert (esketch-render-svg (esketch-file-doc (esketch-read-file "test/data/esketch-made.excalidraw")))))'
	$(BUN) tools/compare-svg.ts $(BUILD)/made.svg test/data/esketch-made.ref.svg

ref-basic:
	$(BUN) tools/excalidraw-ref.ts $(BUILD)/ref-basic test/data/basic.excalidraw test/data/esketch-made.excalidraw
	cp $(BUILD)/ref-basic/basic.svg test/data/basic.ref.svg
	cp $(BUILD)/ref-basic/esketch-made.svg test/data/esketch-made.ref.svg

# Every corpus file drawn by esketch and by real Excalidraw (@excalidraw/utils
# in headless Chromium); fails on any path that differs.
test-render-corpus: compile
	@test -n "$$(ls $(BUILD)/corpus 2>/dev/null)" || { echo "test-render-corpus: run make corpus first"; exit 1; }
	$(BUN) tools/excalidraw-ref.ts $(BUILD)/ref $(BUILD)/corpus/*.excalidraw
	rm -rf $(BUILD)/esk && mkdir -p $(BUILD)/esk
	$(BATCH) -l esketch-render --eval '(dolist (f (directory-files "$(BUILD)/corpus" t "excalidraw$$")) (with-temp-file (concat "$(BUILD)/esk/" (file-name-base f) ".svg") (insert (esketch-render-svg (esketch-file-doc (esketch-read-file f))))))'
	@bad=0; for f in $(BUILD)/ref/*.svg; do \
	  $(BUN) tools/compare-svg.ts $(BUILD)/esk/$$(basename $$f) $$f > $(BUILD)/cmp.txt || { bad=$$((bad+1)); echo "$$(basename $$f):"; head -3 $(BUILD)/cmp.txt; }; \
	done; echo "test-render-corpus: $$(ls $(BUILD)/ref | wc -l) files, $$bad differ"; test $$bad = 0

# Regenerates esketch-fonts.el and fonts/OFL.txt from Excalidraw's woff2
# files at the pinned commit.
EXCALIDRAW_REF = 4c37956b
fonts: | $(BUILD)
	mkdir -p $(BUILD)/fonts
	for p in $$(gh api "repos/excalidraw/excalidraw/git/trees/$(EXCALIDRAW_REF)?recursive=1" --jq '.tree[].path' \
	           | grep -E 'packages/excalidraw/fonts/(Excalifont|Virgil)/.*\.woff2$$'); do \
	  gh api "repos/excalidraw/excalidraw/contents/$$p?ref=$(EXCALIDRAW_REF)" --jq .content | base64 -d > $(BUILD)/fonts/$$(basename $$p); \
	done
	$(BUN) tools/gen-font.ts $(BUILD)/fonts

# Builds the offline browser editor page (Excalidraw 0.18.1 + fonts, one file).
page:
	cd tools && $(BUN) install --frozen-lockfile
	$(BUN) tools/build-page.ts

# Drives the page in headless Chromium with the network cut, then brings its
# export back through esketch and checks it is written unchanged.
verify-page: compile | $(BUILD)
	mkdir -p $(BUILD)/verify
	$(BATCH) -l esketch --eval '(esketch-page-write (esketch-file-doc (esketch-read-file "test/data/basic.excalidraw")) "basic" "$(BUILD)/verify/page.html")'
	$(BUN) tools/verify-page.ts
	$(BUN) tools/verify-input.ts
	$(BATCH) -l esketch --eval '(esketch-page-write (esketch-file-doc (esketch-read-file "test/data/esketch-made.excalidraw")) "esketch-made" "$(BUILD)/verify/page-made.html")'
	$(BUN) tools/verify-compat.ts $(BUILD)/verify/page-made.html test/data/esketch-made.excalidraw
	$(BATCH) -l esketch --eval '(esketch-write-file (esketch-read-file "$(BUILD)/verify/export.excalidraw") "$(BUILD)/verify/export-emacs.excalidraw")'
	cmp $(BUILD)/verify/export.excalidraw $(BUILD)/verify/export-emacs.excalidraw
	@echo "verify-page: page export round-trips through esketch byte for byte"

# The same page in Firefox, with its proxy pointed at a dead port so it has no
# network; the screenshot is the evidence.
verify-firefox: verify-page
	rm -rf "$(BUILD)/verify/ff-profile" && mkdir -p "$(BUILD)/verify/ff-profile"
	printf '%s\n' 'user_pref("network.proxy.type", 1);' 'user_pref("network.proxy.http", "127.0.0.1");' \
	  'user_pref("network.proxy.http_port", 9);' 'user_pref("network.proxy.ssl", "127.0.0.1");' \
	  'user_pref("network.proxy.ssl_port", 9);' 'user_pref("network.proxy.allow_hijacking_localhost", true);' \
	  'user_pref("browser.shell.checkDefaultBrowser", false);' > "$(BUILD)/verify/ff-profile/user.js"
	firefox --headless --no-remote --profile "$(BUILD)/verify/ff-profile" --window-size=1300,800 \
	  --screenshot "$(CURDIR)/$(BUILD)/verify/firefox.png" "file://$(CURDIR)/$(BUILD)/verify/page.html"
	@echo "verify-firefox: look at $(BUILD)/verify/firefox.png"
