#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
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

# Live mode: mistakes that raise in scripts only warn here, so a live set keeps
# playing (see MB::Sound::LiveMethods)
MB::Sound.live = true

# Shared Tee buffer checks are off unless MB_SOUND_CHECK_SHARED is set; here
# they only warn, so a live set keeps playing (see GraphNode::Tee)
MB::Sound::GraphNode::Tee.shared_check = :warn if MB::Sound::GraphNode::Tee.shared_check

# Compile common node types before anything plays (YJIT is on via the shebang),
# and the dashboard band's painter (`ui`)
MB::Sound.warm_up
MB::Sound::UI.warm_up

def clear
  STDOUT.write("\e[H\e[2J")
  STDOUT.flush
end

puts
clear if ARGV.include?('--clear')

# Console help (lib/mb/sound/help.rb): help, now, lesson; Pry's own help
# moves to pry-help.  The welcome screen is a few lines and one random tip.
require 'mb/sound/help'
MB::Sound::Help::Level.apply # the saved listening level becomes the monitor trim
MB::Sound::Help.first_level_check # first launch only, in a terminal, with a sound card
puts MB::Sound::Help.welcome, ''

# The take: an always-on log of every line typed and exactly where each change
# it made landed (see MB::Sound::Take); `take.save` writes a script that
# replays the performance.  Started after warm_up, so it records the random
# generator as the first line will find it.
MB::Sound::Take.current
Pry.config.hooks.add_hook(:before_eval, :mb_sound_take) { |code, _pry| MB::Sound::Take.current.begin_line(code) }
Pry.config.hooks.add_hook(:after_eval, :mb_sound_take) { |_result, _pry| MB::Sound::Take.current.end_line }

Pry.config.commands.rename_command('pry-play', 'play')
Pry.config.commands.rename_command('pry-reset', 'reset')
Pry.config.commands.rename_command('pry-hist', 'hist')
MB::Sound::Help.install_pry!

# Tab completion of track, scene, knob, bus, layout, and pane names after the
# commands that take them (`go :<Tab>`), and session names first for any
# Symbol (see MB::Sound::UI::Completion)
MB::Sound::UI::Completion.install

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

Pry.start(
  MB::Sound,
  prompt: Pry::Prompt.new(:mb_sound, "The interactive sound environment's default prompt", [
    # With a Session running, the prompt starts with its status: bar:beat,
    # recording and armed tracks, render load (MB::Sound::UI.prompt_status;
    # MB::Sound::UI.prompt_status_enabled = false turns it off)
    _pry_a = -> (obj, nest, pry) {
      status = MB::Sound::UI.prompt_status
      "\1\e[36m\2#{File.basename($0)}\1\e[0m\2 #{status ? "#{status} " : ''}\1\e[32m\2#{obj}\1\e[0;2m\2(#{nest}) > \1\e[0m\2"
    },
    -> (obj, nest, pry) {
      ' ' * _pry_a.call(obj, nest, pry).gsub(/(\x01|\x02|\e\[[0-9;]*[A-Za-z])/, '').length
    }
  ]),
  exception_handler: ->(output, exception, _pry) {
    output.puts(MB::U.color_trace(exception, exclude: %r{/pry-.*/lib/pry}))

    # color_trace prints #message; since Ruby 3.3 did_you_mean's "Did you
    # mean?" suggestions are only in #detailed_message (after the message's
    # lines)
    hint = exception.detailed_message(highlight: false).lines.drop(exception.message.lines.count).join.strip
    output.puts("\e[33m#{hint}\e[0m") unless hint.empty?
  },
  load_pry_byebug: false,
  driver: PryByebugWorkaround
)
