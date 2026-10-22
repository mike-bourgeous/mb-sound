# Working with the maintainer

How the maintainer likes agentic work on mb-sound to go.  Imported from CLAUDE.md; personal, in-progress state (open questions, work status, idea backlogs) stays in the agent's local memory, not here.

## Fun is the point

mb-sound exists because making sound with code is fun: for the maintainer, for the people watching the videos and reading the code, and, as far as it applies, for the agents building it with them.  The rigor below (reproducible renders, measured numbers, memcheck, step-by-step questions) is there so the fun stands on solid ground, not as the goal itself.

- Follow good tangents.  When an idea opens up ("what if the editor rewrote the Ruby literal?"), explore it with the maintainer, write it down, and come back to the queue; a design conversation that changes direction several times is often the best part of the day.
- Make things that are delightful to play and to read: surprising musical uses, demos worth listening to, DSL code that shows off what Ruby can do.
- Bring curiosity and enthusiasm to the work, honestly; never at the cost of the honesty and evidence rules below.
- When a choice is close, prefer the one that makes the library more fun to perform with, teach with, or extend.

## Decisions and questions

- "Note for later" / "record these as notes" means write it down (local memory idea notes) and do NOT implement until the maintainer explicitly says go.  Short messages are normal ("Merge ✅", "🚀" = go ahead); confirm what was recorded and ask only the open decision.
- Messages that arrive mid-turn add requirements: fold them into the current change and say so, rather than stopping.
- When asked to brainstorm, give options with pros/cons and a recommendation, then wait.
- Questions are numbered and short so they can be answered tersely ("1. agreed 2. :bar").  When several pile up, present them in bursts of four, highest impact first, preferring questions that don't wait on listening.  The mobile app scrolls away long lists, so never send one huge list.
- Report one step at a time: a step is one mergeable branch or one set of questions.  When other background work finishes while questions are open, give it a one-line note and hold its summary until the current questions are answered or deferred.
- Questions about things used heavily in composition or live performance may stay open until the project that solves them; re-raise still-open questions at merge reports and backlog check-ins instead of letting them scroll away.
- Every 2-3 features, offer a backlog checkpoint: group ideas, point out dependencies and clusters, suggest what's next.
- Decisions in conversation, merges on tests (maintainer, 2026-10-18): each branch is classed when briefed.  Execution branches (fixes, answers already given, follow-ups, test infrastructure) merge on a runner pass with a short note after.  Design branches (new concepts, APIs, names, defaults) get the design conversation first (proposal, brainstorm, options); the brief records what was agreed, and they too merge on a runner pass when the agent's final report lists no design deltas (new names, changed defaults, changed sound, removed APIs, saved-format changes, surprises).  Any delta, any sound change, and any change to saved formats (graph documents, takes, presets) waits for the maintainer.  Cheap-to-reverse open questions don't block a merge (no legacy compat makes most choices reversible): they merge as built and go into the design queue, raised in batches at natural pauses as design conversations.  Architectural findings (a class of bug, a surprising mechanism, an out-of-the-box idea) go to the design queue too, and to the maintainer at once if they change direction.  This works with the systematize-lessons practice: every final report's lessons table (lesson -> mechanism -> bug class -> adopted/proposed) and the coordinator's cross-branch pattern synthesis feed the design queue and its architectural reviews.
- If the maintainer gives a standing instruction (e.g. "overnight, merge using best judgement"), merge branches whose tests pass, keep sound-changing defaults as built, and collect questions into one list for later; otherwise ask before merging.

## Honesty and evidence

- Give measured numbers, say what was and wasn't tested, and correct earlier explanations that turn out wrong.  Compute numbers with a quick script before quoting them, or label them estimates.
- Measure before explaining a failure.
- When a change alters the default sound, render an A/B for the maintainer to listen to (they listen on a Mac) and let them choose before committing the default.  Put good try-it snippets in the header comments of demo scripts in `bin/` so they persist.

## Ears win: exactness and sound guards (maintainer, 2026-10-22)

The zoom-out's guard rule: "Ears win."  Sound decides; exactness is kept where it can be heard or a workflow needs it.

- Reproduce what was heard: seeds, takes, and variants render identically on the same settings (same code, same buffer size).  That stays a requirement.
- Buffer sizes: "within -80db if possible. Just not obsessed over and never part of persona concerns."  Bit-identical output at every buffer size is no longer a default requirement; briefs ask for it only where a workflow depends on it (take replays, stems that must sum to the mix).  Existing invariance stays unless a change has a reason to give it up, and the report says so.
- C kernels: new kernels get a Ruby reference that specs compare within a stated tolerance (e.g. -120 dB, or a relative error); a bit-exact mirror is an option where it's cheap, not the rule.  Existing exact mirrors and their specs stay.
- Integer frame counters on hot paths; Rationals for musical positions.
- Sound guards: changes that touch DSP (nodes, kernels, filters, oscillators, envelopes, effects, mastering), presets, or the plan layer run the golden set (`bundle exec rake golden:check`, `design/notes/sound_guards.md`) before merging.  A failing piece is not re-approved by the agent: its Bench set (approved vs new, written by the check) goes to the maintainer, and `rake golden:approve[name] RUN=dir` follows his verdict.  A change meant to alter sound names the pieces it moves in its report.

## API taste (Ruby DSL)

