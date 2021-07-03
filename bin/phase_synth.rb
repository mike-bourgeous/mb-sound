#!/usr/bin/env ruby
# Synthesizes a stereo sine wave with periodic phase transitions between
# in-phase, out-of-phase, or between.  The final phase will play for 1 second
# unless a final delay is given.
#
# Delays between phases should be at least 100ms to account for phase
# transition time.  Phase should range from 0 to 180.
#
# Phase transition duration may be changed using the PHASE_TRANSITION
# environment variable, which should contain an integer number of samples.  The
# default transition duration is 480 samples.
#
# Example:
#     bin/phase_synth.rb /tmp/x.flac 300 0 1 45 1 90 1 135 1 180 1 135 1 90 1 45 1 0 1
#
# Output:
#     Frequency: 300.00Hz
#
#     Index   Start  Phase
#        0:       0   0.00
#        1:   47520  45.00
#        2:   95520  90.00
#        3:  143520 135.00
#        4:  191520 180.00
#        5:  239520 135.00
#        6:  287520  90.00
#        7:  335520  45.00
#        8:  383520   0.00
#        9:  431520    END
#
#     Wrote 431520 samples to /tmp/x.flac

require 'bundler/setup'

require 'benchmark'
require 'pry-byebug'

$LOAD_PATH << File.expand_path('../lib', __dir__)

require 'mb-sound'

USAGE = "\n\n#{MB::U.read_header_comment.join}\n(usage: #{$0} out_file frequency [initial_phase_deg [delay_s phase_deg [delay_s phase_deg... [delay_end]]]]"
RATE = 48000
PHASE_TRANSITION = ENV['PHASE_TRANSITION']&.to_i || 480
AMP_TRANSITION = 4800

(puts USAGE;exit) if ARGV.empty? || ARGV.include?('--help')

filename = ARGV[0]
raise "No or invalid output file given #{USAGE}" unless filename && File.directory?(File.dirname(filename))
output = MB::Sound::FFMPEGOutput.new(filename, rate: RATE, channels: 2)

freq = ARGV[1]&.to_f
raise "No or invalid frequency given #{USAGE}" unless freq && freq > 0

phases = []
phases << { start: 0, phase: (ARGV[2] || 0).to_f }
ARGV.shift(3)

puts "\n\e[36mFrequency: \e[1m#{'%.2f' % freq}Hz\e[0m"

samples = 0
while (delay, phase = ARGV.shift(2)).length >= 1
  start = (samples - PHASE_TRANSITION + delay.to_f * RATE).round
  start = samples if start < samples
  samples = start + PHASE_TRANSITION
  phases << {
    start: start,
    phase: phase&.to_f
  }
end

phases << { start: samples + RATE, phase: nil } unless phases.last[:phase].nil?

# TODO: print or highlight these during processing?
puts "\n\e[1;33mIndex \e[32m  Start  \e[34mPhase\e[0m"
phases.each_with_index do |p, idx|
  puts "\e[33m#{idx.to_s.rjust(4)}: \e[32m#{p[:start].to_s.rjust(7)} \e[34m#{(p[:phase] ? '%.2f' % p[:phase] : 'END').rjust(6)}\e[0m"
end

osc = MB::Sound::Oscillator.new(ENV['WAVE_TYPE']&.sub(/^:/, '')&.to_sym || :sine)
sample = 0
phase_idx = 0
prior_phase = phases[0][:phase]
data = [Numo::SFloat.zeros(phases.last[:start]), Numo::SFloat.zeros(phases.last[:start])]
while sample <= phases.last[:start] # XXX <= should be < but testing another condition
  amp = 0.25

  # Fade in at start
  if sample < AMP_TRANSITION
    amp *= MB::M.smootherstep(sample.to_f / AMP_TRANSITION)
  end

  # Fade out at end
  if phases[phase_idx + 1][:phase].nil? && sample >= phases[phase_idx + 1][:start] - AMP_TRANSITION
    amp *= MB::M.smootherstep((phases[phase_idx + 1][:start] - sample).to_f / AMP_TRANSITION)
  end

  # Transition between phases
  if phase_idx > 0 && sample < phases[phase_idx][:start] + PHASE_TRANSITION
    phase = MB::M.interp(prior_phase, phases[phase_idx][:phase], MB::M.smootherstep((sample - phases[phase_idx][:start]).to_f / PHASE_TRANSITION))
  else
    phase = phases[phase_idx][:phase]
  end

  # phase is divided by 360 for half phase in each channel
  base_phase = sample * freq * 2.0 * Math::PI / RATE
  data[0][sample] = amp * osc.oscillator((base_phase + phase * Math::PI / 360.0) % (2.0 * Math::PI))
  data[1][sample] = amp * osc.oscillator((base_phase - phase * Math::PI / 360.0) % (2.0 * Math::PI))

  sample += 1

  if sample >= phases[phase_idx + 1][:start]
    prior_phase = phase
    phase_idx += 1
    break if phases[phase_idx][:phase].nil?
  end
end

output.write(data)
output.close

puts "\nWrote \e[1m#{sample}\e[0m samples to \e[1m#{filename}\e[0m"
