# Working with the maintainer

How the maintainer likes agentic work on mb-sound to go.  Imported from CLAUDE.md; personal, in-progress state (open questions, work status, idea backlogs) stays in the agent's local memory, not here.

## Fun is the point

mb-sound exists because making sound with code is fun: for the maintainer, for the people watching the videos and reading the code, and, as far as it applies, for the agents building it with them.  The rigor below (exact samples, measured numbers, memcheck, step-by-step questions) is there so the fun stands on solid ground, not as the goal itself.

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
- If the maintainer gives a standing instruction (e.g. "overnight, merge using best judgement"), merge branches whose tests pass, keep sound-changing defaults as built, and collect questions into one list for later; otherwise ask before merging.

## Honesty and evidence

- Give measured numbers, say what was and wasn't tested, and correct earlier explanations that turn out wrong.  Compute numbers with a quick script before quoting them, or label them estimates.
- Measure before explaining a failure.
- When a change alters the default sound, render an A/B for the maintainer to listen to (they listen on a Mac) and let them choose before committing the default.  Put good try-it snippets in the header comments of demo scripts in `bin/` so they persist.

## API taste (Ruby DSL)

- "More than one way": short methods plus long-name aliases (`n4`/`quarter`, `outro`/`fadeout`, `vis`/`visualize`, `at_bar`/`on_bar`); short, performance-friendly names for things played live, with full names alongside.
- Plain numbers over new global methods; musical time in bars/whole notes rather than seconds where it fits.  Console commands must be short and not collide with Pry commands.
- Generalize where possible without polluting the namespace (e.g. accent/slide as generic note marks usable in any seq, 303 specifics in one `.acid` transform).  Capitalized constants for markers (`Rest`, `Tie`; `_` means "discard" in Ruby).  Keep related APIs consistent (e.g. the diode ladder uses lp4's resonance scale).
- Prefer dedicated, reusable GraphNodes over arithmetic composed in DSL methods; things should resolve to GraphNodes, reusing code through inheritance or mixins.  `sig.filter(obj)` is supported but not the favorite: look for more poetic ways to attach effects.
- Avoid parsing strings; favor real Ruby syntax as much as possible (maintainer, 2026-10-10).  Part of the project's purpose is showing people and LLMs how powerful Ruby syntax and metaprogramming are for DSLs, so look for clever, outside-the-box uses of Ruby that make the end use more fun and easy: block builders with methods defined on the fly (so `did_you_mean` catches typos), operators, Ruby literals (ranges, symbols, Rationals) as values, objects that print themselves back as Ruby (`to_ruby`).  Text formats (YAML, JSON, binary) are for saving and loading only, never a mini-language people type.  The maintainer's ClassyHash gem (`deseretbook/classy_hash`, 10+ years old) shows the same taste: the schema is plain Ruby values (classes, Ranges, Regexps, Procs, Arrays as "one of", `[[...]]` for members, `:optional`), with no parser.
- Extending core and library classes: prepending and including modules (`Numeric.include(...)`, `GraphNode.prepend(...)`) is 100% fine; never reopen a class and directly redefine its methods (maintainer, 2026-10-10).  Refinements are an option where a change should stay local.
- MVPs first, designed to grow cleanly.  Demo voices live in `bin/` as loadable scripts until a library project revisits them.
- Creative extensions are welcome: when building a feature, suggest (and within scope, demo) surprising musical uses, not only the literal request.

## Process notes

- Commits are step by step with detailed messages; preserve false starts in history (don't rewrite commit messages); `--no-ff` merges only when the maintainer says merge.  Never push.
- Merges that change only one `bin/` script (plus its spec) need only that script's specs before and after merging, not the full suite and smoke run.
- Both machines' containers are x86_64-linux and build into the same `tmp/x86_64-linux/` and `lib/**/*.so` of a checkout (native macOS builds use `tmp/x86_64-darwin*/` and `.bundle`), so in any one checkout run only one `rake compile` at a time across both machines, and no suite or memcheck on one machine while the other compiles there.  Separate worktrees have their own `tmp/` and `lib/` builds, so they don't collide, and could hold machine-specific builds (e.g. `-march=native`) if that's ever wanted (maintainer note, 2026-10-11).
- Background agents get self-contained prompts (see the `agent-brief` skill), send the main session regular one-line progress updates (relayed to the maintainer as one-liners, so they can see what's running without asking), and run at most about three at once on the 7 GB container (check-mode suites and Valgrind are memory-heavy).
- After every merge, follow the `post-merge` skill (merge report, post-merge tests, "did you know" note).
- Keep notes local by default; don't post to GitHub unless asked.
