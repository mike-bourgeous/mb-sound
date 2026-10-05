#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# A/B listening: plays before/after pairs of audio files, switching between them at the same position.
#
# Usage: $0 [options] DIR_OR_FILE [...]
#
# Pairs are found by name: NAME_before.EXT goes with NAME_after.EXT, or
# else NAME.EXT, in the same directory (any audio extension).  Directories
# are searched recursively; two files given alone that don't pair by name
# are compared as A and B.  A is "before", B is "after".  Other files
# (logs, READMEs) are ignored, but README.md items naming a pair (or its
# script, e.g. fm_bass for fm_bass_c_major) are shown when it plays.
#
# Examples:
#     $0 tmp/listening                     # every pair, both listening sets
#     $0 tmp/listening/synths -F fm_bass   # pairs whose names contain fm_bass
#     $0 --blind tmp/listening/clips       # X/Y in random order; ? reveals
#     $0 --auto 2 tmp/listening            # hands-free: switch every 2 s
#     $0 old.flac new.flac
#
# Keys (when stdin is a terminal):
#     space, tab    switch A/B (a or b picks one; x or y with --blind)
#     left/right    seek -/+ 2 s (h/l too; up/down or j/k seek 10 s)
#     0, home       back to the start of the pair
#     n, p          next/previous pair (enter: next)
#     m             level matching on/off (scales B to A's RMS)
#     L             loop on/off (off: go to the next pair at the end)
#     ?             reveal which is which (--blind)
#     q, ctrl-c     quit
#
# Switches crossfade over --crossfade ms.  The time shown is the playback
# position written to the sound card, about one output queue ahead of
# what you hear.  Output defaults to the :low latency profile (AUDIO_PROFILE
# or -L wins) so switches respond quickly.

require 'bundler/setup'
require 'io/console'
require 'mb-sound'

