---
phase: complete
progress: 37/37
task: "Excalidraw-style diagram editor for Emacs that runs under corporate IT restrictions"
slug: esketch
iteration: 1
started: 2026-10-16T00:00:00Z
updated: 2026-10-16T00:00:00Z
principal_stated_goal: "is it possible to replicate ms visio or excalidraw in a emacs pkg with no external dependencies. you could use html to help, but any solution has to survice the restrictive environment of a corporative IT an its restrictions! https://excalidraw.com/, https://www.microsoft.com/en-us/microsoft-365/visio -- yes, scope it as a new repo."
principal_stated_goal_source: prompt
principal_stated_goal_signal: 1
principal_stated_goal_locked: 2026-10-16T00:00:00Z
---

# esketch -- Excalidraw-style diagrams from Emacs

## Problem

At work, diagrams mean Visio (licensed, heavy, binary files that do not diff)
or excalidraw.com (a website that IT may block, and that cannot hold
confidential drawings anyway). Desktop installs, Node, Python and browser
extensions are usually blocked. Emacs and a browser are what is reliably there,
and neither currently gives a quick boxes-and-arrows sketch that lives as a
plain-text file next to the code or the Org notes it explains.

## Vision

`M-x esketch-open design.excalidraw` shows the drawing inside Emacs. Small edits
happen right there: add a box, retitle it, drag it, and the arrows stay attached.
One key opens the same drawing in a browser tab for full mouse sketching, and
one key brings the result back. The file is Excalidraw's own format, so the same
drawing opens on excalidraw.com at home and in esketch at work, and it diffs in
git like any text. It looks hand-drawn, as Excalidraw drawings do. Nothing was
installed except one Emacs package.

## Out of Scope (v1)

- Visio parity: stencil libraries, `.vsdx` import/export, orthogonal connector
  auto-routing, layers, master pages, data-linked shapes.
- Real-time collaboration, sharing links, cloud storage.
- Excalidraw libraries, frames, embeds, laser pointer and presentation mode.
- PNG export from Emacs itself (the browser page can save PNG; Emacs exports
  SVG).
- Terminal (`-nw`) editing. Under `-nw` the browser page is the editor.

## Principles

- One document model. Emacs and the browser read and write the same JSON, and
  a fixture set shared by both test suites keeps them agreeing.
- The file is the user's. Opening, viewing or exporting never rewrites it;
  only an explicit save does, and a save keeps every field it does not
  understand.
- Runtime touches nothing outside Emacs except `browse-url` on an explicit
  command.

## Constraints

- Emacs 27.1+ with SVG image support (`(image-type-available-p 'svg)` is `t`,
  confirmed on the target corporate machine 2026-10-16). Pure Emacs Lisp; no
  dynamic modules.
- The browser page is one `.html` file with its script, styles and fonts
  inlined, opened from `file://`. No CDN, no `fetch`, no local server, no
  listening port, no browser extension.
- A `file://` page cannot write to disk, so the page hands data back by
  clipboard copy or by a normal download; Emacs picks it up from either.
- Build and test tooling (bun, headless Chromium) runs at home only and is
  never required on the target machine.

## Goal

A package that opens, edits and saves Excalidraw-format drawings in Emacs, with
a self-contained offline browser editor for mouse-heavy work, whose files
round-trip through excalidraw.com without loss, and whose runtime needs nothing
but Emacs 27.1+ and a browser.

## Features

### F1 - Document model and file format
Why: the format is the contract with excalidraw.com, with git and with the
browser page; get it right once and both editors stay honest.

- [x] ISC-1: Reading and writing a `.excalidraw` file preserves every element
  and every field, including fields esketch does not interpret. Probe: ERT
  round-trips a fixture set exported from excalidraw.com; parsed JSON equal.
- [x] ISC-1.1: Saving an unmodified file reproduces it byte for byte when
  Excalidraw wrote it, and in every case writes exactly what Excalidraw's
  `JSON.stringify(data, null, 2)` would, so a save never adds diff noise.
  Probe: `make test-corpus` over the public corpus listed in
  `test/corpus.txt`, compared against bun's `JSON.stringify` output.
