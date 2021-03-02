#!/usr/bin/env ruby
# Episode 2 of Code Sound & Surround
# Synthesizahh!!!

require 'bundler/setup'

require 'nibbler'
require 'forwardable'

require 'mb-sound'
require 'mb-sound-jackffi'

# A ring/pool of oscillators to be used in FIFO order.  Error handling and
# better voice stealing left as an exercise for the reader.
class OscPool
  extend Forwardable

  def_delegators :@array, :each, :map

  # Initializes an oscillator pool with the given array of oscillators.
  def initialize(array)
    raise 'Pass an array' unless array.is_a?(Array)

    @array = array
    @available = array.dup
    @used = []
    @key_to_value = {}
    @value_to_key = {}
  end

  # Retrieves the next available (or stolen) oscillator to play +key+.
  def next(key)
    if @key_to_value.include?(key)
      # Reusing the oscillator that's already playing this key
      return @key_to_value[key]
    elsif !@available.empty?
      # Using an unused oscillator
      value = @available.shift
      @key_to_value[key] = value
      @value_to_key[value] = key
      @used << value
      return value
    elsif !used.empty?
      # Stealing an oscillator already in use
      value = @used.shift
      old_key = @value_to_key[value]
      @key_to_value.delete(old_key)
      @value_to_key.delete(value)
      @used << value
      return value
    else
      raise 'BUG: both used and available are empty'
    end
  end

  # Adds the oscillator associated with this +key+ to the available pool and
  # returns the oscillator.  Returns nil if the oscillator was recycled.
  def release(key)
    if @key_to_value.include?(key)
      value = @key_to_value[key]
      @used.delete(value)
      @key_to_value.delete(key)
      @value_to_key.delete(value)
      @available << value
      value
    else
      nil
    end
  end
end

MB::Sound::Oscillator.tune_freq = 480
MB::Sound::Oscillator.tune_note = 71

jack = MB::Sound::JackFFI['EP2Synth']
midi_in = jack.input(port_type: :midi, port_names: ['midi_in'], connect: ARGV[0] || :physical)
output = jack.output(port_names: ['Synth', 'Impulse'], channels: 2, connect: :physical)

midi = Nibbler.new

OSC_COUNT = 8
osc_pool = OscPool.new(
  OSC_COUNT.times.map { 240.hz.ramp.at(0).oscillator }
)

filter = 1500.hz.lowpass(quality: 4)

loop do
  midi.clear_buffer

  while event = midi_in.read(blocking: false)[0]
    event = [midi.parse(event.bytes)].flatten

    event.each do |e|
      case e
      when MIDIMessage::NoteOn
        osc_pool.next(e.note).trigger(e.note, e.velocity)

      when MIDIMessage::NoteOff
        osc_pool.release(e.note)&.release(e.note, e.velocity)

      when MIDIMessage::ControlChange
        case e.index
        when 1
          decade = MB::Sound::M.scale(e.value, 0..127, 0..3)
          freq = 20.0 * 10.0 ** decade
          filter.center_frequency = freq
        end
      end
    end
  end

  data = osc_pool.map { |osc| osc.sample(output.buffer_size) }.sum
  data = filter.process(data)
  output.write([data, filter.impulse_response(output.buffer_size)])
end
