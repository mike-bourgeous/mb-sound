#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 MB_SOUND_YJIT=1 ruby
# "Night Bus: Capture": a jam on the Night Bus tracks (night_bus_flow.rb)
# showing MIDI recording (phase 4 of the arrangement tools).  A keyboard
# player's hands (a scripted stand-in for live MIDI, slightly loose, with
# a filter knob sweep) play over the groove; the riff they play is
# captured into a track and loops on, then a 4-bar answer is recorded with
# the looper and swaps in where it closes, and a controller sweep moves
# the hook's filter through `learn`.  21 bars at 126 BPM plus the ring-out.
#
#   bars 1-4   intro drums; `arm :keys` at bar 3 (the hands now play
#              through the keys track's pluck: its monitor, keys/live)
#   bars 5-6   the hands play a 2-bar riff (A minor, Am-G) over the groove
#   bar 7      `capture :keys, 2, quantize: [16, amount: 0.8]`: the riff
#              they just played loops on the keys track from bar 7
#   bar 9      `rec 4`: the hands play a 4-bar answer (Am-F-G-E); it
#              swaps in at bar 13, where the drop-ish scene starts
#   bar 13     `learn :cut`; the hands turn a knob (CC 74) up and back
#              down over 2 bars: the hook's lowpass follows it
#   bar 21     everything rings out
#
# Usage:
#     bin/songs/night_bus_capture.rb                    # plays live
#     bin/songs/night_bus_capture.rb capture.flac       # renders (-f to overwrite)
#     bin/songs/night_bus_capture.rb --quantize 0 x.flac   # the riff as played (no quantize)
#     bin/songs/night_bus_capture.rb --no-loop x.flac   # the hands only: nothing captured or recorded
#
# With a real keyboard in bin/sound.rb (live MIDI goes through the
# session's MIDI input, so a saved take replays what you played):
#     load 'bin/songs/night_bus_capture.rb'
#     night_bus_capture(hands: false)   # tracks and scenes; then go :jam
#     arm :keys                  # hear your keyboard through the pluck
#     capture :keys              # the phrase you just played loops from the next bar
#     capture :keys, 2, quantize: 16    # or exactly the last 2 bars, on 16ths
#     rec 4                      # a 4-bar loop from the next bar, swapped in when it closes
#     captures                   # => {keys_1: Clip(...), keys_2: ...}
#     scene :more, drums: last_stop_kits[:drop], keys: captures[:keys_1]; go :more
#     learn :cut                 # the next knob you turn takes the hook's filter
#     rec_audio 'sets/jam.flac'; stop_rec_audio on: :bar   # the master bus to a file
#     undo                       # a capture or rec is one undo step
#     take.save                  # the replay script includes your MIDI

require 'bundler/setup'
require 'mb-sound'
require_relative 'night_bus_flow'

