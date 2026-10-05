#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# Plots MB::Sound::Envelope curves and presets.
#
# Usage: $0 [options] [attack [decay [sustain [release]]]]
#
# Times are in seconds; omitted values come from the preset (see
# MB::Sound::EnvelopeMethods).  Without --gate the envelope is a one-shot
# that releases --hold seconds after it starts.  --print lists the
# segment boundaries and levels instead of plotting.
#
# Examples:
#     $0                                   # adsr defaults, :analog curves
#     $0 --compare 0.05 0.3 0.4 0.5        # every curve preset
#     $0 --curve 30 --db 80 0 1 0 1        # a 30 dB curve, plotted in dB
#     $0 --curve 0,60,60 --gate 0.2 --lift 0.9 0.1 0.2 0.5 0.4
#     $0 --preset filter_env --velocity 0.5 0.01 0.3 0 0.3
#     $0 --print 0.01 0.02 0.5 0.03
#     $0 --curve smooth --gate 2 1 0.5 0.6 1   # S-curves (the old smoothstep)
#     $0 --shape s --curve -12,0,12 1 0.5 0.6 1 # skewed S: swell, plain, fast-first
#     $0 --shape s,exp,exp --gate 0.4 1 0.5 0.6 1  # S attack released early
#
# In the console, the same S-curves:
#     play 110.hz.ramp * adsr(1, 0.5, 0.6, 1, shape: :s, hold: 2)
#     play 110.hz.ramp * adsr(1, 0.5, 0.6, 1, curve: :pad, hold: 2)
#     play 110.hz.ramp * adsr(1, 0.5, 0.6, 1, hold: 2).shape(attack: :s).curve(attack: -6)

require 'bundler/setup'
require 'mb-sound'

# Parses a --shape value: exp or s, or attack,decay,release shapes.
def parse_shape(text)
  return nil if text.nil?
  values = text.split(',').map(&:to_sym)
  values.length == 1 ? values[0] : values
end

# Parses a --curve value: a preset name, one number, or attack,decay,release.
def parse_curve(text)
  return nil if text.nil?
  return text.to_sym if text.match?(/\A[a-z_]+\z/)

  values = text.split(',').map { |v| Float(v) }
  values.length == 1 ? values[0] : values
end

# Samples +env+ until it ends (or +limit+ seconds), returning an SFloat.
def sample_all(env, limit)
  bufs = []
  total = 0
  while total < limit * env.sample_rate && (buf = env.sample(480))
    bufs << buf.dup
    total += buf.length
  end
  Numo::SFloat.zeros(0).concatenate(*bufs)
end

MB::Sound.script(
  args: 0..4,
  preset: ['adsr', '-p', 'Envelope preset', String, MB::Sound::Envelope::PRESETS.keys.map(&:to_s)],
  curve: [nil, '-c', String, "Curve: a preset (#{MB::Sound::Envelope::CURVES.keys.join(', ')}), dB, or attack,decay,release dB"],
  shape: [nil, '-s', String, 'Segment shape: exp or s (S-curve) for every segment, or attack,decay,release (e.g. s,exp,exp)'],
  hold: [nil, Float, 'Seconds from the start to the release (one-shots; default 2 * (attack + decay), at least 0.1)'],
  lift: [nil, Float, 'Release velocity (0..1; 0.5 leaves the release time alone, 0 doubles it, 1 halves it)', 0.0..1.0],
  gate: [nil, '-g', Float, 'Hold a gate for this many seconds instead of a one-shot'],
  velocity: [1.0, '-v', Float, 'Note velocity (0..1)', 0.0..1.0],
  compare: [false, 'Plot every curve preset (CURVES) with the same times'],
  db: [nil, Float, 'Plot in decibels over this range (e.g. 80)', 1.0..],
  terminal: [false, '-t', 'Plot in the terminal instead of a gnuplot window'],
  print: [false, 'Print segment boundaries and levels instead of plotting'],
) { |args, p|
  times = args.map { |v| Float(v) }
  names = [:attack, :decay, :sustain, :release]
  positional = names.zip(times).to_h.compact
  preset = p.preset.to_sym

  # Velocity needs a note start: a gate, or a one-sample trigger
  make = ->(curve) {
    opts = { velocity: p.velocity }
    opts[:hold] = p.hold if p.hold
    opts[:lift] = p.lift if p.lift
    if p.gate
      opts[:gate] = 1.constant.until(p.gate)
    elsif p.velocity != 1
      opts[:trigger] = 1.constant.until(1.samples)
    end
    opts[:curve] = curve if curve
    opts[:shape] = parse_shape(p.shape) if p.shape
    MB::Sound::Envelope.preset(preset, **positional, **opts)
  }

  envelope = make.(parse_curve(p.curve))
  limit = (envelope.attack_time || 0) + (envelope.decay_time || 0) + (p.gate || envelope.hold.to_f) + (envelope.release_time || 0) + 0.25

  if p.print
    # One sample at a time, printing each stage change
    puts envelope
    puts format('%-10s %10s %12s  %s', 'sample', 'seconds', 'output', 'stage')
    stage = nil
    count = 0
    while count < limit * envelope.sample_rate && (buf = envelope.sample(1))
      if envelope.stage != stage
        stage = envelope.stage
        puts format('%-10d %10.5f %12.6f  %s', count, count / envelope.sample_rate, buf[0], stage)
      end
      count += 1
    end
    puts "#{count} samples#{envelope.ended? ? ', ended' : ''}"
    next
  end

  plots = {}
  if p.compare
    MB::Sound::Envelope::CURVES.each_key do |name|
      plots[name] = sample_all(make.(name), limit)
    end
  else
    plots[:"#{preset} #{p.curve || 'default'}#{" #{p.shape}" if p.shape}"] = sample_all(envelope, limit)
  end

  length = plots.values.map(&:length).max
  plots.transform_values! { |d| d.length < length ? d.concatenate(Numo::SFloat.zeros(length - d.length)) : d }
  plots.transform_values! { |d| (20 * Numo::NMath.log10(d.clip(10 ** (-p.db / 20), nil))).clip(-p.db, nil) } if p.db

  MB::Sound.plotter(graphical: !p.terminal, width: 960, height: 540).plot(plots)

  unless p.terminal
    begin
      STDIN.readline
    rescue EOFError, Interrupt
    end
  end
}
