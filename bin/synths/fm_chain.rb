#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# An experimental FM synthesizer that chains held notes: each new held note
# frequency-modulates the note held before it, and only the first held note
# is heard.  If only one note is held, it plays unmodulated.  Releasing a
# note in the middle of the chain joins its neighbors.  The modulation wheel
# controls the intensity of modulation (the peak frequency deviation each
# link adds, 0 to 10 kHz).
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

require 'bundler/setup'
require 'mb-sound'

# The chained FM oscillators, driven by a MIDI stream.
class FMChain
  include MB::Sound::GraphNode
  include MB::Sound::GraphNode::SampleRateHelper

  # +notes+ is a MB::Sound::Notes (the script's +midi+); +index+ a node
  # giving the modulation index in Hz (read once per event segment).
  def initialize(notes, index:, osc_count: 8, sample_rate: 48000)
    @sample_rate = sample_rate.to_f
    @reader = notes.note_stream.reader
    @time = @reader.cursor
    @index_node = index.get_sampler
    @mod_index = 0.0

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
      note(e.note, e.type == :note_on) if e.type == :note_on || e.type == :note_off
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
      o.frequency[0] = @mod_index unless o.frequency.summands.empty?
    end

    data = @oscillators[0].sample(to - from)
    @buf[from...to] = @oscs_used > 0 ? data : 0
  end

  def note(number, on)
    if on
      note(number, false) if @osc_map.include?(number)

      if @oscs_used < @oscillators.length
        osc = @oscillators[@oscs_used]
        @osc_map[number] = osc

        osc.frequency.constant = MB::Sound.tuning.frequency_of(number)
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
end

MB::Sound.synth_script(
  index: [1000.0, Float, '-x', 'Modulation index (Hz of deviation per link) before the mod wheel moves', 0.0..10000.0],
  table: [true, 'Show the oscillator table while playing'],
) { |midi, p|
  wheel = midi.cc(1, range: 0.0..10000.0, default: (p.index / 10000.0 * 127).round, name: 'FM index')
  synth = FMChain.new(midi, index: wheel.smooth(0.05), sample_rate: midi.sample_rate)

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
