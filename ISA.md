---
phase: marking
progress: 0/27
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

- [ ] ISC-1: Reading and writing a `.excalidraw` file preserves every element
  and every field, including fields esketch does not interpret. Probe: ERT
  round-trips a fixture set exported from excalidraw.com; parsed JSON equal.
- [ ] ISC-2: Elements esketch writes (rectangle, ellipse, diamond, line, arrow,
  text, freedraw) load in excalidraw.com and look as drawn in esketch. Probe:
  fixture written by esketch, opened on excalidraw.com in a real browser at
  home, screenshot compared.
- [ ] ISC-3: Arrow bindings (`startBinding`, `endBinding`, `boundElements`)
  stay consistent after every edit operation: moving or deleting a bound shape
  moves or unbinds its arrows. Probe: ERT property test over random edit
  sequences checks the binding invariant after each step.

### F2 - Rendering, hand-drawn and plain
Why: the drawing has to look like what was meant, in Emacs and in the browser
alike.

- [ ] ISC-4: Emacs renders every supported element to SVG, in hand-drawn style
  (rough, seeded by each element's `seed`) and in a plain style. Probe: ERT
  golden SVG per element type and style.
- [ ] ISC-5: The hand-drawn style is deterministic and the same in both
  renderers: for the same element and seed, Emacs and the browser produce the
  same path geometry. Probe: shared fixture table run by ERT and by `bun test`;
  paths compared numerically.
- [ ] ISC-6: Text renders in a hand-drawn font that ships inside the package
  and the page, with an OFL or compatible licence recorded in README. Probe:
  page scanned for external font URLs (none); README licence line read.
- [ ] ISC-7: Antecedent: A first-time viewer recognises an esketch drawing as
  "an Excalidraw sketch". Probe: side-by-side screenshots of the same fixture
  in excalidraw.com and in esketch (Emacs and page), viewed.

### F3 - Native Emacs editor
Why: small edits should not need a browser, and the drawing should live in the
buffer the user is already in.

- [ ] ISC-8: In a GUI frame the user can create rectangle, ellipse, diamond,
  arrow and text, select by click, move by drag, resize, retitle, delete, and
  undo/redo every one of those. Probe: ERT drives the commands with synthetic
  mouse events and checks the model after each step.
- [ ] ISC-9: An arrow drawn from one shape to another binds to both, and
  dragging either shape keeps it attached. Probe: ERT plus a viewed screenshot
  of a dragged pair.
- [ ] ISC-10: README states the drag latency `make bench` measured at 10, 100
  and 500 elements. Probe: `make bench` output, README read.
- [ ] ISC-10.1: README names the element count above which the browser page is
  the recommended editor, derived from the ISC-10 figures. Probe: README read.
- [ ] ISC-11: Keyboard-only editing works too: select next/previous element,
  move by grid step, edit text, connect two selected shapes. Probe: ERT.

### F4 - Offline browser editor
Why: freehand sketching and fast dragging need a real canvas; the page gives
that without installing anything.

- [ ] ISC-12: `esketch-browse` writes one self-contained `.html` holding the
  drawing and opens it with `browse-url`. Probe: ERT scan of the generated
  page finds no `src=`/`href=` to a URL, no `@import`, no `fetch`, no
  `XMLHttpRequest`, no `WebSocket`, with a planted-positive page caught.
- [ ] ISC-13: In a real browser the page draws every supported element type,
  selects, moves, resizes, binds arrows, draws freehand, undoes and redoes,
  pans and zooms. Probe: headless Chromium run with real DOM events
  (`make verify`) plus a screenshot viewed.
- [ ] ISC-14: The page copies the drawing as JSON to the clipboard and also
  offers it as a `.excalidraw` download; it can also save PNG and SVG. Probe:
  `make verify` reads the clipboard and the downloaded files.
- [ ] ISC-15: The page works opened from `file://` with the network disabled,
  in Chromium-based browsers and Firefox. Probe: `make verify` with network
  off on both engines.

### F5 - Round trip between page and Emacs
Why: the two editors are one tool only if a drawing moves between them without
thinking about it.

- [ ] ISC-16: `esketch-import` takes the drawing back from the clipboard or
  from the newest matching file in the download directory, shows a summary of
  what changed, and replaces the buffer's drawing as one undoable step.
  Probe: ERT with clipboard and download-directory fixtures.
- [ ] ISC-17: Optionally, Emacs watches the download directory with
  `file-notify` and offers the import when the page saves. Probe: ERT with a
  temporary directory.
- [ ] ISC-18: A drawing edited in the page and imported equals, field for
  field, what the page holds (no loss through the hand-off). Probe: `make
  verify` exports, ERT imports, both serialisations compared.

### F6 - Org integration and export
Why: most drawings exist to explain something written next to them.

- [ ] ISC-19: An Org link `[[esketch:path.excalidraw]]` displays inline as an
  image and opens the editor on `C-c C-o`. Probe: ERT on an Org buffer;
  screenshot viewed.
- [ ] ISC-20: `esketch-export-svg` writes a standalone SVG (fonts embedded)
  that renders the same in Emacs and in a browser, and Org HTML export embeds
  it. Probe: ERT plus `make verify` screenshot.

### F0 - Cross-cutting
Why: the whole point is surviving a locked-down machine and staying
maintainable.

- [ ] ISC-21: All runtime files byte-compile with zero warnings. Probe:
  `make compile` with `byte-compile-error-on-warn`.
- [ ] ISC-22: README.org lists every dependency (runtime and build), every
  keybinding of both editors, the measured limits and the font licence.
  Probe: Read README; ERT checks each command key appears.
- [ ] ISC-A1: Anti: Runtime elisp calls no process, network or server function
  and no function newer than Emacs 27.1. Probe: `make audit` with planted
  positives.
- [ ] ISC-A2: Anti: Opening, viewing, rendering, exporting or browsing a
  drawing never modifies the drawing file. Probe: ERT hashes fixtures before
  and after each of those commands.
- [ ] ISC-A3: Anti: A save never drops an element or a field that was in the
  file when it was opened. Probe: covered by the ISC-1 round-trip plus an ERT
  case with unknown future fields.
- [ ] ISC-A4: Anti: No Excalidraw application source is vendored into the
  package; any ported algorithm (rough.js) carries its MIT notice. Probe:
  `grep` for the notice in the ported file; licence section of README read.

## Not yet specified

- fog: Freehand drawing in the native Emacs editor -- whether mouse-movement
  event rate under `track-mouse` is enough for a usable pen.
- fog: How faithfully to match Excalidraw's own rough output. Same algorithm
  and seed gives "the same style"; byte-identical to excalidraw.com would need
  their exact rough.js version and options, which may not be worth it.
- fog: Emacs Lisp package layout and file split; decided at the first build
  slice, as in ewavedrom and evaporview.
- fog: Package licence (sibling repos differ).

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
- 2026-10-16 Hand-off from page to Emacs is clipboard or download, never a
  localhost server: endpoint protection often flags listening sockets.

## Test Strategy

`make all` = compile (warnings are errors) + ERT + audit; `bun test` for the
page's pure functions; `make verify` drives headless Chromium and Firefox with
real DOM events at home.

| isc | type | check | threshold | tool | anchors_to |
|-----|------|-------|-----------|------|------------|
| ISC-1 | round-trip | fixtures from excalidraw.com read and written | parsed JSON equal | ERT | F1 |
| ISC-2 | interop | esketch-written file opened on excalidraw.com | loads, looks as drawn | real browser | F1 |
| ISC-3 | property | binding invariant after random edits | 0 violations in 1000 sequences | ERT | F1 |
| ISC-4 | golden | SVG per element type and style | matches golden | ERT | F2 |
| ISC-5 | parity | rough paths Emacs vs browser | equal within 1e-6 | ERT + bun test | F2 |
| ISC-6 | scan | external font URLs in page | none | ERT | F2 |
| ISC-7 | visual | side-by-side screenshots | recognised as Excalidraw style | viewed | F2 |
| ISC-8 | behaviour | synthetic mouse edits and undo | model correct each step | ERT | F3 |
| ISC-9 | behaviour | arrow follows dragged shape | stays bound | ERT + screenshot | F3 |
| ISC-10 | bench | drag latency at 10/100/500 elements | figures in README | make bench | F3 |
| ISC-10.1 | doc | recommended page threshold | stated, derived from ISC-10 | Read | F3 |
| ISC-11 | behaviour | keyboard-only edits | model correct | ERT | F3 |
| ISC-12 | scan | external references in page | none, planted caught | ERT | F4 |
| ISC-13 | e2e | page editing with real DOM events | all operations pass | make verify | F4 |
| ISC-14 | e2e | clipboard, download, PNG, SVG | files and clipboard read back | make verify | F4 |
| ISC-15 | e2e | file:// with network off, two engines | all pass | make verify | F4 |
| ISC-16 | behaviour | import from clipboard and downloads | one undo step, summary shown | ERT | F5 |
| ISC-17 | behaviour | file-notify offer | offered once per save | ERT | F5 |
| ISC-18 | round-trip | page export vs Emacs import | field-for-field equal | make verify + ERT | F5 |
| ISC-19 | behaviour | Org link inline image and C-c C-o | displays, opens | ERT + screenshot | F6 |
| ISC-20 | render | standalone SVG in Emacs and browser | same look | ERT + make verify | F6 |
| ISC-21 | build | byte-compile | 0 warnings | make compile | F0 |
| ISC-22 | doc | README deps, keys, limits, licence | every command key present | Read + ERT | F0 |
| ISC-A1 | audit | process/network/new-function use | none, planted caught | make audit | F0 |
| ISC-A2 | integrity | fixture hash before/after commands | unchanged | ERT | F0 |
| ISC-A3 | round-trip | unknown fields survive save | preserved | ERT | F0 |
| ISC-A4 | licence | MIT notice on ported code | present | grep | F0 |

## Remaining Work

- [ ] Create the private GitHub remote `Pcsf/esketch` -- waits on the
  principal's go-ahead.
