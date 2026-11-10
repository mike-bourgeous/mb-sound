# Releases and installing (the gem without a checkout)

<!-- summary -->
`rake release:local DIR=...` (`release/local_release.rb`) builds .gem files for mb-sound, mb-term, the git-pinned mb-math and mb-util, and the locked registry gems into DIR/gems, then installs them with `gem install --local` into a fresh DIR/gem_home outside any bundle; `rake release:smoke DIR=...` (`release/clean_room_smoke.rb`) runs mb-sound there as a musician would.
An installed gem has no checkout: code that writes files uses `Internal.user_data_dir`/`scratch_dir`, code that needs the checkout asks `Internal.checkout_dir` (nil when installed), and `sound.rb` is the gem's executable.
`spec/release/gemspec_spec.rb` guards what ships and that every gem lib/ requires is a runtime dependency.
<!-- /summary -->

## Quick reference

- `bundle exec rake -f Rakefile release:local release:smoke DIR=/some/scratch` (MAKE_JOBS=8 speeds the install's compiles; ~2.5 min on the Mac container, most of it compiling); `release:build` only builds the .gem files.
- In DIR: `gems/` (the .gem files: a local source), `src/` (clones of the git dependencies), `gem_home/` (the install), `home/` (the clean room's HOME), `room/` (its working directory).
- New files under lib/, bin/, ext/, presets/, matrices/, or sounds/ must be tracked (`git add`) before building: the gemspec lists `git ls-files`, and the build stops on untracked ones.
- Paths: `Internal.user_data_dir(*parts)`, `Internal.checkout_dir`, `Internal.scratch_dir(name)` (`lib/mb/sound/internal.rb`); example sounds `lib/mb/sound/example_sounds.rb`.

## The procedure (release-1, 2026-11-10)

Persona round 3 (workbench/research/panel2-retro/retro.md, "Mechanisms for future panels") runs personas outside /app with mb-sound installed as a gem and only user-facing docs.  The prerequisite: mb-sound installs and runs in an empty directory with no checkout.

`MB::Sound::LocalRelease#build` (under the checkout's bundle):

1. `gem build` of `mb-sound.gemspec` and `gems/mb-term/mb-term.gemspec`.
2. For each git source in Gemfile.lock that mb-sound's runtime dependencies reach (mb-math, mb-util; the numo-narray compat fork is a development-only Gemfile entry), a clone into `src/<name>` at the locked revision, from Bundler's own checkout (`Bundler.load.specs[name]`) when it has the commit, else from the remote; then `gem build` there.
3. The other gems of the runtime closure at their locked versions, copied from the RubyGems and Bundler caches (`gem fetch` only when missing).  Default gems the lockfile doesn't list are left to Ruby.

`#install` runs `gem install --local --no-document --install-dir gem_home mb-sound-*.gem` in `gems/`, with `#clean_env`: no BUNDLE_*, GEM_*, RUBY*, MB_SOUND_* variables from the caller, GEM_HOME=gem_home, GEM_PATH=gem_home plus Ruby's own gem directory (`Gem.default_dir`: the default and bundled gems of a fresh Ruby, as a musician has them), a fresh HOME, OUTPUT_TYPE=null.  The install compiles every C extension (rake-compiler isn't involved: each `extconf.rb` alone must work).  No network is used at install time.

A musician without the release directory would do the same from a directory of .gem files: `gem install --local mb-sound-<version>.gem` there (the README's Install section).  System packages: ffmpeg, libsamplerate, ALSA and JACK headers on Linux, as for the checkout (CLAUDE.md, System dependencies).

## What ships

`spec.files` is `git ls-files` minus specs, `gems/` (mb-term is its own .gem), design notes, research, experiments, the golden set, release tooling, agent and container setup, the Rakefile, and the bundle files.  bin/ (all scripts, run by path: `ruby $(gem contents mb-sound | grep bin/effects/reverb.rb)`), presets/, matrices/, and sounds/ (6.5 MB; the README and help examples) ship.  `spec.executables` is `['sound.rb']` only (question for the maintainer: more, e.g. `play.rb`, `record.rb`, and under which names).  Runtime dependencies gained `pry` (the console) and `word_wrap` (`MB::U.wrap`, used by `play`'s header).

## Installed-gem behavior

- `Internal.checkout_dir`: mb-sound's directory when it has `.git` and a Gemfile (a checkout or worktree), else nil.  Take replay scripts load the checkout's bundle only then; `take.save`/`rec_audio` with `repo: true` fall back to the user data directory; the hand-tune worker sets BUNDLE_GEMFILE only then; help pages name design notes only then.
- `Internal.scratch_dir(name)`: the checkout's `tmp/<name>`, else the user data directory's `tmp/<name>` (debug dumps, `take.save :tmp`).  The gem's own directory is never written (the smoke test checks).
- `Internal.user_data_dir(*parts)`: ~/Library/Application Support/mb-sound on macOS, $XDG_DATA_HOME/mb-sound (~/.local/share/mb-sound) elsewhere; presets (the user shelf), takes, ui layouts, and help state, each with its own override variable as before.
- `MB::Sound::ExampleSounds`: a relative `sounds/...` name that isn't a file in the working directory reads mb-sound's copy (prepended to FFMPEGInput, so `file_input`, `read`, Samples, `play 'file'`); a working-directory file wins, graph documents keep FileGuard's rules.
- `bin/sound.rb` as the gem's executable: RubyGems' wrapper starts Ruby without the shebang's variables, and Ruby reads RUBY_THREAD_TIMESLICE only when it starts, so the console execs itself again with `RUBY_THREAD_TIMESLICE=10 MB_SOUND_YJIT=1` when started through the wrapper (`$0` is another file named sound.rb).  Without a Gemfile, `require 'bundler/setup'` does nothing and mb-sound loads from the installed gems; pry-byebug is optional.  Other bin/ scripts keep `require 'bundler/setup'`, which is likewise a no-op outside a bundle.
- `ext/mb/sound/fast_ui`: its extconf finds mb-term's header through `Gem::Specification.find_by_name` (gem install runs extconf.rb without loading dependencies), and its `depend` names the repository's copy through `$(wildcard ...)` (depend:check reads it as the path).

## What the clean room found (2026-11-10)

In order of discovery, all fixed on release-1: fast_ui's extconf didn't find mb-term's header, then its depend file required the repository's copy; `Failed to load the WordWrap gem` on every `play`; `sound.rb` required `benchmark` (a bundled gem, not declared) and `pry-byebug` (development), then crashed in the pry-byebug workaround without it; the gem executable lost the time slice and YJIT; the README's and help's `sounds/` examples failed outside the checkout; debug dumps and `take.save :tmp` would have written into the gem's directory; take replays named a missing Gemfile.  Seen but not changed: psych `~> 5.2.3` excludes Ruby 4.0's default psych 5.3.1, so the install compiles psych 5.2.6 (needs libyaml headers); extensions build with `-Werror`, so a compiler with new warnings fails the install; a song script with no declared params prints its options hash (`{output: "x.flac"}`) before rendering.

## Smoke checks

`CleanRoomSmoke#run` writes small Ruby files into `room/` and runs them as processes with the clean environment: loading (no checkout file in `$LOADED_FEATURES`, every built extension loaded), a DSL song file rendered (`render ... do bg ... end`, non-silent) and played through NullOutput, help pages and lessons, the library (shelves, `find`, a preset rendered), the README's sounds/ examples, the installed `sound.rb` with piped lines (time slice 10 and YJIT on, `take.save :tmp` and `debug_dump` into HOME's data directory), `bin/play.rb --help` and `bin/effects/reverb.rb` rendering from the gem, then that nothing was written into the gem and nothing unexpected left in the room.  The release tasks aren't part of any suite (the install compiles for minutes); run them before a persona round or a release.