- [x] ISC-2: Drawings esketch writes load in Excalidraw with every element,
  binding and label intact, and Excalidraw draws them path for path as esketch
  does. Probe: test/data/esketch-made.excalidraw, made only with esketch's
  editor commands; `make verify-page` loads it in Excalidraw 0.18.1 and
  compares bindings after its load-time repair (a planted broken binding is
  caught); `make test-render` compares it with Excalidraw's export. Tested
  against the Excalidraw packages, not the excalidraw.com site.
- [x] ISC-3: Arrow bindings (`startBinding`, `endBinding`, `boundElements`)
  stay consistent after every edit operation: moving or deleting a bound shape
  moves or unbinds its arrows, and no edit leaves a broken or stale link.
  Probe: ERT property test over random edit sequences checks both after each
  step.
- [x] ISC-3.1: On real files, which often carry stale back-references and
  pre-2021 `boundElementIds`, every file reads with no broken link and random
  edits never add a broken or stale link. Probe: `make test-corpus` edit
  phase, 10 sequences of 10 edits per file.

### F2 - Rendering, hand-drawn and plain
Why: the drawing has to look like what was meant, in Emacs and in the browser
alike.

- [x] ISC-4: Emacs renders every supported element to SVG, in hand-drawn style
  (rough, seeded by each element's `seed`) and in a plain style. Probe: ERT
  golden SVG per element type and style.
- [x] ISC-5: The hand-drawn style is deterministic and the same in both
  renderers: `esketch-rough.el`, a port of roughjs 4.6.4 (the version
  Excalidraw pins), reproduces real roughjs path data for every case in
  `test/rough-cases.json`, and the page draws with that same roughjs. Probe:
  ERT against the table bun generates from the real library; numbers within
  1e-6.
- [x] ISC-5.1: Freehand strokes match Excalidraw: `esketch-freehand.el`, a
  port of perfect-freehand 1.2.0 with Excalidraw's stroke options and path
  rounding, reproduces the path data of the real library for every case in
  `test/freehand-cases.json`. Probe: ERT against the bun-generated table.
- [x] ISC-5.2: Each element type gets the roughjs options and shape call
  Excalidraw uses for it (roughness damping for small shapes, dash arrays,
  fill weight and gap, rounded corners as paths, curved and elbow arrows,
  arrowheads, freehand loop fills), after the same load-time defaults and
  point normalisation Excalidraw applies. Probe: `make test-render-corpus`
  draws every corpus file with esketch and with real Excalidraw
  (@excalidraw/utils 0.1.5 `exportToSvg` in headless Chromium) and compares
  every path; `make test-render` does the same offline for the basic fixture.
- [x] ISC-6: Text renders in the hand-drawn fonts Excalidraw uses (Excalifont,
  Virgil), shipped inside the package as glyph outlines so librsvg, which
  ignores embedded web fonts, draws them with nothing installed; OFL 1.1
  recorded in README and fonts/OFL.txt. Probe: corpus text widths from the
  shipped advances against the widths Excalidraw measured (`make
  test-corpus`, median under 1 px); librsvg render viewed. The page uses the
  same outlines (ISC-13).
- [x] ISC-7: Antecedent: A first-time viewer recognises an esketch drawing as
  "an Excalidraw sketch". Probe: side-by-side screenshots of the same fixture
  in excalidraw.com and in esketch (Emacs and page), viewed.

### F3 - Native Emacs editor
Why: small edits should not need a browser, and the drawing should live in the
buffer the user is already in.

- [x] ISC-8: In a GUI frame the user can create rectangle, ellipse, diamond,
  arrow and text, select by click, move by drag, resize, retitle, delete, and
  undo/redo every one of those. Probe: ERT drives the commands with synthetic
  mouse events and checks the model after each step.
- [x] ISC-8.1: The minimal editor: click selects (a label selects its shape),
  drag moves, arrows nudge 1 px and S-arrows 10 px, r/o/d add a rectangle,
  ellipse or diamond at the last click, RET sets a shape's label or a text,
  DEL deletes, u and U undo and redo. Probe: ERT editor suite with
  constructed mouse events. Still open in ISC-8: resizing, drawing arrows
  and text with the mouse.
- [x] ISC-9: An arrow drawn from one shape to another binds to both, and
  dragging either shape keeps it attached. Probe: ERT plus a viewed screenshot
  of a dragged pair.
- [x] ISC-10: README states the drag latency `make bench` measured at 10, 100
  and 500 elements. Probe: `make bench` output, README read.
- [x] ISC-10.1: README names the element count above which the browser page is
  the recommended editor, derived from the ISC-10 figures. Probe: README read.
- [x] ISC-11: Keyboard-only editing works too: select next/previous element,
  move by grid step, edit text, connect two selected shapes. Probe: ERT.
- [x] ISC-26: Right-clicking a shape opens a menu that sets its stroke colour,
  fill, stroke width, roughness and font size, and right-clicking the
  background opens a menu to add a shape there. Probe: ERT invokes each menu
  entry and checks the model.
- [x] ISC-27: Every gesture in README's gesture table has a passing ERT case.
  The table follows el-easydraw's conventions: arrows nudge 1 px and S-arrows
  10 px, `C-mouse-1` toggles selection, `S-drag` constrains to 45 deg steps or
  squares, `M-drag` duplicates, middle-drag pans, `C-wheel` zooms. Probe: ERT
  enumerates the table rows and runs one case per row.

### F4 - Offline browser editor
Why: freehand sketching and fast dragging need a real canvas; the page gives
that without installing anything.

- [x] ISC-12: `esketch-browse` (`b` in the editor) writes one self-contained
  `.html` -- Excalidraw 0.18.1, its CSS, its fonts but the CJK one, and the
  drawing -- and opens it with `browse-url`; the page's markup loads no
  script, stylesheet or import from anywhere, and the page itself makes no
  network request. Probe: ERT page test; `make verify-page` reads Chromium's
  net log and requires the page's only request to be a planted probe.
- [x] ISC-13: In a real browser the page is Excalidraw itself, offline: it
  loads the drawing, draws in Excalifont, and draws rectangles and freehand
  strokes, drags shapes, undoes, redoes and zooms. Probe: `make verify-page`
  (headless Chromium; drag with trusted DevTools-protocol mouse input);
  screenshot viewed.
- [x] ISC-14: The page's Send to Emacs button copies the drawing as JSON to
  the clipboard and saves it as NAME.excalidraw to the download directory;
  Excalidraw's own export saves PNG and SVG. Probe: `make verify-page` clicks
  the button with trusted input and reads the clipboard and the download.
- [x] ISC-15: The page works opened from `file://` with the network disabled,
  in Chromium and Firefox. Probe: `make verify-page` (name resolution off,
  net log checked) and `make verify-firefox` (proxy on a dead port),
  screenshots viewed.

### F5 - Round trip between page and Emacs
Why: the two editors are one tool only if a drawing moves between them without
thinking about it.

- [x] ISC-16: `esketch-import` (`i`) takes the drawing back from the
  clipboard or from the newest matching save in the download directory since
  the page opened, shows what changed, and replaces the drawing as one
  undoable step. Probe: ERT import tests.
- [x] ISC-17: While a page is open, Emacs watches the download directory with
  `file-notify` and takes each save in as it lands (undo reverts it); once
  the editor is closed, the save is written to the drawing file. Probe: ERT
  watch tests, 0.2 s from landing to editor.
- [x] ISC-18: A drawing edited in the page and brought into Emacs is written
  exactly as the page held it. Probe: `make verify-page` exports from the
  page, esketch reads and writes it, `cmp` finds the bytes equal.

### F6 - Diagrams embedded in Org documents
Why: a drawing should behave like a Lucidchart diagram embedded in Confluence.
It reads as a picture in the document, one click edits it where it sits, and
the document shows the result the moment you finish.

- [x] ISC-19: An Org link `[[esketch:path.excalidraw]]` displays inline as an
  image. Probe: ERT on an Org buffer; screenshot viewed.
- [x] ISC-23: One command, `esketch-org-insert`, creates a new drawing file
  under the customisable `esketch-directory`, inserts its link at point, and
  opens the editor on it. Probe: ERT checks file, link and editor state.
- [x] ISC-24: `C-c C-o` or a click on the inline image opens the native editor
  in place, as an overlay where the image was, with the surrounding text still
  visible. `C-c C-c` commits and shows the refreshed image, and `C-c C-k`
  discards the edit. Probe: ERT on an Org buffer for commit and discard;
  screenshot of an open editor viewed.
- [x] ISC-25: A drawing sent from the in-place editor to the browser page and
  saved there refreshes the inline image in the Org buffer within 2 s of the
  download landing, with no manual command. Probe: ERT with a temporary
  download directory, timed. Builds on the download watch of ISC-17.
- [x] ISC-20: `esketch-export-svg` writes a standalone SVG, text as glyph
  outlines so it needs no font anywhere, and Org HTML export embeds the
  drawing as inline SVG. Probe: ERT export and Org HTML tests; the same SVG
  is what `make test-render` compares with Excalidraw's export.

### F0 - Cross-cutting
Why: the whole point is surviving a locked-down machine and staying
maintainable.

- [x] ISC-21: All runtime files byte-compile with zero warnings. Probe:
  `make compile` with `byte-compile-error-on-warn`.
- [x] ISC-22: README.org lists every dependency (runtime and build), every
  keybinding of both editors, the measured limits and the font licence.
  Probe: Read README; ERT checks each command key appears.
- [x] ISC-A1: Anti: Runtime elisp calls no process, network or server function
  and nothing newer than Emacs 27.1. Probe: `make audit` with planted
  positives, and `make test-emacs27` (build and suite on Emacs 27.1).
- [x] ISC-A2: Anti: Opening, viewing, rendering, exporting or browsing a
  drawing never modifies the drawing file. Probe: ERT hashes fixtures before
  and after each of those commands.
- [x] ISC-A3: Anti: A save never drops an element or a field that was in the
  file when it was opened. Probe: covered by the ISC-1 round-trip plus an ERT
  case with unknown future fields.
- [x] ISC-A4: Anti: No Excalidraw code runs in Emacs: the Lisp side reads,
  draws and edits on its own, and ported algorithms (roughjs,
  perfect-freehand) keep their MIT notices. The browser page bundles
  Excalidraw 0.18.1 unmodified, with its MIT notice in the page. Probe: grep
  for the notices in the ported files and in assets/esketch-page.html.

## Decisions

- 2026-10-16 Scope is Excalidraw, not Visio. Visio's value is stencils,
  connector auto-routing and `.vsdx`; each is a project of its own and none
  survives the corporate constraints better than a sketch tool does.
- 2026-10-16 File format is Excalidraw's JSON, not a new s-expression format,
  so drawings move between work and excalidraw.com, and git diffs stay
  readable.
- 2026-10-16 Two editors over one model, as in evaporview: native SVG-in-buffer
  for viewing and small edits, offline HTML for mouse-heavy work. evaporview
  rejected SVG-in-buffer because it needs librsvg and fails under `-nw`; here
  SVG support was confirmed on the target machine, and `-nw` is out of scope.
- 2026-10-16 Prior art checked: el-easydraw (misohena) is a pure-elisp SVG
  editor for Org, with reported drag stutter on Emacs 30.2 (Codeberg
  ezemtsov/emacs#1); it uses its own SVG format, has no hand-drawn style and
  no Excalidraw compatibility. org-excalidraw needs an external converter on
  PATH. Neither meets the goal; building, pending the principal's confirmation.
- 2026-10-16 UX references chosen by the principal: org-excalidraw (one
  command creates the file and link, the link shows inline, saving in the
  editor refreshes Org within seconds) and el-easydraw (in-place overlay editor
  in the Org buffer, C-c C-c to commit, right-click menus, modifier gestures),
  both read like a Lucidchart diagram embedded in Confluence. Their UX goes
  into F3 and F6; their code is not used. org-excalidraw's dependencies
  (excalidraw_export on PATH, a Chrome PWA, chrome://flags) are what esketch
  exists to avoid.
- 2026-10-16 Licence GPL-3.0-or-later, as evaporview; a ported rough.js keeps
  its MIT notice, which GPL allows.
- 2026-10-16 Test oracle for the format: 43 of 44 public `.excalidraw` files
  (32 from excalidraw.com, 9 from the VS Code extension) equal
  `JSON.stringify(JSON.parse(raw), null, 2)`, two of them plus a final
  newline. The corpus is third-party, so only its list (repo, path, blob sha)
  is committed and `make corpus` fetches it at home.
- 2026-10-16 Own JSON reader and writer instead of json.el: json.el cannot
  tell null from {} under alist objects, and matching JSON.stringify byte for
  byte needs control of number and string formatting.
- 2026-10-16 Deleting an element removes it from every boundElements list
  that names it, stale ones included; first edit of a legacy element moves
  its `boundElementIds` into `boundElements`, as Excalidraw does on load.
- 2026-10-16 Rendering oracle: @excalidraw/utils 0.1.5 exportToSvg run in
  headless Chromium (bun bundle, `--allow-file-access-from-files`). Ports of
  roughjs and perfect-freehand were written by delegated agents against
  oracle tables from the real libraries, then rechecked here.
- 2026-10-16 Load-time defaults (Excalidraw's restore) are applied to a copy
  for drawing only; the saved file keeps what the user had.
- 2026-10-16 Fog "how faithfully to match Excalidraw's rough output" closed:
  ISC-5 and ISC-5.2 settled it at path-for-path identity with real Excalidraw.
- 2026-10-16 Text is drawn as glyph outlines (esketch-fonts.el, generated
  from Excalidraw's woff2 by tools/gen-font.ts), not as SVG text with an
  embedded font: librsvg uses only installed fonts, and installing fonts is
  what locked-down machines forbid. Fonts esketch does not ship (Helvetica,
  Cascadia, Nunito...) and characters missing from the outlines fall back to
  SVG text.
- 2026-10-16 The browser editor is Excalidraw itself (0.18.1, MIT), bundled with
  React and its fonts into one 8.8 MB offline page, instead of an editor
  written from scratch: a spike showed it runs from file:// with the network
  cut, and nothing written here would come near it. Its CDN font loads are
  redirected to fonts carried in the page. ISC-A4 was reworded from "no
  Excalidraw source in the package" to "no Excalidraw code in Emacs";
  ISC-12 to ISC-15 now describe that page.
- 2026-10-16 Learned: Excalidraw ignores synthetic pointer events for
  dragging existing shapes (drawing new ones works), so the drag and the Send
  button are checked with trusted input through the DevTools protocol.
- 2026-10-16 Learned: in batch Emacs, file-notify events are dispatched only
  while reading input (`read-event`), not by `accept-process-output`.
- 2026-10-16 Without SVG display (emacs -nw, or a build without librsvg) the
  drawing shows as a one-line note and `b` still opens the browser editor,
  instead of failing in create-image.
- 2026-10-16 Fog closed: freehand drawing stays in the browser editor, which
  is Excalidraw's own pen; the Emacs editor draws shapes, arrows and text.
- 2026-10-16 Fog closed: package layout is esketch-json (format),
  esketch-model (edits), esketch-rough / esketch-freehand / esketch-fonts
  (drawing primitives), esketch-render (SVG), esketch (editor) and
  esketch-org (Org).
- 2026-10-16 Fog closed: drawings live in their own .excalidraw files, never
  inside the Org text; Excalidraw JSON is too large to embed readably, and a
  separate file keeps it openable on excalidraw.com and diffable.
- 2026-10-16 F3 beyond the minimal editor was built by a delegated agent
  (multi-selection, resize, mouse-drawn arrows and text, Tab selection,
  context menus, gestures, bench) and rechecked here: suite, Emacs 27.1,
  three planted bugs, rendered selection viewed. Text resizes by font size;
  `0` resets a panned or zoomed view; moves apply on release, no live drag.
- 2026-10-16 Hand-off from page to Emacs is clipboard or download, never a
  localhost server: endpoint protection often flags listening sockets.

## Learning

- 2026-10-16 conjectured: a well-formed drawing has every link on both sides,
  so any one-sided link is an error. refuted by: 24 of 44 public files failed
  that check; 12 use the pre-2021 `boundElementIds` field, and the modern ones
  carry only back-side entries whose arrow is gone, which Excalidraw leaves
  behind. learned: Excalidraw relies on forward links being listed back and
  tolerates stale back entries. criterion now: ISC-3 and ISC-3.1 treat
  forward-without-back as an error and never let an edit add a stale entry,
  while reading legacy `boundElementIds`.

- 2026-10-16 conjectured: the grep audit of Emacs 28+ functions is enough to
  keep the runtime on Emacs 27.1. refuted by: the first run on a real 27.1
  (`make test-emacs27`) failed to load esketch-freehand.el, which used
  `(setf (plist-get ...))`, a place added in 28 that no name list catches.
  learned: a pattern audit only knows the failures already thought of; the
  real interpreter is the check. criterion now: ISC-A1 also requires the
  build and suite to pass on Emacs 27.1, and the audit gained the pattern.

## Verification

- ISC-4: corpus 44/44 files and basic fixture equal to Excalidraw's export;
  plain style by ERT; librsvg (Emacs's renderer) PNG of the fixture viewed.
- ISC-5: ERT rough suite, 206 sets, max deviation 2.8e-14; five planted
  bugs fail it.
- ISC-5.1: ERT freehand suite, max deviation 1.1e-13, 35 d strings exact;
  four planted bugs fail it.
- ISC-6: `make test-corpus` 725 labels, median 0.34 px, p90 2.04 px; ERT
  glyph and fallback tests.
- ISC-7: librsvg render beside Excalidraw's own font-embedded export, fixture
  and a 200-path diagram, viewed: indistinguishable.
- ISC-8.1, ISC-9: ERT editor suite 15/15; four planted bugs each fail it.
  Connector ends now clipped at ellipse and diamond outlines after a viewed
  render showed them stopping at the bounding box.
- ISC-19, ISC-23, ISC-24: ERT org cases (inline overlay, insert, commit,
  discard leaves the file hash unchanged); librsvg render of the editor's
  overlay image viewed. A screenshot of a live GUI frame was not taken: no
  off-screen display server here, and none was added to the live session.
- ISC-12 to ISC-15, ISC-18: `make verify-page` 13 checks plus the byte
  round trip, stable over four runs; page and Firefox screenshots viewed.
- ISC-16, ISC-17, ISC-25: ERT import tests; watch 0.2 s to the editor; the
  Org refresh test fails when its hook is removed.
- ISC-20: ERT export-svg and Org HTML export tests.
- ISC-2: verify-compat ok for 9 elements; broken binding planted and caught;
  esketch-made render 9/9 paths equal to Excalidraw's.
- ISC-8, ISC-11, ISC-26, ISC-27: test/esketch-gesture-test.el (52 tests
  with the editor suite); planted zoom, follower and constrain bugs each
  fail it; README gesture table checked row by row by a test.
- ISC-10, ISC-10.1: `make bench`; graphic drag step 16 ms at 10, 122 ms at
  100, 379 ms at 500 elements; README Limits names 100 elements.
- ISC-21, ISC-A1: `make all` (zero warnings, audit with planted cases) and
  `make test-emacs27` 243 passed, 2 skipped for no SVG in that image.
- ISC-22: README dependencies with pinned versions and proven-on list, key
  and gesture tables, Limits, licences; read.
- ISC-A2: test/esketch-integrity-test.el checks content and modification
  time; a planted save in esketch-browse fails it.
- ISC-A4: MIT notices for roughjs and perfect-freehand in the ported files
  (grep); no Excalidraw application code in the package.
- ISC-5.2: `make test-render-corpus` 44 files, 3513 paths, 0 differ; a
  planted 0.3 px change is caught.
- ISC-1, ISC-1.1: `make test-corpus` 44/44 match JSON.stringify, 43
  byte-identical; planted mismatch exits 1. ERT round-trip and json-cases
  (47 rows from bun).
- ISC-3: ERT `binding-invariant-property`; five planted model bugs each
  failed it or a targeted test.
- ISC-3.1: `make test-corpus` 0 files with errors, 440 sequences, 0 added a
  problem; red at 19 before the delete fix.
- ISC-A3: ERT `unknown-fields-survive-edits` + corpus round trip.

- 2026-10-16 conjectured: following shape.ts element by element reproduces
  Excalidraw's drawing. refuted by: only 34 of 44 corpus files matched, and
  10 failed or drifted. learned: Excalidraw draws the element as restore()
  leaves it on load (field defaults, strokeSharpness to roundness, line
  heights, arrowhead names, arrows and lines moved so the first point is the
  origin) and drops invisible ones, so restore is part of rendering.
  criterion now: ISC-5.2 is judged by a head-to-head against real Excalidraw
  on the corpus, not by reading its source.

## Test Strategy

`make all` = compile (warnings are errors) + ERT + audit; `bun test` for the
page's pure functions; `make verify` drives headless Chromium and Firefox with
real DOM events at home.

| isc | type | check | threshold | tool | anchors_to |
|-----|------|-------|-----------|------|------------|
| ISC-1 | round-trip | fixtures from excalidraw.com read and written | parsed JSON equal | ERT | F1 |
| ISC-1.1 | round-trip | unmodified save vs JSON.stringify(d,null,2) over public corpus | byte-identical, all files | make test-corpus | F1 |
| ISC-2 | interop | esketch-written file opened on excalidraw.com | loads, looks as drawn | real browser | F1 |
| ISC-3 | property | binding invariant after random edits | 0 violations in 1000 sequences | ERT | F1 |
| ISC-3.1 | property | random edits on every corpus file | 0 files with errors, 0 sequences adding a problem | make test-corpus | F1 |
| ISC-4 | golden | SVG per element type and style | matches golden | ERT | F2 |
| ISC-5 | parity | esketch-rough vs real roughjs 4.6.4, 138 cases | numbers within 1e-6 | ERT | F2 |
| ISC-5.1 | parity | esketch-freehand vs real perfect-freehand 1.2.0, 52 cases | outline within 1e-6, d exact | ERT | F2 |
| ISC-5.2 | parity | every corpus file drawn by esketch and by Excalidraw | 0 paths differ beyond 2-decimal rounding | make test-render-corpus | F2 |
| ISC-6 | measure | shipped-font text widths vs Excalidraw's measured widths, corpus | median under 1 px, p90 under 3 px | make test-corpus | F2 |
| ISC-7 | visual | side-by-side screenshots | recognised as Excalidraw style | viewed | F2 |
| ISC-8 | behaviour | synthetic mouse edits and undo | model correct each step | ERT | F3 |
| ISC-8.1 | behaviour | select, drag, nudge, add, label, delete, undo/redo | model correct each step | ERT | F3 |
| ISC-9 | behaviour | arrow follows dragged shape | stays bound | ERT + screenshot | F3 |
| ISC-10 | bench | drag latency at 10/100/500 elements | figures in README | make bench | F3 |
| ISC-10.1 | doc | recommended page threshold | stated, derived from ISC-10 | Read | F3 |
| ISC-11 | behaviour | keyboard-only edits | model correct | ERT | F3 |
| ISC-26 | behaviour | context menus set properties, add shapes | model correct per entry | ERT | F3 |
| ISC-27 | behaviour | README gesture table | one passing case per row | ERT | F3 |
| ISC-12 | scan | external references in page | none, planted caught | ERT | F4 |
| ISC-13 | e2e | page editing with real DOM events | all operations pass | make verify | F4 |
| ISC-14 | e2e | clipboard, download, PNG, SVG | files and clipboard read back | make verify | F4 |
| ISC-15 | e2e | file:// with network off, two engines | all pass | make verify | F4 |
| ISC-16 | behaviour | import from clipboard and downloads | one undo step, summary shown | ERT | F5 |
| ISC-17 | behaviour | file-notify offer | offered once per save | ERT | F5 |
| ISC-18 | round-trip | page export vs Emacs import | field-for-field equal | make verify + ERT | F5 |
| ISC-19 | behaviour | Org link shows inline image | displays | ERT + screenshot | F6 |
| ISC-23 | behaviour | one-command insert | file, link, editor open | ERT | F6 |
| ISC-24 | behaviour | in-place overlay edit, commit, discard | image refreshed or unchanged | ERT + screenshot | F6 |
| ISC-25 | timing | page save refreshes inline image | within 2 s of download | ERT | F6 |
| ISC-20 | render | standalone SVG in Emacs and browser | same look | ERT + make verify | F6 |
| ISC-21 | build | byte-compile | 0 warnings | make compile | F0 |
| ISC-22 | doc | README deps, keys, limits, licence | every command key present | Read + ERT | F0 |
| ISC-A1 | audit | process/network/new-function use | none, planted caught | make audit | F0 |
| ISC-A2 | integrity | fixture hash before/after commands | unchanged | ERT | F0 |
| ISC-A3 | round-trip | unknown fields survive save | preserved | ERT | F0 |
| ISC-A4 | licence | MIT notice on ported code | present | grep | F0 |

## Remaining Work

- [x] See it in a real GUI frame: the demo Org note opened in a Wayland Emacs
  frame rasterised both drawings (529x233, 465x263), and the principal
  confirmed the browser editor works from it (2026-10-16).
- [x] Draw images (with crop and flips), frame outlines, and the mask that
  cuts an arrow's line under its label -- the corpus image and 8 masks
  match Excalidraw's export when viewed side by side.
- [ ] Draw embeds, sticky notes and constant-width (laser geometry) freehand
  strokes in Emacs -- none occurs in the corpus; embeds and sticky notes are
  skipped, constant-width strokes are drawn variable-width. The browser
  editor (Excalidraw itself) draws all of them.
- [ ] Create the private GitHub remote `Pcsf/esketch` -- waits on the
  principal's go-ahead.
