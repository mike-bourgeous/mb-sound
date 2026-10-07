#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# Plots tweening curves (MB::Sound::Curve) in the terminal or a gnuplot window.
#
# Usage: $0 [options] [curve ...]
#
# Curves are names (see --list), with _in, _out, _in_out, or _out_in
# suffixes, a signed dB number (Envelope's curvature), or four bezier
# control values separated by commas.  --overshoot and --cycles go to every
# named curve that takes them.  --from/--to widen the x range to show how
# the curve shaper's --edges mode (GraphNode#ease) handles inputs outside
# 0..1.  --print lists values instead of plotting.
#
# Examples:
#     $0                                       # smoothstep, back, elastic, squiggle, bounce
#     $0 elastic squiggle --overshoot 0.4 --cycles 5
#     $0 bounce bounce_in_out anticipate
#     $0 --all --print                         # every named curve as a table
#     $0 30 -30 0.25,0.1,0.25,1                # dB curves and a CSS bezier
#     $0 --from -1 --to 3 --edges mirror sine_in steps
#     $0 -t elastic                            # in the terminal (default when no display)
#
# In bin/sound.rb:
#     Curve[:elastic, overshoot: 0.4].(0.5)
#     plot Curve[:bounce].map(Numo::DFloat.linspace(0, 1, 200))

require 'bundler/setup'
require 'mb-sound'

# Parses a curve argument: a name, a dB number, or bezier values.
def parse_curve(text, options)
  if text.match?(/\A-?[\d.]+(,-?[\d.]+){3}\z/)
    MB::Sound::Curve.bezier(*text.split(',').map { |v| Float(v) })
  elsif text.match?(/\A-?[\d.]+\z/)
    MB::Sound::Curve.db(Float(text))
  else
    begin
      MB::Sound::Curve.named(text, **options)
    rescue ArgumentError => e
      raise unless e.message.match?(/takes|no options/)
      MB::Sound::Curve.named(text) # options don't apply to this curve
    end
  end
end

MB::Sound.script(
  overshoot: [nil, '-o', Float, 'Overshoot for curves that take it (back, elastic, squiggle, bounce)', 0.0..1.0],
  cycles: [nil, '-c', Float, 'Cycles for curves that take them (elastic, squiggle, bounce, steps)', 0.0..100.0],
  from: [0.0, Float, 'Start of the x range'],
  to: [1.0, Float, 'End of the x range'],
  edges: [:clamp, Symbol, 'Edge mode outside 0..1', MB::Sound::GraphNode::CurveShaper::EDGES.keys],
  points: [401, '-n', Integer, 'Points to plot', 2..100_000],
  all: [false, '-a', 'Plot every named curve'],
  list: [false, '-l', 'List the curve names and exit'],
  print: [false, '-p', 'Print a table of values instead of plotting'],
  terminal: [false, '-t', 'Plot in the terminal instead of a gnuplot window'],
) { |args, p|
  if p.list
    MB::Sound::Curve.names.each { |n| c = MB::Sound::Curve[n]; puts format('%-14s %-30s %s', n, c, c.kind) }
    next
  end

  options = { overshoot: p.overshoot, cycles: p.cycles }.compact
  names = p.all ? MB::Sound::Curve.names.map(&:to_s) : args
  names = %w[smoothstep back elastic squiggle bounce] if names.empty?
  curves = names.to_h { |n| [n, parse_curve(n, options)] }

  x = Numo::DFloat.linspace(p.from, p.to, p.points)

  if p.print
    cols = Numo::DFloat.linspace(p.from, p.to, 11)
    puts format('%-30s %s  %s', 'curve', cols.to_a.map { |v| format('%6.2f', v) }.join(' '), 'min..max')
    curves.each_value do |c|
      lo, hi = c.extent
      vals = c.map_edges(cols, p.edges).to_a.map { |v| format('%6.3f', v) }.join(' ')
      puts format('%-30s %s  %.3f..%.3f', c, vals, lo, hi)
    end
    next
  end

  plots = curves.to_h { |_, c| [c.to_s, c.map_edges(x, p.edges)] }
  graphical = !p.terminal && ENV['DISPLAY'].to_s != ''
  MB::Sound.plotter(graphical: graphical, **(graphical ? { width: 960, height: 540 } : {})).plot(plots)

  if graphical
    begin
      STDIN.readline
    rescue EOFError, Interrupt
    end
  end
}
