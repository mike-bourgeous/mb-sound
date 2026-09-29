#!/usr/bin/env ruby
# An experimental FM synthesizer that uses later notes to modulate earlier
# notes.  If only one note is played, that note is unmodulated.  Each later
# note modulates the note that came before it.  The modulation wheel controls
# the intensity of modulation.
# (C)2021 Mike Bourgeous
#
# Usage: $0 [options] [midi_file_or_port [output_file]]
#
# Plays live MIDI (JACK), or a MIDI file, showing a table of the oscillators
# while it plays (--no-table to hide it).  Run with --help for all options.
#
# Examples:
#     $0                                    # live MIDI
#     $0 spec/test_data/c_major.mid         # a MIDI file
#     $0 --no-table spec/test_data/c_major.mid fm.flac

require 'bundler/setup'
require 'mb-sound'

class FM
  include MB::Sound::GraphNode

  attr_reader :sample_rate

  def initialize(manager:, osc_count: 8)
    @sample_rate = 48000
    @manager = manager
    @manager.on_note(&method(:note))

    @manager.on_cc(1, range: 0.0..10000) do |mod|
      @mod_index = mod
      @oscillators.each do |o|
        o.frequency[0] = @mod_index unless o.frequency.empty?
      end
    end

    @oscillators = osc_count.times.map { |o|
      # Parabola is a little more interesting than sine without being too chaotic
      o = 440.hz.parabola.at(-10.db).oscillator
      o.frequency = MB::Sound::GraphNode::Mixer.new([], sample_rate: 48000)
      o
    }
    @oscs_used = 0
    @osc_map = {}

    @mod_index = 1000
  end

  def print
    MB::U.headline("Oscillators (#{@oscs_used} in use)")
    MB::U.table(
      @oscillators.map { |o|
        [
          o.__id__,
          o.wave_type,
          o.frequency.constant.round(3),
          o.frequency.summands.map(&:__id__),
          o.frequency.gains,
        ]
      },
      header: [:id, :wave_type, :frequency, :modulator, :mod_gain],
      variable_width: true
    )
  end

  def note(number, velocity, on, timestamp)
    if on
      note(number, velocity, false) if @osc_map.include?(number)

      if @oscs_used < @oscillators.length
        osc = @oscillators[@oscs_used]
        @osc_map[number] = osc

        osc.frequency.constant = MB::Sound::Oscillator.calc_freq(number)
        osc.frequency.clear

        if @oscs_used > 0
          # Wire this oscillator as FM modulator for the previous oscillator
          prev = @oscillators[@oscs_used - 1]
          prev.frequency.clear
          prev.frequency[osc] = @mod_index
        end

        @oscs_used += 1
      end
    else
      osc = @osc_map.delete(number)
      if osc
        index = @oscillators.index(osc)

        if index > 0
          prev = @oscillators[index - 1]

          # Disconnect this oscillator from the FM chain
          prev.frequency.clear

          next_osc = osc.frequency.summands.first
          prev.frequency[next_osc] = @mod_index if next_osc
        end

        osc.frequency.clear

        @oscillators.delete(osc)
        @oscillators << osc

        @oscs_used -= 1
      end
    end
  end

  # True once a MIDI file input has passed its last event, so the script
  # runner can stop when the output is quiet (see MIDI::MIDIFile#ended?).
  def ended?
    @manager.midi_in.respond_to?(:ended?) && @manager.midi_in.ended?
  end

  def sample(count)
    @manager.update
    return nil if @manager.midi_in.respond_to?(:done?) && @manager.midi_in.done?

    @oscillators[0].sample(count) * (@oscs_used > 0 ? 1 : 0)
  end
end

MB::Sound.synth_script(
  table: [true, 'Show the oscillator table while playing'],
) { |input, p|
  manager = MB::Sound.midi_manager(input)
  synth = FM.new(manager: manager)
  manager.midi_in.clock.node ||= synth if manager.midi_in.respond_to?(:clock)

  next synth unless p.table

  puts "\n" * MB::U.height
  at_exit { puts "\n" * MB::U.height }

  buffers = 0
  synth.spy { |data|
    if buffers % 20 == 0
      puts "\e[H"
      synth.print
    end
    buffers += 1
  }
}
