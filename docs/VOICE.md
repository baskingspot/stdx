# The voice of the stdx docs

This file says how the public-facing docs of stdx sound and why. It covers the README, the guide
(`docs/content/_index.md`), its examples, and the `//!` and `///` comments in `src/`. The mechanics
(layout, build, example rules) are in the "Documentation" section of `AGENTS.md`. Read this file
before you write or review any of them.

## Who reads this

An adopter who knows Zig and is deciding whether to use stdx. A second reader is the same person
later, debugging at the end of a long day. Neither reads for pleasure. Both want the answer, the
reason once, and the edge that will bite them.

Two surfaces, one job each:

- The API docs (`//!`, `///`) state the contract. What a symbol does, its invariants, its failure
  modes.
- The guide says which piece to pick and how the pieces combine. It is organized by task, not by
  module.

## The voice

Plain, specific, and dense. Every sentence carries something concrete: a symbol, a number, an error
name, a constraint, a command. Lead with what the thing is and what sets it apart, in the words an
adopter would search for. State the strength as a fact. Do not call anything powerful, seamless, or
robust.

Test each sentence:

1. Does it carry something concrete?
2. Could it appear in any library's docs? If yes, cut it or replace it with the specific fact.
3. Would the reader miss it if you deleted it?

### Slop to remove

- Throat-clearing and recap: "it is important to note", a closing paragraph that restates the
  chapter.
- Inflated words: "powerful", "seamless", "robust", "comprehensive", "leverage" as a verb.
- Hedging when the code is deterministic: "typically", "in most cases". State the condition.
- Templates: "not X, but Y" as a pose, a three-item list built for rhythm, a bold lead-in on every
  bullet.
- Padded structure: a heading over one sentence, a table with two rows.
- A doc that restates the signature.
- Claims with no handle: "fast", "efficient", "safe". Give the number or the mechanism, or cut it.

### Do not over-correct

The module docs have a real voice: dense, specific, with em dashes and long sentences where the
content needs them. That is not slop. Do not flatten a precise sentence into a vague one. Do not ban
a punctuation mark. Slop is content that says nothing, not a style.

### Two registers

- The guide is formal technical text. Write short active sentences. No contractions. No `should`,
  `may`, `might`, `could`, or `would`. No semicolons. Descriptive sentences stay under 25 words and
  procedural ones under 20. Code, identifiers, and quoted errors are exempt.
- Doc comments in `src/` keep the repo voice. The ASD-STE rules do not apply to them.

## One tagline

The same sentence appears in five places. Change all five together.

> Extensions to the Zig 0.16 standard library: fixed-capacity containers, strict parsers, IPv4
> types, and the primitives std lacks.

- `README.md`, under the logo
- the first sentence of `docs/content/_index.md`
- the first lines of `src/root.zig`
- `description` in `docs/config.toml`
- the GitHub About (`gh repo edit mattrobenolt/stdx --description "..."`)

The README is the condensed version of the guide's opening. It has the same tagline, the same
origin paragraph, and the same list of what is inside. It adds install steps and links out to the
site. Keep the two lists in step: one bullet per guide chapter, using that chapter's own wording.
When a chapter is added, split, or renamed, update both lists. They went stale once already, after
strict parsing became three chapters.

## Facts

- Every claim is true on this toolchain. Read the pinned std source before you write what std does
  or lacks. Run a scratch test before you state behavior you only read. Reading missed two bugs:
  `set.unite` never returned `true`, and `static_map` could not find narrow keys.
- stdx builds with Zig 0.16 only. Never write "or newer". `.minimum_zig_version` in
  `build.zig.zon` is a Zig field name and means nothing more.
- Never name a downstream project. Examples are generic programs that show how stdx is used.
- Do not state status or recency in mechanism docs: no "now", "currently", "recently". Readiness
  belongs in an issue, not in prose.
- A doc comment explains why, not what. No walkthroughs. No review or PR references. A short brief
  of what the thing is and what it promises belongs on a type or module.
- A claim about another module needs its own check. A doc written for one type and pasted onto its
  neighbor is the most common wrong doc here.

## Structure decisions

- The guide is one page, like the Zig language reference. Cmd+F is the search. Split it only when a
  single page stops being searchable.
- Chapters are by task (`# Strict parsing`, `# Timekeeping`). Sections are `##`. A heading's slug
  is its anchor, so renaming a heading breaks links to it, including the ones in the README and in
  the API docs.
- The Modules table lists exactly the exports of `src/root.zig`. Each row agrees with that module's
  `//!`.
- Every code block in the guide is a real file in `docs/examples/`, compiled by `just test`. Never
  paste a block that the compiler has not seen. The two install snippets are the exception.
- Examples follow one style. A file that uses one stdx module writes
  `const buffer = @import("stdx").buffer;`. A file that uses several writes
  `const stdx = @import("stdx");` first. Bind the module at the top and never spell it out inline.
  Use decl literals and inferred types. Use `.parseComptime("...")` for address and prefix literals.
  The `x` suffix (`timex`, `fmtx`) appears only where std has a namesake in scope.
- Fences are `zig` or `sh`. The highlighter has no `zon` grammar, so `.zon` snippets are `zig`.
- No third-party scripts on the site. No search index. The GitHub link is a plain link with the
  mark inlined.
- The logo is two plain SVGs in a `<picture>`: one for light pages and one for dark. A single file
  with a color-scheme rule follows the OS, not the GitHub theme, and fails there.

## Tools

- `just guide` serves the guide and the API reference with live reload.
- `just doc` builds the whole site into `zig-out/site/`.
- `just fmt` formats the Zig, the guide, the README, and the CSS. The Tera templates in
  `docs/templates` are not HTML, so the formatter skips them.
- `just svgo` squeezes the SVGs. A rerun changes nothing.
- The `docs-librarian` agent (`.pi/agents/docs-librarian.md`) is the second reader. It audits by
  reading only. It never compiles or runs code. A claim that reading cannot settle goes under
  "unverified" with the exact check, and the parent runs it. Verify every finding before you apply
  it, because it sometimes proposes a wrong rewrite or flags a correct claim.

## Not yet mechanized

These checks run by hand or through the librarian. Each would make a small `just` recipe.

- The Modules table against the exports of `src/root.zig`.
- Every `/api/#stdx.<name>` link against those exports.
- Every file in `docs/examples/` against the guide and `docs/examples/root.zig`.
- The README's list against the guide's opening list.
