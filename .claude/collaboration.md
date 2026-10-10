# Working with the maintainer

How the maintainer likes agentic work on mb-sound to go.  Imported from CLAUDE.md; personal, in-progress state (open questions, work status, idea backlogs) stays in the agent's local memory, not here.

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
- MVPs first, designed to grow cleanly.  Demo voices live in `bin/` as loadable scripts until a library project revisits them.
- Creative extensions are welcome: when building a feature, suggest (and within scope, demo) surprising musical uses, not only the literal request.

## Process notes

- Commits are step by step with detailed messages; preserve false starts in history (don't rewrite commit messages); `--no-ff` merges only when the maintainer says merge.  Never push.
- Merges that change only one `bin/` script (plus its spec) need only that script's specs before and after merging, not the full suite and smoke run.
- Compiling extensions in the shared main checkout is fine: macOS builds `.bundle` and Linux builds `.so` in separate `tmp/<platform>/` directories.
- Background agents get self-contained prompts (see the `agent-brief` skill), send the main session regular one-line progress updates (relayed to the maintainer as one-liners, so they can see what's running without asking), and run at most about three at once on the 7 GB container (check-mode suites and Valgrind are memory-heavy).
- After every merge, follow the `post-merge` skill (merge report, post-merge tests, "did you know" note).
- Keep notes local by default; don't post to GitHub unless asked.
