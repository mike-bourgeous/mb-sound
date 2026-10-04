#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# Episode 2 of Code Sound & Surround
# Synthesizahh!!!
#
# Usage: $0 [options] [midi_file_or_port [output_file]]
#
# Plays live MIDI (JACK), or a MIDI file, through eight sawtooth voices and a
# resonant lowpass filter; CC 1 (the mod wheel) sweeps the filter.  The
# output is stereo; --impulse puts the filter's impulse response on the
# second channel instead, for scopes (it never goes quiet, so MIDI files play
# on for the 10 s tail limit).  Run with --help for all options.
#
# Examples:
#     $0                                    # live MIDI
#     $0 spec/test_data/c_major.mid         # a MIDI file
#     $0 spec/test_data/mod_wheel.mid ep2.flac
#     $0 --impulse                          # impulse response on the right

require 'bundler/setup'
require 'mb-sound'

MB::Sound.tuning b4: 480

OSC_COUNT = 8

MB::Sound.synth_script(
  impulse: [false, "Play the filter's impulse response on the second channel instead of the synth"],
) { |input, p|
  manager = MB::Sound.midi_manager(input)

  osc_pool = MB::Sound::MIDI::VoicePool.new(
    manager,
    OSC_COUNT.times.map { 240.hz.ramp.at(0).oscillator }
  )
  manager.midi_in.clock.node ||= osc_pool if manager.midi_in.respond_to?(:clock)

  filter = 1500.hz.lowpass(quality: 4)

  # The graph sets the filter's cutoff from this node on every buffer
  cutoff = 1500.constant.named('Cutoff')
  manager.on_cc(1, default: 1.8, range: 0..3) do |decade|
    cutoff.constant = 20.0 * 10.0 ** decade
  end

  synth = (osc_pool.oversample(16, mode: :libsamplerate_fastest).filter(filter, cutoff: cutoff) * 0.2).softclip(0.5)
  next synth.stereo unless p.impulse

  # Built from the synth's output so it ends when the synth does
  impulse = synth.proc { |d| filter.impulse_response(d.length) }.named('Impulse')
  [synth, impulse].channels
}
