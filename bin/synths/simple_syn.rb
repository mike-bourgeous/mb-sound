#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 ruby
# One-oscillator synthesizer based on MB::Sound::MIDI::Voice (slight upgrade of
# bin/synths/ep2_syn.rb).
#
# GraphVoice is better so use that for building new synths.
#
# Usage: $0 [options] [midi_file_or_port [output_file]]
#
# Plays live MIDI (JACK), or a MIDI file; CC 1 (the mod wheel) sweeps each
# voice's filter and adds vibrato.  Run with --help for all options.
#
# Examples:
#     $0                                    # live MIDI
#     $0 spec/test_data/c_major.mid         # a MIDI file
#     $0 --oversample 4 spec/test_data/c_major.mid simple.flac

require 'bundler/setup'
require 'mb-sound'

MB::Sound.tuning b4: 480

OSC_COUNT = 8

MB::Sound.synth_script(
  oversample: [16.0, 'Oversampling factor'],
) { |input, p|
  manager = MB::Sound.midi_manager(input)

  osc_pool = MB::Sound::MIDI::VoicePool.new(
    manager,
    OSC_COUNT.times.map { MB::Sound::MIDI::Voice.new(manager: manager) }
  )
  manager.midi_in.clock.node ||= osc_pool if manager.midi_in.respond_to?(:clock)

  manager.on_cc(1, default: 1.8, range: 1..3) do |decade|
    freq = 20.0 * 10.0 ** decade

    osc_pool.each do |v|
      v.cutoff = freq
      v.vibrato_intensity = (decade - 1) / 2
    end
  end

  graph = osc_pool
    .real
    .filter(:lowpass, cutoff: 16000 * MB::M.min(1, p.oversample))
    .oversample(p.oversample, mode: :libsamplerate_fastest)

  (graph * 0.4).softclip(0.5)
}
