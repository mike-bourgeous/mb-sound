#!/usr/bin/env ruby
# A single-oscillator monophonic MIDI-controlled synthesizer.  Requires the
# mb-sound-jackffi gem.  This is a simple example that quantizes all MIDI
# events to audio buffer boundaries.
#
# Usage: ./bin/synth.rb [midi_port_to_connect]

require 'rubygems'
require 'bundler/setup'

Bundler.require

$LOAD_PATH << File.expand_path('../lib', __dir__)

require 'mb-sound-jackffi'
require 'mb/sound'

jack = MB::Sound::JackFFI[]
midi_in = jack.input(port_type: :midi, port_names: ['midi_in'], connect: ARGV[0])
audio_out = jack.output(port_names: ['audio_out'], connect: [['system:playback_1', 'system:playback_2']])
oscil = MB::Sound::Oscillator.new(:ramp, frequency: 440, advance: Math::PI * 2 / audio_out.rate, range: -0.0..0.0)
nib = Nibbler.new
filter = MB::Sound::Filter::Cookbook.new(:lowpass, audio_out.rate, 2400, quality: 0.707)

puts "\e[1;34mMaking \e[33mmusic\e[0m"

loop do
  nib.clear_buffer
  while event = midi_in.read(blocking: false)[0]
    event = nib.parse(event.bytes)
    event = [event] unless event.is_a?(Array)

    event.each do |e|
      puts MB::Sound::U.highlight(e) unless e.is_a?(MIDIMessage::SystemRealtime)

      oscil.handle_midi(e)

      if e.is_a?(MIDIMessage::ControlChange)
        case e.index
        when 71
          # Filter resonance
          filter.quality = MB::Sound::M.scale(e.value, 0..127, 0.1..4.0)

        when 74
          # Filter frequency
          decade = MB::Sound::M.scale(e.value, 0..127, 0..3)
          freq = 20.0 * 10.0 ** decade
          puts "Filter frequency: #{freq}"
          filter.center_frequency = freq
        end
      end
    end
  end

  audio_out.write([filter.process(oscil.sample(audio_out.buffer_size))])
end
