#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# Checks live MIDI through RtMidi (MB::Sound::MIDI::Input/Output): prints the
# MIDI APIs, which one scripts would use and why, which libjack this process
# loaded, the audio backend scripts would use, and every API's sources and
# destinations; optionally prints incoming MIDI or sends a note around a
# loopback on each API.
#
# Usage: $0 [options]
#
# Examples:
#     $0                               # what scripts would use, and all ports
#     $0 --listen 10                   # print MIDI arriving at a virtual port
#     $0 --listen 10 -c jack-keyboard  # ...from a source (part of its name)
#     $0 --loopback                    # send a note to ourselves on each API
#     MIDI_API=jack $0 --listen 10     # JACK only
#
# Listing JACK ports when no JACK server answers prints libjack's connection
# errors; they're expected there.  MIDI_API and MIDI_DEVICE take precedence
# over --api and --connect, as in scripts.

require 'bundler/setup'
require 'mb-sound'

# Paths of shared libraries matching +pattern+ loaded in this process
# (Linux; nil elsewhere).
def loaded_libraries(pattern)
  return nil unless File.readable?('/proc/self/maps')
  File.foreach('/proc/self/maps').map { |l| l.split[5] }.compact.grep(pattern).uniq
end

def show_ports(api)
  sources = MB::Sound::MIDI::Input.port_names(api, :input)
  destinations = MB::Sound::MIDI::Input.port_names(api, :output)
  puts "  sources (#{sources.length}):"
  sources.each_with_index { |n, i| puts "    #{i}: #{n}" }
  puts "  destinations (#{destinations.length}):"
  destinations.each_with_index { |n, i| puts "    #{i}: #{n}" }
rescue MB::Sound::FastMIDI::Error, MB::Sound::FastAudio::Error => e
  puts "  unavailable: #{e.message}"
end

# Sends a note from a virtual output to an input connected to it on +api+,
# returning a description of the result.
def loopback(api)
  name = "loop#{rand(1 << 20)}"
  out = MB::Sound::MIDI::Output.new(api: api, port_name: name)
  input = MB::Sound::MIDI::Input.new(api: api, connect: name)
  return "the input didn't find our output #{name.inspect}" unless input.connected_to

  sleep 0.05
  start = MB::U.clock_now
  out.write([0x90, 60, 100])
  events = []
  while events.empty? && MB::U.clock_now - start < 2
    events.concat(input.read[0])
    sleep 0.002
  end

  if events.empty?
    "no message within 2 s (#{input.connected_to})"
  else
    "ok: #{events[0][1].bytes.map { |b| '%02x' % b }.join(' ')} in #{((MB::U.clock_now - start) * 1000).round(1)} ms via #{input.connected_to}"
  end
rescue MB::Sound::FastMIDI::Error, MB::Sound::FastAudio::Error, ArgumentError => e
  "failed: #{e.message}"
ensure
  input&.close
  out&.close
end

MB::Sound.script(
  args: 0,
  api: [nil, String, '-a', 'MIDI API for --listen (default: what scripts use)', %w[core alsa jack]],
  connect: [nil, String, '-c', 'Source for --listen (part of its name or an index; default: a virtual port)'],
  listen: [nil, Float, '-l', 'Seconds to print incoming MIDI', 0.1..86400],
  loopback: [false, 'Send a note through a virtual port on each API'],
) { |_args, p|
  fast = MB::Sound::FastMIDI
  apis = MB::Sound::MIDI::Input.apis
  client = MB::Sound::DeviceOutput.client_name

  puts "MIDI APIs: #{apis.join(', ')} (JACK through the shared client; RtMidi #{fast::RTMIDI_VERSION} for the rest)"
  puts "Platform: #{RUBY_PLATFORM}; client name: #{client}"
  %w[MIDI_API MIDI_DEVICE AUDIO_BACKEND JACK_DEFAULT_SERVER JACK_CLIENT_NAME LD_LIBRARY_PATH PIPEWIRE_RUNTIME_DIR XDG_RUNTIME_DIR].each do |var|
    puts "  #{var}=#{ENV[var]}" if ENV[var]
  end

  jack = MB::Sound::FastAudio.jack_server?
  puts "JACK server answers: #{jack ? 'yes' : 'no'} (a JACK client opened without starting a server)"
  if jack || apis.include?(:jack)
    libs = loaded_libraries(/libjack/)
    if libs
      libs = libs.map { |l| "#{l}#{" -> #{File.realpath(l)}" if File.symlink?(l)}" }
      puts "libjack loaded: #{libs.empty? ? 'none' : libs.join(', ')}"
      puts "  (a path under pipewire-0.3/jack is PipeWire's libjack; else probably JACK2's)" unless libs.empty?
    end

    if RUBY_PLATFORM =~ /linux/
      runtime = ENV['XDG_RUNTIME_DIR'] || "/run/user/#{Process.uid}"
      %w[pipewire-0 pulse/native].each do |s|
        path = File.join(runtime, s)
        puts "  #{path}: #{File.socket?(path) ? 'socket' : 'missing'}"
      end
      jackd = `pgrep -a -x 'jackd|jackdbus|pipewire' 2>/dev/null`.lines.map(&:strip)
      puts "  processes: #{jackd.empty? ? 'no jackd, jackdbus, or pipewire' : jackd.join('; ')}"
    end
  end

  puts "Scripts' MIDI API: #{MB::Sound::MIDI::Input.api}"

  begin
    backends = MB::Sound::DeviceOutput.backends
    puts "Scripts' audio backends: #{backends ? backends.join(', ') : "miniaudio's default order"}; " \
      "first working: #{MB::Sound::DeviceOutput.backend}"
  rescue MB::Sound::FastAudio::Error => e
    puts "Audio: #{e.message}"
  end

  apis.each do |api|
    puts
    puts "#{api}:"
    show_ports(api)
  end

  if p.loopback
    puts
    puts 'Loopback (virtual output to an input connected to it):'
    apis.each { |api| puts "  #{api}: #{loopback(api)}" }
  end

  if p.listen
    puts
    input = MB::Sound::MIDI::Input.new(api: p.api, connect: p.connect)
    where = input.connected_to || "#{input.connections.first}; connect a source to it"
    puts "Listening for #{p.listen} s on #{input.api} (#{where})..."

    start = MB::U.clock_now
    while MB::U.clock_now - start < p.listen
      input.read[0].each do |_t, bytes|
        puts format('%8.3f  %s', MB::U.clock_now - start, bytes.bytes.map { |b| '%02x' % b }.join(' '))
      end
      sleep 0.005
    end
    input.close
  end
}
