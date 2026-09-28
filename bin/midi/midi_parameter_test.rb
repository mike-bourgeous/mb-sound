#!/usr/bin/env ruby
# Tests assigning multiple parameters to a single MIDI message type.

require 'bundler/setup'

require 'mb-sound'
require 'mb-sound-jackffi'
require 'mb-util'

MB::U.sigquit_backtrace

jack = MB::Sound::JackFFI[]
manager = MB::Sound::MIDI::Manager.new(jack: jack, connect: ARGV[0] || :physical, channel: 0)

manager.on_bend(range: 0.0..0.5, description: 'First bend') do |b|
  puts "First pitch bend callback: #{b}\e[K"
end

manager.on_bend(range: 0.5..1.0, description: 'Second bend') do |b|
  puts "Second pitch bend callback: #{b}\e[K"
end

manager.on_cc(1, range: 10.0..20.0, description: 'First mod') do |mod|
  puts "First modwheel callback: #{mod}\e[K"
end

manager.on_cc(1, range: 0.0..-10.0, description: 'Second mod') do |mod|
  puts "Second modwheel callback: #{mod}\e[K"
end

manager.on_cc(1, range: 0.0..2.0, description: 'Third mod') do |mod|
  puts "Third modwheel callback: #{mod}\e[K"
end

manager.on_note_number(range: 0..1270, description: '10x note number') do |n|
  puts "Note number callback: #{n}\e[K"
end

manager.on_note_velocity(MB::Sound::C3.number, range: 0.0..1.0, filter_hz: 0.02) do |v|
  puts "Note velocity for C3 only: #{v}\e[K"
end

run = true
trap :INT do
  run = false
end

puts "\e[H\e[J"

begin
  while run do
    puts "\e[H"
    manager.update
  end
ensure
  puts MB::U.syntax(manager.to_acid_xml, :xml)
end
