#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# This is a simple algorithmically defined song that exercises several common
# parts of the GraphNode and Filter code, including processing with complex
# numbers.
#
# Music and code (C)2025 Mike Bourgeous
#
# Usage:
#     bin/songs/node_graph_benchmark.rb                # plays the song (3 minutes)
#     bin/songs/node_graph_benchmark.rb song.flac      # renders it to a file
#     bin/songs/node_graph_benchmark.rb --bench        # runs the benchmark (DURATION, LOOP_COUNT env vars)
#     bin/songs/node_graph_benchmark.rb --help         # all options

require 'bundler/setup'

require 'benchmark'

require 'mb-util'
require 'mb-sound'

# A one-shot envelope over the whole song: linear segments (close to the
# smoothstep ADSREnvelope this song was written with), releasing after the
# attack and decay like that envelope's auto release.
def song_envelope(attack, decay, sustain, release)
  MB::Sound::Envelope.new(
    attack: attack, decay: decay, sustain: sustain, release: release,
    hold: attack + decay, curve: :linear, sample_rate: 48000
  )
end

# Builds the song's graph, returning its left and right outputs and the
# envelopes (one-shots that start with the song).
def benchmark_song
  abenv = song_envelope(60, 30, 0.125, 90)

  a = 100.hz.complex_square.at(-13.db).filter(1500.hz.lowpass(quality: 0.5))
  b = 150.hz.ramp.at(-15.db).filter(2600.hz.lowpass(quality: 0.5))

  ab = (a + b).softclip(0.05, 0.2) * 3.db * 1.hz.drumramp.lfo.at(2..0.1).filter(30.hz.lowpass) * abenv

  cenv = song_envelope(90, 60, 1, 30)

  c = (
    266.66667.hz.triangle.at(-4.db).softclip(0.05, 0.5).filter(1900.hz.lowpass1p) * 0.1.hz.lfo.at(0..1) +
    250.hz.complex_triangle.at(-3.db).softclip(0.05, 0.5).filter(1900.hz.lowpass1p) * 0.1.hz.lfo.at(0..1).with_phase(0.5)
  ).softclip(0.05, 0.25) * 10.db * cenv

  denv = song_envelope(4, 170, 1, 6)

  d = (
    50.hz.triangle.at(-3.db).filter(150.hz.lowpass1p) *
    (10 ** (4.hz.drumramp.lfo.at(0..-30) / 20)).filter(50.hz.lowpass)
  ).softclip(0.005, 0.25) * 10.db * denv

  drumenv = song_envelope(10, 150, 1, 20)

  hat = 10000.hz.noise.filter(9000.hz.highpass).filter(15000.hz.lowpass) * 10 ** (8.hz.drumramp.lfo.at(-4..-25).filter(100.hz.lowpass) / 20)
  kick = 50.hz.at(-3.db).fm((10 ** (2.hz.drumramp.at(90.to_db..-60) / 20)).filter(100.hz.lowpass)) * (10 ** (2.hz.drumramp.at(0..-30) / 20)).filter(100.hz.lowpass)

  drums = (hat + kick) * drumenv

  graph = ((drums + ab + c + d) * -6.db).softclip(0.25, 0.99)

  envelopes = graph.graph.select { |n| n.is_a?(MB::Sound::Envelope) }

  m = graph.real
  s = graph.imag

  l = m + -6.db * s
  r = m - -6.db * s

  flanger_l = -4.db * l - -5.db * l.delay(seconds: 0.1.hz.triangle.lfo.at(0.001..0.008))
  final_l = flanger_l.softclip(0.5, 0.99)

  flanger_r = -4.db * r - -5.db * r.delay(seconds: 0.1.hz.triangle.lfo.with_phase(0.5).at(0.001..0.008))
  final_r = flanger_r.softclip(0.5, 0.99)

  [final_l, final_r, envelopes]
end

if ARGV.include?('--bench')
  MB::U.sigquit_backtrace

  duration = ENV['DURATION']&.to_f || 30
  loop_count = ENV['LOOP_COUNT']&.to_i

  MB::U.bench_csv(prefix: MB::U.ruby_info) do |bench|
    [100, 800, 4000].each do |bufsize|
      final_l = final_r = nil

      # Oscillators play forever, so each run builds a new graph
      bench.report("build @ #{bufsize}") do
        final_l, final_r, _ = benchmark_song
        final_l = final_l.with_buffer(bufsize)
        final_r = final_r.with_buffer(bufsize)
      end

      bench.report("bufsize=#{bufsize}") do
        buffers = (duration * 48000 / bufsize).ceil
        i = 0
        loop do
          x = final_l.sample(bufsize)
          y = final_r.sample(bufsize)

          break if x.nil? || y.nil?

          i += 1
          break if i == buffers || (loop_count && i == loop_count)
        end
      end
    end
  end
else
  MB::Sound.song_script(bars: 90) { # 3 minutes at 120 BPM
    final_l, final_r, _ = benchmark_song
    MB::Sound.bg(:song, [final_l.with_buffer(800), final_r.with_buffer(800)], fade: 0)
  }
end
