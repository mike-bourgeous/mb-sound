#!/usr/bin/env ruby
# Synthesizer for episode 2

require 'bundler/setup'

require 'nibbler'

require 'mb-sound'
require 'mb-sound-jackffi'

# A ring/pool of objects (e.g. oscillators) to be used in FIFO order.  Error
# handling and better voice stealing left as an exercise for the reader.
class Ring
  extend Forwardable

  def_delegators :@array, :each, :map

  # Pass a block to be notified when an element is reused before being
  # released.
  def initialize(array, &block)
    raise 'Pass an Array' unless array.is_a?(Array)
    @remove_cb = block
    @array = array
    @available = array.dup
    @used = []
    @key_to_value = {}
    @value_to_key = {}
  end

  # Returns the value assigned to +key+ (e.g. a note number) if present;
  # otherwise assigns +key+ to the next element in the ring for later lookup by
  # #[].
  def next(key)
    if @key_to_value.include?(key)
      puts "Found existing oscillator for #{key}"
      return @key_to_value[key]
    elsif !@available.empty?
      puts "Found available oscillator for #{key} out of #{@available.length} available"
      value = @available.shift
      @key_to_value[key] = value
      @value_to_key[value] = key
      @used << value
      return value
    elsif !@used.empty?
      value = @used.shift
      old_key = @value_to_key[value]
      puts "Recycling oscillator from #{old_key} for #{key} out of #{@used.length} used"
      @key_to_value.delete(old_key)
      @value_to_key.delete(value)
      @remove_cb.call(old_key, value) if @remove_cb
      @used << value
      return value
    else
      raise 'BUG: both used and available are empty'
    end
  end

  # Retrieves the value assigned to +key+, or nil if expired/reused or not set.
  def [](key)
    @key_to_value[key]
  end

  # Returns the value associated with this +key+ to the pool, if it hasn't
  # already been recycled.
  def release(key)
    if @key_to_value.include?(key)
      puts "Releasing #{key}"
      value = @key_to_value[key]
      @used.delete(value)
      @key_to_value.delete(key)
      @value_to_key.delete(value)
      @available << value
      value
    else
      puts "There was no #{key} to release; maybe it was recycled"
      nil
    end
  end
end

jack = MB::Sound::JackFFI[]
midi_in = jack.input(port_type: :midi, port_names: ['midi_in'], connect: ARGV[0] || :physical)
output = jack.output(port_names: ['Synth', 'Impulse'], connect: :physical)

MB::Sound::Oscillator.tune_freq = 480
MB::Sound::Oscillator.tune_note = 71

OSC_COUNT = 8
osc_bank = Ring.new(
  OSC_COUNT.times.map { 240.hz.ramp.at(0).oscillator }
)
filter = 1500.hz.lowpass(quality: 4)

midi = Nibbler.new

loop do
  midi.clear_buffer
  while event = midi_in.read(blocking: false)[0]
    event = midi.parse(event.bytes)
    event = [event] unless event.is_a?(Array)

    event.each do |e|
      case e
      when MIDIMessage::NoteOn
        osc_bank.next(e.note).trigger(e.note, e.velocity)

      when MIDIMessage::NoteOff
        osc_bank.release(e.note)&.release(e.note, e.velocity)

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

  data = osc_bank.map { |osc| osc.sample(output.buffer_size) }.sum
  data = filter.process(data)
  output.write([data, filter.impulse_response(800)])
end
