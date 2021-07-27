#!/usr/bin/env ruby
# Plots different window functions and their overlap
# Usage: bin/plot_windows.rb [window_length [hop]] [window and plot names]
# Usage: $0 [window names...] or $0 [window length] [window names...] or $0 [window_length hop_size] [window names...]
# e.g. bin/plot_windows.rb 2048 Hann dft

require 'rubygems'
require 'bundler/setup'

require 'pry'
require 'pry-byebug'

$LOAD_PATH << File.expand_path('../lib', __dir__)

require 'mb-sound'

if ARGV.include?('--help')
  puts MB::U.read_header_comment.join.gsub('$0', $0)
  exit 1
end

hop = nil
if ARGV[0] =~ /\A\d+\z/
  if ARGV[1] =~ /\A\d+\z/
    length, hop, *names = ARGV
    hop = hop.to_i
  else
    length, *names = ARGV
  end
  length = length.to_i
else
  length = 512
  names = ARGV
end

window_list = MB::Sound::Window::windows.select { |w|
  # delete will return nil if the window name wasn't present, or the window
  # name if it was.  Then the bang bang will convert that to true/false.
  #
  # After the loop finishes, the names should either be empty, or should
  !!names.delete(w.window_name)
}

# If only graph names were specified then the window list will be empty, so
# refill it (e.g. bin/windows.rb phase).
window_list = MB::Sound::Window::windows if window_list.empty?

plots = window_list.map { |c|
  name = c.name.rpartition('::').last
  w = c.new(length)
  w.force_hop(hop) if hop

  puts "#{name}: length=#{w.length} hop=#{w.hop}"

  # Overlap at least 4 full windows.
  n = 4 * w.length / w.hop
  puts "Overlapping #{n} times"
  ovl = w.gen_overlap(n).map { |t| t.round(8) } * w.overlap_gain
  pwrovl = w.gen_power_overlap(n).map { |t| t.round(8) } * w.overlap_gain

  # Zero-padding allows the FFT to show sub-bin detail
  expand = 32
  combined_window = w.pre_window || w.post_window
  combined_window *= w.post_window if w.pre_window && w.post_window
  padded = MB::M.rol(
    MB::M.zpad(
      combined_window,
      length * expand
    ),
    length * expand / -2
  )

  dft_cplx = MB::Sound.trunc_fft(padded, 50 * expand, false)
  dft = MB::Sound.trunc_fft(padded, 50 * expand, true)
  dft = dft - dft.max

  {
    "#{name} pre" => w.pre_window || [1],
    "#{name} post" => w.post_window || [1],
    "#{name} overlap" => ovl,
    "#{name} overlap-zoom" => ovl[(ovl.size * 7/16)..(ovl.size * 9/16)],
    "#{name} power-overlap" => pwrovl,
    "#{name} dft" => dft,
    "#{name} phase" => MB::Sound.unwrap_phase(dft_cplx),
  }.select { |p|
    names.empty? || names.include?(p.rpartition(' ').last)
  }
}

p = MB::M::Plot.new
begin
  loop do
    # Loop because gnuplot doesn't resize plots when the window is resized
    p.plot(plots.reduce(&:merge), columns: plots.first.size)
    break if ENV['PLOT_TERMINAL'] == 'dumb' # Allow testing
    sleep 5
  end
ensure
  p.close
end
