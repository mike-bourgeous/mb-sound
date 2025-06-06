#!/usr/bin/env ruby
# This is a simple algorithmically defined song that exercises several common
# parts of the GraphNode and Filter code, including processing with complex
# numbers.
#
# Music and code (C)2025 Mike Bourgeous
#
# Use --bench to run the benchmark, or no arguments to play the song.

require 'bundler/setup'

require 'benchmark'

require 'mb-util'
require 'mb-sound'

MB::U.sigquit_backtrace


abenv = MB::Sound::ADSREnvelope.new(attack_time: 60, decay_time: 30, sustain_level: 0.125, release_time: 90, sample_rate: 48000)

a = 100.hz.complex_square.forever.at(-13.db).filter(1500.hz.lowpass(quality: 0.5))
b = 150.hz.ramp.forever.at(-15.db).filter(2600.hz.lowpass(quality: 0.5))

ab = (a + b).softclip(0.05, 0.2) * 3.db * 1.hz.drumramp.lfo.at(2..0.1).filter(30.hz.lowpass) * abenv

cenv = MB::Sound::ADSREnvelope.new(attack_time: 90, decay_time: 60, sustain_level: 1, release_time: 30, sample_rate: 48000)

c = (
  266.66667.hz.triangle.forever.at(-4.db).softclip(0.05, 0.5).filter(1900.hz.lowpass1p) * 0.1.hz.lfo.at(0..1) +
  250.hz.complex_triangle.forever.at(-3.db).softclip(0.05, 0.5).filter(1900.hz.lowpass1p) * 0.1.hz.lfo.at(0..1).with_phase(Math::PI)
).softclip(0.05, 0.25) * 10.db * cenv

denv = MB::Sound::ADSREnvelope.new(attack_time: 4, decay_time: 170, sustain_level: 1, release_time: 6, sample_rate: 48000)

d = (
  50.hz.triangle.at(-3.db).forever.filter(150.hz.lowpass1p) *
  4.hz.drumramp.lfo.at(0..-30).db.filter(50.hz.lowpass)
).softclip(0.005, 0.25) * 10.db * denv

drumenv = MB::Sound::ADSREnvelope.new(attack_time: 10, decay_time: 150, sustain_level: 1, release_time: 20, sample_rate: 48000)

hat = 10000.hz.noise.filter(9000.hz.highpass).filter(15000.hz.lowpass) * 8.hz.drumramp.lfo.at(-4..-25).filter(100.hz.lowpass).db
kick = 50.hz.at(-3.db).fm(2.hz.drumramp.at(90.to_db..-60).db.filter(100.hz.lowpass)) * 2.hz.drumramp.at(0..-30).db.filter(100.hz.lowpass)

drums = (hat + kick) * drumenv

graph = ((drums + ab + c + d) * -6.db).softclip(0.25, 0.99)

envelopes = graph.graph.select { |n| n.is_a?(MB::Sound::ADSREnvelope) }

m, s = graph.for(180).tee

m1, m2 = m.real.tee
s1, s2 = s.imag.tee

l = m1 + -6.db * s1
r = m2 - -6.db * s2

final_l = l.tee.yield_self { |(x, y)|
  flanger = -4.db * x - -5.db * y.delay(seconds: 0.1.hz.triangle.lfo.at(0.001..0.008))
  flanger.softclip(0.5, 0.99)
}
final_r = r.tee.yield_self { |(x, y)|
  flanger = -4.db * x - -5.db * y.delay(seconds: 0.1.hz.triangle.lfo.with_phase(Math::PI).at(0.001..0.008))
  flanger.softclip(0.5, 0.99)
}

envelopes.each do |e|
  e.trigger(1, auto_release: true)
end

loop_count = ENV['LOOP_COUNT']&.to_i

if ARGV.include?('--bench')
  Benchmark.bmbm do |bench|
    [100, 800, 4000].each do |bufsize|
      # Reset envelopes
      bench.report("envs @ #{bufsize}") do
        envelopes.each do |e|
          e.trigger(1, auto_release: true)
        end
      end

      # Reset oscillators and constants
      bench.report("for(180) @ #{bufsize}") do
        final_l.for(180)
        final_r.for(180)
      end

      bench.report("bufsize=#{bufsize}") do
        i = 0
        loop do
          x = final_l.with_buffer(bufsize).sample(bufsize)
          y = final_r.with_buffer(bufsize).sample(bufsize)

          break if x.nil? || y.nil?

          i += 1
          break if loop_count && i == loop_count
        end
      end
    end
  end
elsif ARGV[0]
  overwrite = ARGV.delete('--overwrite')
  MB::U.prevent_overwrite(ARGV[0], prompt: true) unless overwrite

  MB::U.headline("Saving benchmark song to #{ARGV[0].inspect}")

  if loop_count
    # FIXME: MB::Sound::GraphNode::Tee has a buffer size of 48000
    MB::Sound.write(ARGV[0], [final_l, final_r].map { |c| c.with_buffer(800).sample(loop_count * 800) }, overwrite: true)
  else
    MB::Sound.write(ARGV[0], [final_l.with_buffer(800), final_r.with_buffer(800)], overwrite: true)
  end
else
  MB::Sound.play [final_l.with_buffer(800), final_r.with_buffer(800)]
end
