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
oscil = MB::Sound::Oscillator.new(:triangle, frequency: 440, advance: Math::PI * 2 / audio_out.rate, range: -0.0..0.0)
nib = Nibbler.new

loop do
  nib.clear_buffer
  while event = midi_in.read(blocking: false)[0]
    event = nib.parse(event.bytes)
      
    if event.is_a?(Array)
      event.each do |e|
        puts MB::Sound::U.highlight(e)
        oscil.handle_midi(e)
      end
    else
      puts MB::Sound::U.highlight(event)
      oscil.handle_midi(event)
    end
  end

  audio_out.write([oscil.sample(audio_out.buffer_size)])
end
