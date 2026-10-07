#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# An experimental FM synthesizer that chains held notes: each new held note
# frequency-modulates the note held before it, and only the first held note
# is heard.  If only one note is held, it plays unmodulated.  Releasing a
# note in the middle of the chain joins its neighbors.  The modulation wheel
# controls the overall intensity of modulation (the peak frequency deviation
# each link adds, 0 to 10 kHz), and each stacked note's velocity scales the
# depth of its own link, so harder keys modulate more: --velocity-range dB
# (default 24) across the velocity range, unchanged at velocity 96 (+5.9 dB
# at 127, -6 dB at 64, -12 dB at 32; 0 turns it off).
# (C)2021 Mike Bourgeous
#
# This is the 2021 bin/synths/fm_synth.rb on the Notes/Stream MIDI API
# (fm_synth.rb is now a plain two-operator FM synth).  Differences from the
# 2021 script:
# - Note events land on their exact samples instead of at the start of the
#   buffer they arrive in.
# - The sustain pedals hold notes (the old MIDI manager ignored them).
# - --index sets the modulation before the wheel moves (default 1000 Hz, as
#   the old script meant to; it actually started at 0 until CC 1 arrived,
#   which --index 0 reproduces).
# - The mod wheel is smoothed by graph smoothing (50 ms) and read once per
#   event segment, instead of the old 15 Hz filter run once per buffer.
#
# Usage: $0 [options] [midi_file_or_port [output_file]]
#
# Plays live MIDI, or a MIDI file, showing a table of the oscillators while
# it plays (--no-table to hide it).  Run with --help for all options.
#
# Examples:
#     $0                                    # live MIDI
#     $0 spec/test_data/c_major.mid         # a MIDI file
#     $0 --no-table spec/test_data/midi.mid fm.flac
#     $0 --index 0 spec/test_data/mod_wheel.mid   # the old starting point
#     $0 spec/test_data/fm_chain_demo.mid   # FM-friendly key orders and wheel moves
#     $0 --velocity-range 0 spec/test_data/fm_chain_demo.mid   # without velocity
#
# Playing it: hold keys in order (the first sounds, each later key modulates
# the one before) at close FM-friendly intervals, and ride the mod wheel.  A
# growly bass: D4, then A4, then G#5 (or D#5), mod wheel around 71; it likes
# a little chorus and reverb.  Play the modulating keys softly for a
# rounder tone and harder for more bite.

require 'bundler/setup'
require 'mb-sound'

# The chained FM oscillators, driven by a MIDI stream.
class FMChain
  include MB::Sound::GraphNode
  include MB::Sound::GraphNode::SampleRateHelper

  # The velocity (normalized) at which a link gets exactly the wheel's
  # modulation index.
  VELOCITY_REFERENCE = 96 / 127.0

  # +notes+ is a MB::Sound::Notes (the script's +midi+); +index+ a node
  # giving the modulation index in Hz (read once per event segment).
  # +velocity_range+ is the dB range of each link's index over the
  # modulating note's velocity 0..1 (0 dB at VELOCITY_REFERENCE).
  def initialize(notes, index:, velocity_range: 24, osc_count: 8, sample_rate: 48000)
    @sample_rate = sample_rate.to_f
    @reader = notes.note_stream.reader
    @time = @reader.cursor
    @index_node = index.get_sampler
    @mod_index = 0.0
    @velocity_range = velocity_range.to_f
    @link_gain = {}

    @oscillators = osc_count.times.map {
      # Parabola is a little more interesting than sine without being too
      # chaotic.  Each frequency is a Mixer that #note rewires (a constant
      # for the note plus the next oscillator in the chain as FM).
      MB::Sound::Tone.new(
        wave_type: :parabola,
        frequency: MB::Sound::GraphNode::Mixer.new([], sample_rate: @sample_rate),
        sample_rate: @sample_rate
      ).at(-10.db)
    }
    @oscs_used = 0
    @osc_map = {}
    @tail = 0
    @buf = nil
    @node_type_name = 'FM chain'
  end

  def sources
    { index: @index_node }
  end

  # True once a MIDI file has ended (every event read) and no note is held,
  # so the script runner can stop once the output is quiet.
  def ended?
    @reader.ended? && @oscs_used == 0
  end

  # The index multiplier for a modulating note of normalized +velocity+.
  def velocity_gain(velocity)
    10 ** (@velocity_range * (velocity - VELOCITY_REFERENCE) / 20)
  end

  def print
    MB::U.headline("Oscillators (#{@oscs_used} in use, index #{@mod_index.round(1)} Hz)")
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

  def sample(count)
    count = count.round
    if ended?
      @tail += count
      return nil if @tail > MB::Sound::Synth::TAIL_SECONDS * @sample_rate
    end

    index = @index_node.sample(count)
    events = @reader.next(Rational(count) / @sample_rate.to_r)
    @buf = Numo::SFloat.zeros(count) if @buf.nil? || @buf.length != count

    start = @time
    @time += Rational(count) / @sample_rate.to_r
    pos = 0

    # Split the buffer at each event's sample
    events.each do |e|
      at = ((e.time - start) * @sample_rate).floor.clamp(pos, count)
      render(index, pos, at)
      pos = at
      note(e.note, e.type == :note_on, e.velocity) if e.type == :note_on || e.type == :note_off
    end
    render(index, pos, count)

    @buf
  end

  private

  # Renders samples +from+...+to+ of the buffer through the chain.
  def render(index, from, to)
    return if to <= from

    @mod_index = index.nil? ? @mod_index : index[from].to_f
    @oscillators.each do |o|
      mod = o.frequency.summands.first
      o.frequency[0] = link_index(mod) if mod
    end

    data = @oscillators[0].sample(to - from)
    @buf[from...to] = @oscs_used > 0 ? data : 0
  end

  # The FM gain (Hz of deviation) of the link modulated by +osc+.
  def link_index(osc)
    @mod_index * @link_gain.fetch(osc, 1.0)
  end

  def note(number, on, velocity = nil)
    if on
      note(number, false) if @osc_map.include?(number)

      if @oscs_used < @oscillators.length
        osc = @oscillators[@oscs_used]
        @osc_map[number] = osc
        @link_gain[osc] = velocity_gain(velocity || VELOCITY_REFERENCE)

        osc.frequency.constant = MB::Sound.tuning.frequency_of(number)
        osc.frequency.clear

        if @oscs_used > 0
          # Wire this oscillator as FM modulator for the previous oscillator
          prev = @oscillators[@oscs_used - 1]
          prev.frequency.clear
          prev.frequency[osc] = link_index(osc)
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
          prev.frequency[next_osc] = link_index(next_osc) if next_osc
        end

        osc.frequency.clear

        @oscillators.delete(osc)
        @oscillators << osc

        @oscs_used -= 1
      end
    end
  end
end

MB::Sound.synth_script(
  index: [1000.0, Float, '-x', 'Modulation index (Hz of deviation per link) before the mod wheel moves', 0.0..10000.0],
  velocity_range: [24.0, Float, '-V', 'dB range of each link\'s index over the modulating key\'s velocity (0 dB at 96; 0 = off)', 0.0..60.0],
  table: [true, 'Show the oscillator table while playing'],
) { |midi, p|
  wheel = midi.cc(1, range: 0.0..10000.0, default: (p.index / 10000.0 * 127).round, name: 'FM index')
  synth = FMChain.new(midi, index: wheel.smooth(0.05), velocity_range: p.velocity_range, sample_rate: midi.sample_rate)

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
