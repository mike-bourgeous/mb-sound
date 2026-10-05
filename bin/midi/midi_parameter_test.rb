#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# Tests assigning multiple parameters to a single MIDI message type: several
# MB::Sound::Notes controller nodes with different ranges on the same pitch
# bend and mod wheel, plus note number and velocity, printed live.  Prints
# the controller list (Notes#controls) on exit.
#
# Reads live MIDI (JACK or RtMidi; see MB::Sound::MIDI::Input); without an
# argument, connect a MIDI source to the port it creates.  Reads MIDI
# channel 1 only.
#
# Usage: $0 [part_of_a_midi_source_name]

require 'bundler/setup'

require 'mb-sound'
require 'mb-util'

MB::U.sigquit_backtrace

MB::Sound.script(args: 0..1) { |(port)|
  input = MB::Sound::MIDI::Input.open_live(port)
  source = MB::Sound::MIDI::LiveSource.new(input, timing: :asap)
  midi = MB::Sound::Notes.new(MB::Sound::MIDI::Stream.new(source).channel(0))

  # Several controller nodes on one controller, each with its own range
  nodes = {
    'First bend (0..0.5)' => midi.bend * 0.25 + 0.25,
    'Second bend (0.5..1)' => midi.bend * 0.25 + 0.75,
    'First mod (10..20)' => midi.cc(1, range: 10.0..20.0, name: 'First mod'),
    'Second mod (0..-10)' => midi.cc(1, range: 0.0..-10.0, name: 'Second mod'),
    'Third mod (0..2)' => midi.cc(1, range: 0.0..2.0, name: 'Third mod'),
    '10x note number' => midi.number * 10,
    'Note velocity, smoothed' => midi.velocity.smooth(0.5),
  }

  run = true
  trap :INT do
    run = false
  end

  puts "\e[H\e[J"

  # Reads a 10 ms buffer from every node in turn, paced by the wall clock
  buffer = 480
  start = MB::U.clock_now
  frames = 0

  begin
    while run
      values = nodes.transform_values { |n| n.sample(buffer)[-1] }

      puts "\e[H"
      values.each do |name, v|
        puts "#{name}: #{MB::M.sigfigs(v.to_f, 5)}\e[K"
      end

      frames += buffer
      delay = start + frames / 48000.0 - MB::U.clock_now
      sleep delay if delay > 0
    end
  ensure
    # TODO: print ACID XML here once the new ControlMap/ACID XML lands (branch
    # acid-xml); until then, the plain controller list from Notes#controls.
    puts
    puts 'Controllers:'
    midi.controls.each { |c| puts "  #{c}" }
    source.close
    input.close
  end
}
