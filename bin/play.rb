#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 MB_SOUND_YJIT=1 ruby
# Plays sound files, tracker modules (.mod, .669, .s3m, .xm, .it), and MIDI
# files (on a soft saw), one after another, on a terminal screen picked by
# the file's type (MB::Sound::Player; plain lines when not on a terminal or
# with --no-ui):
#
# - a sound file: its whole-file overview with the play head, a scope and
#   spectrum, true-peak and loudness meters, and its format, rate,
#   channels, length, and integrated loudness;
# - a module: its pattern rows as a tracker shows them, the row playing
#   highlighted, a VU per channel, and the song's format, channels,
#   patterns, and samples;
# - a MIDI file: its notes as a piano roll around the play head.
#
# Keys (? lists them): Space pause, Left/Right 5 s (a module: a bar),
# Up/Down or [ ] 30 s (a module: a pattern's section), - and + the volume
# (2 dB steps, 0 dB at most), n/p the next/previous file, Home the start,
# q or Esc quits.  Without the screen, Ctrl-C skips to the next file
# (twice within a second quits).
#
# Usage: $0 [options] file [...]
#
# Examples:
#     $0 spec/test_data/arp_a7.flac
#     $0 ~/music/tune.mod
#     $0 *.flac *.xm                # a playlist: n/p move through it
#     $0 --layout player_module song.it
#     $0 --no-ui song.mid           # plain lines

require 'bundler/setup'
require 'mb-sound'

MB::Sound.script(
  args: 1..,
  ui: [true, 'Show the player screen on a terminal (--no-ui: plain lines)'],
  layout: [nil, 'A screen layout for every file (player_audio, player_module, player_midi, player)', '-l', String]
) { |files, p|
  layout = p.layout&.delete_prefix(':')&.to_sym
  if layout && !MB::Sound::UI.show_layouts.key?(layout)
    raise MB::Sound::ScriptRunner::InputError, "--layout #{layout}: not a player screen (#{MB::Sound::UI.show_layouts.keys.grep(/player/).join(', ')})"
  end
  MB::Sound::Player.new(files, ui: p.ui ? :auto : false, layout: layout).run
}
