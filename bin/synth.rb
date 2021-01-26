#!/usr/bin/env ruby
# A single-oscillator monophonic MIDI-controlled synthesizer.  Requires the
# mb-sound-jackffi gem.  This is a simple example that quantizes all MIDI
# events to audio buffer boundaries.
#
# Usage: ./bin/synth.rb [midi_port_to_connect]

require 'bundler/setup'

require 'forwardable'

Bundler.require

$LOAD_PATH << File.expand_path('../lib', __dir__)

require 'mb-sound-jackffi'
require 'mb/sound'

# A ring/pool of objects (e.g. oscillators) to be used in FIFO order.
# Error handling left as an exercise for the reader /s
class Ring
  extend Forwardable

  def_delegators :@array, :each, :map

  # Pass a block to be notified when an element is reused before being
  # released.
  def initialize(array = nil, &block)
    raise 'Pass an Array' unless array.is_a?(Array)
    @remove_cb = block
    @array = array
    @key_to_value = {}
    @value_to_key = {}
    @idx = 0
  end

  # Returns the value assigned to +key+ if present; otherwise assigns +key+ to
  # the next element in the ring for later lookup by #[].
  def next(key)
    return @key_to_value[key] if @key_to_value.include?(key)

    @array[@idx].tap { |v|
      if old_key = @value_to_key[v]
        @key_to_value.delete(old_key)
        @value_to_key.delete(v)
        @remove_cb.call(old_key, v) if @remove_cb
      end

      @key_to_value[key] = v
      @value_to_key[v] = key

      @idx = (@idx + 1) % @array.length
    }
  end

  # Retrieves the value assigned to +key+, or nil if expired or not set.
  def [](key)
    @key_to_value[key]
  end
end

jack = MB::Sound::JackFFI[]
midi_in = jack.input(port_type: :midi, port_names: ['midi_in'], connect: ARGV[0])
audio_out = jack.output(port_names: ['audio_out'], connect: [['system:playback_1', 'system:playback_2']])

OSCIL_COUNT = 4
oscil_bank = Ring.new(
  OSCIL_COUNT.times.map {
    MB::Sound::Oscillator.new(:ramp, frequency: 440, advance: Math::PI * 2 / audio_out.rate, range: -0.0..0.0)
  }
)

nib = Nibbler.new

filter = MB::Sound::Filter::Cookbook.new(:lowpass, audio_out.rate, 2400, quality: 4)

puts "\e[1;34mMaking \e[33mmusic\e[0m"

loop do
  nib.clear_buffer
  while event = midi_in.read(blocking: false)[0]
    event = nib.parse(event.bytes)
    event = [event] unless event.is_a?(Array)

    # TODO: Allow changing waveform
    event.each do |e|
      puts MB::Sound::U.highlight(e) unless e.is_a?(MIDIMessage::SystemRealtime)

      case e
      when MIDIMessage::NoteOn
        oscil_bank.next(e.note).trigger(e.note, e.velocity)

      when MIDIMessage::NoteOff
        oscil_bank[e.note]&.release(e.note, e.velocity)

      when MIDIMessage::ControlChange
        case e.index
        when 71
          # Filter resonance
          filter.quality = MB::Sound::M.scale(e.value, 0..127, 0.1..4.0)

        when 1, 74
          # Filter frequency
          decade = MB::Sound::M.scale(e.value, 0..127, 0..3)
          freq = 20.0 * 10.0 ** decade
          puts "Filter frequency: #{freq}"
          filter.center_frequency = freq
        end
      end
    end
  end

  frame = oscil_bank.map { |o| o.sample(audio_out.buffer_size) }.reduce(&:+)
  audio_out.write([filter.process(frame)])
end
