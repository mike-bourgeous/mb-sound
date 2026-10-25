#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 MB_SOUND_YJIT=1 ruby
# Interactive sound environment.  Uses Pry within the MB::Sound module context.
# See README.md for more info, including copyright and license.

require 'rubygems'
require 'bundler/setup'

require 'benchmark'

require 'io/console'
require 'pry'
require 'pry-byebug'

Bundler.require

MB::U.sigquit_backtrace

$LOAD_PATH << File.expand_path('../lib', __dir__)

require 'mb/sound'

# No color into pipes and logs, or under NO_COLOR or TERM=dumb: one decision
# for every part of the console (MB::Sound::ColorPolicy)
unless MB::Sound::ColorPolicy.color?($stdout)
  Pry.config.color = false
  MB::Sound::ColorPolicy.strip_output!
end

# Live mode: mistakes that raise in scripts only warn here, so a live set keeps
# playing (see MB::Sound::LiveMethods)
MB::Sound.live = true

# Shared Tee buffer checks are off unless MB_SOUND_CHECK_SHARED is set; here
# they only warn, so a live set keeps playing (see GraphNode::Tee)
MB::Sound::GraphNode::Tee.shared_check = :warn if MB::Sound::GraphNode::Tee.shared_check

# Compile common node types before anything plays (YJIT is on via the shebang and MB::Sound::JIT),
# and the dashboard band's painter (`ui`)
MB::Sound.warm_up
MB::Sound::UI.warm_up

def clear
  STDOUT.write("\e[H\e[2J")
  STDOUT.flush
end

puts
clear if ARGV.include?('--clear')

# The terminal's name and version (XTVERSION), asked once, for debug_dump
# (see MB::Sound::TerminalInfo)
MB::Sound::TerminalInfo.query!

# Console help (lib/mb/sound/help.rb): help, now, lesson; Pry's own help
# moves to pry-help.  The welcome screen is a few lines and one random tip.
require 'mb/sound/help'
MB::Sound::Help::Level.apply # the saved listening level becomes the monitor trim
MB::Sound::Session::Cue::Prefs.apply # the saved phones blend (cue_mix 0.3, save: true)
MB::Sound::Help.first_level_check # first launch only, in a terminal, with a sound card
puts MB::Sound::Help.welcome, ''

# The take: an always-on log of every line typed and exactly where each change
# it made landed (see MB::Sound::Take); `take.save` writes a script that
# replays the performance.  Started after warm_up, so it records the random
# generator as the first line will find it.
# The take saves itself every minute to the user data dir (autosave_*.rb), so
# even a crash leaves it.
MB::Sound::Take.current.autosave!
Pry.config.hooks.add_hook(:before_eval, :mb_sound_take) { |code, _pry| MB::Sound::Take.current.begin_line(code) }
Pry.config.hooks.add_hook(:after_eval, :mb_sound_take) { |_result, _pry| MB::Sound::Take.current.end_line }

# Pry commands named like console commands (help, play, finish, ...) move
# to pry-<name> (see MB::Sound::Help.rename_pry_collisions!)
MB::Sound::Help.install_pry!

# Tab completion of track, scene, knob, bus, layout, and pane names after the
# commands that take them (`go :<Tab>`), and session names first for any
# Symbol (see MB::Sound::UI::Completion)
MB::Sound::UI::Completion.install

# The tiled screen's `:` palette evaluates in the console's binding (see
# MB::Sound::UI::Tiles)
MB::Sound::UI.install_pry!

# Continuation lines of Reline's multiline editor get a dim prompt naming the
# open constructs, and Enter runs a complete command wherever the cursor is
# (Alt-Enter for a new line; see MB::Sound::UI::Prompt and
# MB::Sound::UI::EnterSubmits)
MB::Sound::UI::Prompt.install!
MB::Sound::UI::EnterSubmits.install!

# Pry 0.16 reads with Reline's multiline editor, which treats piped input as
# one paste and evaluates it as a single block (so `printf 'a\nb\n' |
# bin/sound.rb` stopped at the first error and printed no results).  Read
# piped input a line at a time, as Pry 0.14 did.
Pry.config.multiline = false unless $stdin.tty?

# Work around issue introduced in pry-byebug 3.10.x that breaks Pry when
# launched from a console script like this one.
#
# See comments on https://github.com/mike-bourgeous/mb-sound/issues/37
#
# TODO: remove this workaround if/when a proper fix ends up upstream.
class PryByebugWorkaround < Pry::REPL
  def self.start(options = {})
    return start_without_pry_byebug(options) unless options[:load_pry_byebug] != false
    super
  end
end

# An exception that ends the console writes a debug_dump (the take, the
# session's state, the exception) before it prints
begin
Pry.start(
  MB::Sound,
  prompt: Pry::Prompt.new(:mb_sound, "The interactive sound environment's default prompt", [
    # Pry's line counter, then the state only commands change: recording and
    # armed tracks, the form's section or scene (MB::Sound::UI::Prompt and
    # UI.prompt_status; MB::Sound::UI.prompt_status_enabled = false turns the
    # state off); continuation lines get a dim prompt naming what is open
    -> (obj, nest, pry) { MB::Sound::UI::Prompt.main(obj, nest, pry) },
    -> (obj, nest, pry) { MB::Sound::UI::Prompt.continuation(pry.eval_string) },
  ]),
  # Typos and errors raised on purpose print as one line with suggestions;
  # likely bugs keep a backtrace without Pry's frames (see
  # MB::Sound::ErrorFormat; `wtf?` shows the last full backtrace)
  exception_handler: ->(output, exception, _pry) {
    output.puts(MB::Sound::ErrorFormat.console(exception, color: MB::Sound::ColorPolicy.color?(output)))
  },
  load_pry_byebug: false,
  driver: PryByebugWorkaround
)
rescue Exception => e # rubocop:disable Lint/RescueException (SystemExit and Interrupt pass)
  raise if e.is_a?(SystemExit) || e.is_a?(Interrupt)
  begin
    dir = MB::Sound.debug_dump(exception: e) # (before the UI closes: ui.txt keeps the screen)
    MB::Sound::UI.off rescue nil
    $stderr.puts "\e[1;31mThe console ended with #{e.class}: #{e.message}\e[0m (debug dump: #{dir})"
  rescue Exception => e2 # rubocop:disable Lint/RescueException
    $stderr.puts "(debug_dump failed: #{e2.class}: #{e2.message})"
  end
  raise
ensure
  MB::Sound::Take.active&.stop_autosave
end