# One A/B pair of files, read on first use at the output's sample rate.
class ABPair
  AUDIO_EXTENSIONS = %w[flac wav ogg opus mp3 m4a aac aif aiff caf].freeze

  attr_reader :name, :a_path, :b_path

  # Finds pairs in the given directories and files (see the header).
  def self.find(paths)
    files = []
    paths.each do |p|
      if File.directory?(p)
        files.concat(Dir.glob(File.join(p, '**', '*')).select { |f| File.file?(f) && audio?(f) })
      elsif File.file?(p)
        files << p
      else
        raise ArgumentError, "Not found: #{p}"
      end
    end
    files = files.map { |f| File.expand_path(f) }.uniq.sort

    pairs = files.filter_map { |f|
      base = File.basename(f)
      m = base.match(/\A(.+)_before\.[^.]+\z/) or next
      dir = File.dirname(f)
      partner = %W[#{m[1]}_after #{m[1]}].lazy.filter_map { |stem|
        files.find { |g| File.dirname(g) == dir && g != f && File.basename(g).sub(/\.[^.]+\z/, '') == stem }
      }.first
      new(m[1], f, partner) if partner
    }

    if pairs.empty? && files.length == 2 && paths.none? { |p| File.directory?(p) }
      pairs << new(paths.map { |p| File.basename(p) }.join(' vs '), *paths.map { |p| File.expand_path(p) })
    end

    pairs
  end

  def self.audio?(path)
    AUDIO_EXTENSIONS.include?(File.extname(path).delete_prefix('.').downcase)
  end

  def initialize(name, a_path, b_path)
    @name = name
    @a_path = a_path
    @b_path = b_path
  end

  # Items (bullets, numbered items, table rows, paragraphs) from README.md
  # beside the files that name this pair, or else the longest underscore
  # prefix of its name with at least two parts (e.g. the script of
  # fm_bass_c_major), so the notes on what to listen for show with it.
  def notes
    readme = File.join(File.dirname(@a_path), 'README.md')
    return [] unless File.file?(readme)

    items = []
    code = false
    File.readlines(readme, chomp: true).each do |line|
      # Skip code blocks (fenced, or indented after a blank line)
      if line.start_with?('```')
        code = !code
        items << nil
      elsif code || (line.start_with?('    ') && items.last.nil?)
        items << nil
      elsif line.strip.empty? || line.start_with?('#')
        items << nil
      elsif line.match?(/\A\s*(?:[-*]|\d+\.|\|)\s/) || items.last.nil?
        items << line.strip
      else
        items[-1] += " #{line.strip}"
      end
    end
    items.compact!

    parts = @name.split('_')
    parts.length.downto([parts.length, 2].min) do |n|
      key = Regexp.escape(parts[0...n].join('_'))
      found = items.grep(/(?<!\w)#{key}(?!\w)/)
      return found.map { |i| i.gsub(/\s+/, ' ') } unless found.empty?
    end

    []
  end

  # Reads both files as stereo Numo::SFloat Arrays padded to the same
  # length, returning [a, b].
  def load(sample_rate)
    return @data if @data && @rate == sample_rate

    a, b = [@a_path, @b_path].map { |f|
      d = MB::Sound.read(f, sample_rate: sample_rate).map { |c| Numo::SFloat.cast(c) }
      d.length == 1 ? [d[0], d[0]] : d[0..1]
    }
    @lengths = [a[0].length, b[0].length]
    frames = @lengths.max
    a, b = [a, b].map { |d| d.map { |c| c.length < frames ? c.concatenate(Numo::SFloat.zeros(frames - c.length)) : c } }

    @rate = sample_rate
    @frames = frames
    @data = [a, b]
  end

  def frames
    @frames || 0
  end

  # RMS level in dB of [A, B] over both channels, each over its own length
  # (not the padding).
  def rms_db
    @rms_db ||= @data.zip(@lengths).map { |d, len|
      ms = len == 0 ? 0 : d.sum { |c| (c[0...len].cast_to(Numo::DFloat) ** 2).mean } / d.length
      ms > 0 ? 10 * Math.log10(ms) : -Float::INFINITY
    }
  end

  # Peak level in dB of [A, B].
  def peak_db
    @peak_db ||= @data.map { |d|
      peak = d.map { |c| c.abs.max }.max.to_f
      peak > 0 ? 20 * Math.log10(peak) : -Float::INFINITY
    }
  end
end

# Plays pairs, switching between A and B on key presses or a timer.
class ABPlayer
  SEEK_SHORT = 2.0
  SEEK_LONG = 10.0
  FADE_IN = 0.005

  def initialize(pairs, output:, crossfade:, blind:, auto:, loop:, match:, keys:, notes:)
    @notes = notes
    @pairs = pairs
    @output = output
    @rate = output.sample_rate
    @xfade_step = 1.0 / [(crossfade * @rate).round, 1].max
    @blind = blind
    @auto = auto
    @loop = loop
    @match = match
    @keys = keys
    @queue = Queue.new
  end

  def run
    @index = 0
    start_pair
    reader = start_key_reader if @keys

    until @quit
      handle_keys
      break if @quit
      write_buffer
    end
  ensure
    reader&.kill
    status_line(final: true) if @pair
  end

  private

  def start_pair
    @pair = @pairs[@index]
    @a, @b = @pair.load(@rate)
    @pos = 0
    @mix = 0.0 # 0 = A, 1 = B
    @target = 0.0
    @fade_in = (FADE_IN * @rate).round
    @switched_at = 0
    @revealed = !@blind
    # In blind mode X/Y are A/B in random order
    @flip = @blind ? rand < 0.5 : false
    @mix = @target = 1.0 if @flip

    a_rms, b_rms = @pair.rms_db
    @b_gain = (a_rms.finite? && b_rms.finite?) ? 10 ** ((a_rms - b_rms) / 20) : 1.0

    $stderr.print "\r\e[K" if @keys
    $stderr.puts pair_info
    if @notes
      @pair.notes.first(6).each do |n|
        $stderr.puts MB::U.wrap(n, width: [MB::U.width - 4, 40].max).lines.map { |l| "  \e[2m#{l.chomp}\e[0m" }
      end
    end
    status_line
  end

  def pair_info
    a_peak, b_peak = @pair.peak_db
    a_rms, b_rms = @pair.rms_db
    head = "\e[1m[#{@index + 1}/#{@pairs.length}] #{@pair.name}\e[0m  #{format('%.2f', @pair.frames.to_f / @rate)} s"
    return head if @blind

    [
      head,
      "  A: #{@pair.a_path}  peak #{db(a_peak)}  rms #{db(a_rms)}",
      "  B: #{@pair.b_path}  peak #{db(b_peak)}  rms #{db(b_rms)}  (#{format('%+.1f', b_rms - a_rms)} dB rms)",
    ].join("\n")
  end

  def db(v)
    v.finite? ? format('%.1f dB', v) : 'silent'
  end

  def label(which)
    return which == 0 ? 'A (before)' : 'B (after)' unless @blind

    xy = (which == 1) ^ @flip ? 'Y' : 'X'
    @revealed ? "#{xy} = #{which == 0 ? 'A (before)' : 'B (after)'}" : xy
  end

  def status_line(final: false)
    which = @target >= 0.5 ? 1 : 0
    flags = []
    flags << 'match' if @match
    flags << 'loop' if @loop
    flags << "auto #{@auto}s" if @auto
    text = format("%s  %6.2f / %.2f s  %s", label(which), @pos.to_f / @rate, @pair.frames.to_f / @rate, flags.join(' '))
    if @keys
      # Colored by what the label says (X/Y in blind tests), so color doesn't reveal A/B
      shown = @blind ? ((which == 1) ^ @flip ? 1 : 0) : which
      $stderr.print "\r\e[K\e[1;3#{shown == 0 ? 6 : 3}m▶ #{text}\e[0m"
      $stderr.print "\r\n" if final
    elsif final || @last_printed != which
      $stderr.puts "▶ #{text}"
    end
    @last_printed = which
  end

  # Writes one buffer of the current pair, advancing the position and the
  # A/B crossfade.
  def write_buffer
    count = @output.buffer_size
    frames = @pair.frames

    if @pos >= frames
      if @loop
        seek_to(0)
      else
        next_pair(1, wrap: false)
        return
      end
    end

    if @auto && @pos - @switched_at >= @auto * @rate
      switch_to(@target >= 0.5 ? 0.0 : 1.0)
    end

    n = [count, frames - @pos].min
    range = @pos...(@pos + n)

    # Per-sample mix ramp toward the target, then hold
    dir = @target <=> @mix
    ramp = (Numo::SFloat.new(n).seq(1) * (@xfade_step * dir) + @mix).clip(0, 1)
    @mix = ramp[-1].to_f
    b_gain = @match ? @b_gain : 1.0

    out = 2.times.map { |c|
      buf = @a[c][range] * (1 - ramp) + @b[c][range] * (ramp * b_gain)
      if @fade_in > 0
        k = [@fade_in, n].min
        buf[0...k] *= Numo::SFloat.new(k).seq(1) / (FADE_IN * @rate)
      end
      buf = buf.concatenate(Numo::SFloat.zeros(count - n)) if n < count
      buf
    }
    @fade_in = [@fade_in - n, 0].max

    @output.write(out)
    @pos += n
    status_line if @keys && (@pos / count) % 4 == 0
  end

  def switch_to(target)
    @target = target
    @switched_at = @pos
    status_line
  end

  def seek_to(frame)
    @pos = frame.clamp(0, [@pair.frames - 1, 0].max)
    @switched_at = @pos
    @fade_in = (FADE_IN * @rate).round
    status_line
  end

  def next_pair(step, wrap: true)
    i = @index + step
    if i >= @pairs.length || i < 0
      if wrap
        i %= @pairs.length
      else
        @quit = true
        return
      end
    end
    status_line(final: true)
    @index = i
    start_pair
  end

  def start_key_reader
    Thread.new do
      $stdin.raw do |io|
        loop do
          c = io.getc
          break if c.nil?
          if c == "\e"
            seq = +''
            begin
              seq << io.read_nonblock(2) while IO.select([io], nil, nil, 0.01)
            rescue IO::WaitReadable, EOFError
            end
            c += seq
          end
          @queue << c
          break if c == 'q' || c == "\x03"
        end
      end
    end
  end

  def handle_keys
    until @queue.empty?
      case @queue.pop
      when 'q', "\x03" then @quit = true; return
      when ' ', "\t" then switch_to(@target >= 0.5 ? 0.0 : 1.0)
      when 'a' then switch_to(0.0)
      when 'b' then switch_to(1.0)
      when 'x' then switch_to(@flip ? 1.0 : 0.0)
      when 'y' then switch_to(@flip ? 0.0 : 1.0)
      when "\e[C", 'l' then seek_to(@pos + (SEEK_SHORT * @rate).round)
      when "\e[D", 'h' then seek_to(@pos - (SEEK_SHORT * @rate).round)
      when "\e[A", 'k' then seek_to(@pos + (SEEK_LONG * @rate).round)
      when "\e[B", 'j' then seek_to(@pos - (SEEK_LONG * @rate).round)
      when '0', "\e[H", "\e[1~", "\eOH" then seek_to(0)
      when 'n', "\r", "\n" then next_pair(1)
      when 'p' then next_pair(-1)
      when 'm' then @match = !@match; status_line
      when 'L' then @loop = !@loop; status_line
      when '?'
        if @blind && !@revealed
          @revealed = true
          $stderr.print "\r\e[K"
          @blind = false
          $stderr.puts pair_info
          @blind = true
          status_line
        end
      end
    end
  end
end

MB::Sound.script(
  args: 1..,
  filter: [nil, String, '-F', 'Only pairs whose names contain this text (comma-separated alternatives)'],
  blind: [false, '-B', 'Blind test: label the files X and Y in random order (? reveals)'],
  auto: [nil, Float, '-a', 'Switch A/B every this many seconds and play each pair once (no keys needed)', 0.05..600.0],
  loop: [true, 'Loop each pair (--auto plays each pair once)'],
  match: [false, '-m', 'Start with level matching on (B scaled to A by RMS)'],
  crossfade: [10.0, Float, '-x', 'Crossfade time in milliseconds for switches', 0.0..1000.0],
  latency_profile: ['low', String, '-L', 'Latency profile (AUDIO_PROFILE wins)', %w[low default video safe]],
  notes: [true, 'Show README.md items that name each pair (what to listen for)'],
  list: [false, '-l', 'List the pairs and exit'],
) { |args, p|
  pairs = ABPair.find(args)
  if p.filter
    words = p.filter.split(',')
    pairs.select! { |pr| words.any? { |w| pr.name.include?(w) } }
  end
  if pairs.empty?
    $stderr.puts 'No before/after pairs found (NAME_before.EXT with NAME_after.EXT or NAME.EXT)'
    exit 1
  end

  if p.list
    pairs.each do |pr|
      puts "#{pr.name}\n  A: #{pr.a_path}\n  B: #{pr.b_path}"
    end
    next
  end

  keys = $stdin.tty?
  if keys
    $stderr.puts "\e[2mspace/tab switch  a/b pick  ←/→ ±2 s  ↑/↓ ±10 s  0 start  n/p pair  m match  L loop#{p.blind ? '  ? reveal' : ''}  q quit\e[0m"
  end

  output = MB::Sound.output(channels: 2, shared: false, profile: p.latency_profile.to_sym)
  begin
    ABPlayer.new(pairs, output: output, crossfade: p.crossfade / 1000.0, blind: p.blind, auto: p.auto, loop: p.loop && !p.auto, match: p.match, keys: keys, notes: p.notes).run
  ensure
    output.close
  end
}