module MB::Sound
  NIGHT_BUS_CAPTURE_BARS = 21

  # A MIDI Source playing a list of Events (times in seconds since it was
  # first read): the stand-in for a keyboard player's hands.
  class NightBusHands
    include MIDI::Source

    def initialize(events)
      @events = events.sort_by(&:time)
    end

    def read_events(from, to)
      @events.select { |e| e.time >= from && e.time < to }
    end
  end

  # The hands' events: [bar (from 1), 16th step, note, length in 16ths,
  # velocity 0..127] notes, loosened by up to 12 ms (seeded), and a CC 74
  # sweep.  Times are seconds from the start of bar 1 at 126 BPM.
  def self.night_bus_hands(bpm: 126)
    bar = MB::Sound::Sequence::TempoMap.seconds_at(1.0, bpm)
    step = bar / 16
    rnd = Random.new(7)
    riff = [
      # The captured riff (bars 5-6): Am, then G
      [5, 0, A4, 2, 100], [5, 3, C5, 1, 78], [5, 6, E5, 2, 112], [5, 10, D5, 1, 70], [5, 12, C5, 3, 96],
      [6, 0, G4, 2, 100], [6, 3, B4, 1, 74], [6, 6, D5, 2, 106], [6, 10, C5, 1, 68], [6, 12, B4, 2, 90], [6, 14, G4, 1, 60],
      # The recorded answer (bars 9-12): Am, F, G, E
      [9, 0, E5, 2, 104], [9, 3, C5, 1, 76], [9, 6, A4, 2, 108], [9, 10, B4, 1, 72], [9, 12, C5, 3, 94],
      [10, 0, F5, 2, 100], [10, 3, C5, 1, 74], [10, 6, A4, 2, 104], [10, 10, C5, 1, 70], [10, 12, A4, 3, 88],
      [11, 0, D5, 2, 102], [11, 3, B4, 1, 76], [11, 6, G4, 2, 106], [11, 10, A4, 1, 70], [11, 12, B4, 3, 92],
      [12, 0, E5, 2, 108], [12, 3, Gs4, 1, 80], [12, 6, B4, 2, 110], [12, 10, D5, 1, 74], [12, 12, E5, 2, 100], [12, 14, Gs4, 1, 66],
    ]

    events = riff.flat_map { |b, s, note, len, vel|
      on = (b - 1) * bar + s * step + rnd.rand(-0.012..0.012)
      off = on + len * step * 0.85
      n = note.number.round
      [MIDI::Event.parse([0x90, n, vel], time: on.rationalize(1/48000r)), MIDI::Event.parse([0x80, n, 64], time: off.rationalize(1/48000r))]
    }

    # A filter sweep over bars 13.5-15.5: up, then most of the way down
    sweep_start = 12.5 * bar
    events += (0..48).map { |i|
      x = i / 48.0
      raw = (x < 0.5 ? 10 + 230 * x : 125 - 150 * (x - 0.5)).round.clamp(0, 127)
      MIDI::Event.parse([0xb0, 74, raw], time: (sweep_start + x * 2 * bar).rationalize(1/48000r))
    }
    events
  end

  # Sets up the jam on the current session (the Night Bus tracks and a
  # pluck keys track), and with +hands: true+ plays the scripted hands and
  # the performer's commands.  +quantize+ is the capture's quantize amount
  # (0 for the riff as played); +loop: false+ only plays the hands.
  def self.night_bus_capture(hands: true, quantize: 0.8, loop: true)
    last_stop
    k = last_stop_kits
    c = last_stop_clips

    # The keys: a 3-voice pluck (monitored while armed, then playing the
    # captured and recorded loops)
    track(:keys, q: 1) { |clip| last_stop_pluck(clip, brightness: 10, level: 5) }

    # Scenes keep the keys track (:keep): the jam happens on top of them
    scene :jam_intro, drums: k[:intro], keys: :keep
    scene :jam, drums: k[:groove], sub: c[:sub], hook_far: c[:hook], cut: 900, keys: :keep
    scene :jam_drop, drums: k[:drop], bass: c[:roll], hook: c[:hook], cut: 1400, space: 0.2, keys: :keep

    session = Session.current
    session.midi_in.input = MIDI::Stream.new(NightBusHands.new(night_bus_hands)) if hands

    go :jam_intro, on: :now
    return unless hands

    say = ->(bar, line) { puts format("\e[2mbar %-3s\e[0m \e[36m›\e[0m %s", bar, line) }
    at_bar(3) { say[3, 'arm :keys']; arm :keys }
    at_bar(5) { go :jam, on: :now }
    if loop
      q = quantize.to_f > 0 ? [16, { amount: quantize.to_f.rationalize(1/100r) }] : nil
      at_bar(7) {
        say[7, "capture :keys, 2#{q ? ", quantize: [16, amount: #{q[1][:amount]}]" : ''}"]
        capture :keys, 2, quantize: q
      }
      at_bar(9) { say[9, 'rec 4   # an answer, swapped in at bar 13']; rec 4 }
    end
    at_bar(13) { say[13, 'learn :cut   # then a knob sweep']; go :jam_drop, on: :now; learn :cut }
    at_bar(NIGHT_BUS_CAPTURE_BARS) { say[NIGHT_BUS_CAPTURE_BARS, 'stop   # ring out']; disarm; stop }
  end

  if main_script?(__FILE__)
    song_script(
      bars: NIGHT_BUS_CAPTURE_BARS,
      quantize: [0.8, 'Quantize amount for the captured riff (0: as played)', '-Q', Float, 0.0..1.0],
      loop: [true, 'Capture and record loops (--no-loop: the hands only)'],
    ) { |p| night_bus_capture(quantize: p.quantize, loop: p.loop) }
  end
end