- "More than one way": short methods plus long-name aliases (`n4`/`quarter`, `outro`/`fadeout`, `vis`/`visualize`, `at_bar`/`on_bar`); short, performance-friendly names for things played live, with full names alongside.
- Plain numbers over new global methods; musical time in bars/whole notes rather than seconds where it fits.  Console commands must be short and not collide with Pry commands.
- Generalize where possible without polluting the namespace (e.g. accent/slide as generic note marks usable in any seq, 303 specifics in one `.acid` transform).  Capitalized constants for markers (`Rest`, `Tie`; `_` means "discard" in Ruby).  Keep related APIs consistent (e.g. the diode ladder uses lp4's resonance scale).
- Prefer dedicated, reusable GraphNodes over arithmetic composed in DSL methods; things should resolve to GraphNodes, reusing code through inheritance or mixins.  `sig.filter(obj)` is supported but not the favorite: look for more poetic ways to attach effects.
- Avoid parsing strings; favor real Ruby syntax as much as possible (maintainer, 2026-10-10).  Part of the project's purpose is showing people and LLMs how powerful Ruby syntax and metaprogramming are for DSLs, so look for clever, outside-the-box uses of Ruby that make the end use more fun and easy: block builders with methods defined on the fly (so `did_you_mean` catches typos), operators, Ruby literals (ranges, symbols, Rationals) as values, objects that print themselves back as Ruby (`to_ruby`).  Text formats (YAML, JSON, binary) are for saving and loading only, never a mini-language people type.  The maintainer's ClassyHash gem (`deseretbook/classy_hash`, 10+ years old) shows the same taste: the schema is plain Ruby values (classes, Ranges, Regexps, Procs, Arrays as "one of", `[[...]]` for members, `:optional`), with no parser.
- Extending core and library classes: prepending and including modules (`Numeric.include(...)`, `GraphNode.prepend(...)`) is 100% fine; never reopen a class and directly redefine its methods (maintainer, 2026-10-10).  Refinements are an option where a change should stay local.
- Operators on nodes are signal arithmetic (`440.hz * 2` doubles the amplitude); frequency and pitch changes go through method chaining (`transpose`, `.hz`), and values change meaning only when type-tagged (Pitch/Interval/Decibels; a node that outputs a frequency is a different case) (maintainer, 2026-10-13).
- Internal readers must not shadow DSL method names; prefer instance variables internally, and a generic parameter API over ad hoc readers (maintainer, 2026-10-13).
- Prefer explicit state and transitions over implicit state and control flow, where it fits (maintainer, 2026-10-17): when behavior depends on what came before (input modes and pending prefix keys, note-off/hold tracking, players starting/ringing/sleeping, scheduler and capture lifecycles, document loading), model it as named states with a declared transition table rather than instance-variable flags read by if/else chains.  The table can be printed (help, `?` overlays), checked by specs that cover every (state, event) pair plus random walks with invariants, and extended without hidden interactions.  Small, obviously linear code stays plain.
- MVPs first, designed to grow cleanly.  Demo voices live in `bin/` as loadable scripts until a library project revisits them.
- Creative extensions are welcome: when building a feature, suggest (and within scope, demo) surprising musical uses, not only the literal request.

## Process notes

- Commits are step by step with detailed messages; preserve false starts in history (don't rewrite commit messages); `--no-ff` merges only when the maintainer says merge.  Never push.
- Merges that change only one `bin/` script (plus its spec) need only that script's specs before and after merging, not the full suite and smoke run.
- Both machines' containers are x86_64-linux and build into the same `tmp/x86_64-linux/` and `lib/**/*.so` of a checkout (native macOS builds use `tmp/x86_64-darwin*/` and `.bundle`), so in any one checkout run only one `rake compile` at a time across both machines, and no suite or memcheck on one machine while the other compiles there.  Separate worktrees have their own `tmp/` and `lib/` builds, so they don't collide, and could hold machine-specific builds (e.g. `-march=native`) if that's ever wanted (maintainer note, 2026-10-11).
- Background agents get self-contained prompts (see the `agent-brief` skill), send the main session regular one-line progress updates (relayed to the maintainer as one-liners, so they can see what's running without asking), and run at most about three at once on the 7 GB container (check-mode suites and Valgrind are memory-heavy).
- After every merge, follow the `post-merge` skill (merge report, post-merge tests, "did you know" note).
- Keep notes local by default; don't post to GitHub unless asked.
- Zero warnings: the suite fails on any Ruby warning (spec/support/warning_guard.rb).  Fix the cause; a warning a spec triggers on purpose is asserted with an output matcher, never silenced or allowlisted; the allowlist is only for gems we don't control, each with its reason (maintainer, 2026-10-14).
- Flakes get fixes: never hide a flaky spec with reruns.  The flake goes into a fix round (or onto a watch list with its failure text kept, if it can't be reproduced) (maintainer, 2026-10-11).  No reruns at all (maintainer, 2026-10-15): every failure is investigated right away, load-sensitive examples included, instead of rerunning to see whether it passes.
- Installing packages or changing system configuration on either machine needs the maintainer's own OK, not a peer session's or an agent's (2026-10-12).
- Songs on the Listening Bench include per-track stems (`render(..., stems:)`), so each part can be heard alone (maintainer, 2026-10-12).
