#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 MB_SOUND_YJIT=1 ruby
# Measures what YJIT buys and what running without it costs: startup, render cost, scene changes, Ruby hot spots.
#
# Written for the maintainer's question (2026-11-01): "If YJIT on mac
# native is slower than on Linux, we may need to explore more optimization
# to allow disabling JIT and using more C".  Run it natively on the Mac
# (the performance reference) and in a container, and compare the tables.
#
# Ruby fixes YJIT when it starts, so every measurement runs in a child
# process of this script started with MB_SOUND_YJIT=1 (YJIT at
# MB::Sound::JIT's call threshold, as the shebangs do) or MB_SOUND_YJIT=0
# (the interpreter), RUBY_YJIT_ENABLE unset, in alternating order (on,
# off, then off, on, ...) so drift on the machine falls on both.  Each
# child measures one thing:
#
# 1. Startup: bin/sound.rb's steps without starting Pry (requiring the
#    gems and Pry, requiring mb-sound and, inside it, its C extensions,
#    MB::Sound.warm_up, UI.warm_up, the console help), plus Ruby's own
#    boot (process start to the script's first line).
# 2. Render cost: a piece rendered offline through a non-realtime Session
#    (Session#process_buffer, plans on, loudness: false as live), each
#    buffer's time as a percentage of the buffer's duration: mean, p99,
#    and max (over 100% the buffer took longer than it plays), at each
#    buffer size.  Times leave out scheduled blocks (offline they run
#    inline; live they run on the scheduler thread), as
#    bin/scene_profile.rb does (whose hooks this script loads).
# 3. Scene changes, from the same renders: the slowest buffer where a
#    change landed, and the slowest scheduled block (a scene build, which
#    live runs on the scheduler thread); with YJIT on after the warm-ups a
#    live start does (MB::Sound.warm_up and the form's
#    Arrangement#warm_up), with YJIT off without them (play_form skips the
#    form warm-up without YJIT).
# 4. Profile (YJIT off): the Ruby methods with the most self time on the
#    render path, from a sampling thread reading the render thread's
#    backtrace (Thread#backtrace_locations whenever Ruby switches threads,
#    about every 10 ms whatever RUBY_THREAD_TIMESLICE says (Ruby 4.0); no
#    TracePoint).  A method's "self" share is its own Ruby plus the C
#    functions it calls directly ("in C", the C functions named: methods
#    without a source location), with its callers; the share of samples
#    in C functions (mb-sound's own and the rest) and self time by file
#    head each piece.  Ruby switches threads only at safe points (mostly
#    C function calls), so the shares are a coarse guide: tiny methods
#    can show several times their cost (Tuning.current's Thread.current,
#    59 calls of 0.19 us per 2.3 ms buffer of the dense piece, sampled at
#    6%, and making it free changed nothing measurable); confirm a
#    candidate with call counts or a microbenchmark before porting it.  GC
#    time doesn't show (the sampler can't run during GC; the GC column
#    says how much there was).  Scene builds (scheduled blocks) are
#    sampled apart.
#
# Pieces: tunnel_vision (bin/songs/tunnel_vision.rb), night_bus_flow,
# techno (genre(:techno).short: bin/songs/genre_demo.rb -G techno, about a
# minute), dense (spec/test_data/dense_modulated.mid, 8 busy voices with
# controllers and bend every 10 ms, through the :init preset with FM on);
# or the path of any song script.
#
# Prints one Markdown table per measurement (machine, Ruby, and YJIT at
# the top) to paste back, and writes the raw results to -o (JSON, written
# after every child, so an interrupted run keeps what finished) and the
# tables next to it (.md).  A full run (3 repeats) takes about an hour on
# the Mac container; --quick (one repeat, 8 bars per song, 4 s of the
# synth) about 10 minutes.  Run it while nothing else runs on the machine.
#
# Usage: $0 [options]
#
# Examples:
#     $0 -o tmp/jit_bench_mac.json                 # natively on the Mac
#     $0 --quick -o tmp/jit_bench_quick.json
#     $0 --pieces night_bus_flow,dense --buffers 128 -n 5
#     $0 --sections startup -n 10
#     $0 --pieces bin/songs/memory_card.rb --bars 32
#     $0 --sections profile --profile-buffer 512 --top 20

# A startup child: bin/sound.rb's steps, timed before anything else loads
# (the parent sets JIT_BENCH_CHILD=startup and JIT_BENCH_OUT=file)
if ENV['JIT_BENCH_CHILD'] == 'startup'
  jit_bench_first_line = Process.clock_gettime(Process::CLOCK_REALTIME)
  jit_bench_clock = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
  jit_bench_steps = {}
  jit_bench_step = ->(name, &block) {
    t = jit_bench_clock.()
    block.call
    jit_bench_steps[name] = jit_bench_clock.() - t
  }
  jit_bench_began = jit_bench_clock.()

  jit_bench_step.('require gems and Pry') do
    require 'rubygems'
    require 'bundler/setup'
    require 'benchmark'
    require 'io/console'
    require 'pry'
    require 'pry-byebug'
  end

  # Times mb-sound's C extensions, which lib/mb/sound.rb loads with
  # require_relative (resolved here against the caller's file, as Ruby
  # does)
  module JitBenchExtTimer
    @seconds = 0.0
    @count = 0

    class << self
      attr_accessor :seconds, :count
    end

    def require_relative(path)
      base = caller_locations(1, 1)[0]&.absolute_path
      return super unless base # (eval'd code: Ruby's own, unmeasured)

      full = File.expand_path(path, File.dirname(base))
      ext = !full.end_with?('.rb') && !File.exist?("#{full}.rb") && (File.exist?("#{full}.so") || File.exist?("#{full}.bundle"))
      return require(full) unless ext

      t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      begin
        require(full)
      ensure
        JitBenchExtTimer.seconds += Process.clock_gettime(Process::CLOCK_MONOTONIC) - t
        JitBenchExtTimer.count += 1
      end
    end
  end
  Kernel.prepend(JitBenchExtTimer)

  # (Bundler.require loads mb-sound, as in bin/sound.rb)
  jit_bench_step.('require mb-sound') { Bundler.require }
  jit_bench_steps['C extensions (inside require mb-sound)'] = JitBenchExtTimer.seconds
  jit_bench_step.('MB::Sound.warm_up') { MB::Sound.warm_up }
  jit_bench_step.('UI.warm_up') { MB::Sound::UI.warm_up }
  jit_bench_step.('console help') { require 'mb/sound/help' }
  jit_bench_steps['total (first line to ready)'] = jit_bench_clock.() - jit_bench_began

  require 'json'
  File.write(ENV.fetch('JIT_BENCH_OUT'), JSON.generate({
    kind: 'startup', first_line: jit_bench_first_line, steps: jit_bench_steps,
    extensions: JitBenchExtTimer.count,
    yjit: !!(defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?),
  }))
  exit
end

require 'bundler/setup'
require 'json'
require 'rbconfig'
require 'etc'
require 'tmpdir'
require 'fileutils'
require 'shellwords'
require 'mb-sound'

module JitBench
  ROOT = File.expand_path('..', __dir__)
  SCRIPT = File.expand_path(__FILE__)

  # Named pieces; any other name is a song script's path.
  PIECES = {
    'tunnel_vision' => { song: 'bin/songs/tunnel_vision.rb', args: [] },
    'night_bus_flow' => { song: 'bin/songs/night_bus_flow.rb', args: [] },
    'techno' => { song: 'bin/songs/genre_demo.rb', args: ['-G', 'techno'] },
    'dense' => { synth: :init, midi: 'spec/test_data/dense_modulated.mid', params: { fm: 0.5 } },
  }.freeze

  SECTIONS = %w[startup render profile].freeze

  # The longest render of a song without a length of its own.
  MAX_SONG_SECONDS = 600

  # The rows of the startup table, in order.
  STARTUP_ROWS = [
    'Ruby boot (process start to the first line)',
    'require gems and Pry',
    'require mb-sound',
    'C extensions (inside require mb-sound)',
    'MB::Sound.warm_up',
    'UI.warm_up',
    'console help',
    'total (first line to ready)',
  ].freeze

  module_function

  def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def median(values)
    v = values.compact.sort
    return nil if v.empty?
    v.length.odd? ? v[v.length / 2] : (v[v.length / 2 - 1] + v[v.length / 2]) / 2.0
  end

  def percentile(sorted, q) = sorted[(q * (sorted.length - 1)).round]

  # The piece's spec (from PIECES, or a song script's path).
  def piece(name)
    return PIECES.fetch(name) if PIECES.key?(name)
    path = File.expand_path(name, ROOT)
    raise ArgumentError, "Unknown piece #{name.inspect} (#{PIECES.keys.join(', ')}, or a song script's path)" unless File.file?(path)
    raise ArgumentError, "#{name} isn't a song script (song_script)" unless File.read(path).include?('song_script')
    { song: path, args: [] }
  end

  # Paths shortened for tables: relative to the repository, gems by name.
  def short_path(path)
    return '?' unless path
    path.delete_prefix("#{ROOT}/").sub(%r{\A.*/gems/([^/]+)/}, 'gems/\1/').sub(%r{\A.*/lib/ruby/[\d.]+/}, 'ruby/')
  end

  # -- Machine ---------------------------------------------------------

  def cpu_name
    if File.readable?('/proc/cpuinfo')
      File.read('/proc/cpuinfo')[/^model name\s*:\s*(.+)$/, 1]
    else
      `sysctl -n machdep.cpu.brand_string 2>/dev/null`.strip.then { |s| s.empty? ? nil : s }
    end || RbConfig::CONFIG['host_cpu']
  rescue SystemCallError
    RbConfig::CONFIG['host_cpu']
  end

  def os_name
    uname = `uname -srm 2>/dev/null`.strip
    mac = `sw_vers -productVersion 2>/dev/null`.strip if RUBY_PLATFORM.include?('darwin')
    text = mac && !mac.empty? ? "macOS #{mac} (#{uname})" : uname
    text += ', container' if File.exist?('/.dockerenv')
    text
  rescue SystemCallError
    RUBY_PLATFORM
  end

  def machine
    {
      cpu: cpu_name, cores: Etc.nprocessors, os: os_name, platform: RUBY_PLATFORM,
      ruby: RUBY_DESCRIPTION, ruby_cc: RbConfig::CONFIG['CC'], ruby_optflags: RbConfig::CONFIG['optflags'],
      yjit_support: !!defined?(RubyVM::YJIT) && RbConfig::CONFIG['YJIT_SUPPORT'] != 'no',
      yjit_threshold: Integer(ENV['MB_SOUND_YJIT_CALL_THRESHOLD'] || MB::Sound::JIT::CALL_THRESHOLD),
      git: (`git -C #{ROOT.shellescape} rev-parse --short HEAD 2>/dev/null`.strip rescue ''),
      date: Time.now.utc.strftime('%Y-%m-%d %H:%M UTC'),
    }
  end

  # -- Children (render and profile) ------------------------------------

  # Captures where render buffers and scheduled blocks run, for the
  # sampler (profile children only).
  module Sampler
    @where = nil
    @top = { render: Hash.new(0), build: Hash.new(0) }
    @owner = { render: Hash.new(0), build: Hash.new(0) }
    @owner_c = { render: Hash.new(0), build: Hash.new(0) }
    @cfuncs = { render: Hash.new { |h, k| h[k] = Hash.new(0) }, build: Hash.new { |h, k| h[k] = Hash.new(0) } }
    @callers = { render: Hash.new { |h, k| h[k] = Hash.new(0) }, build: Hash.new { |h, k| h[k] = Hash.new(0) } }
    @inclusive = { render: Hash.new(0), build: Hash.new(0) }
    @files = { render: Hash.new(0), build: Hash.new(0) }
    @in_c = Hash.new(0)
    @in_kernels = Hash.new(0)
    @totals = Hash.new(0)
    @thread = nil

    class << self
      attr_accessor :where

      def frame_key(loc) = "#{loc.label} (#{JitBench.short_path(loc.absolute_path || loc.path)})"

      # True if +locs[i]+ is a C function's frame (Ruby gives those their
      # caller's file and line, so the label decides: a method without a
      # source location is C).
      def cfunc?(locs, i)
        locs[i + 1] && c_label?(locs[i].label)
      end

      def c_label?(label)
        @c_labels ||= {}
        return @c_labels[label] if @c_labels.key?(label)
        @c_labels[label] =
          if label.start_with?('block ', '<', 'rescue in ', 'ensure in ') || !(m = label.match(/\A([A-Z][\w:]*)([#.])([^#.]+)\z/))
            false
          else
            mod = Object.const_get(m[1])
            meth = m[2] == '#' ? mod.instance_method(m[3]) : mod.method(m[3])
            meth.source_location.nil?
          end
      rescue NameError
        @c_labels[label] = false
      end

      # Samples the +main+ thread's backtrace on a thread of its own,
      # whenever Ruby switches to it (every time slice, about 10 ms).
      def start(main)
        @thread = Thread.new do
          Thread.current.name = 'jit_bench sampler'
          loop do
            sleep 0.0005
            where = @where
            next unless where
            locs = main.backtrace_locations(0, 400)
            next if locs.nil? || locs.empty? || @where != where

            @totals[where] += 1
            @top[where][frame_key(locs[0])] += 1
            i = 0
            i += 1 while cfunc?(locs, i)
            owner = frame_key(locs[i])
            @owner[where][owner] += 1
            @files[where][JitBench.short_path(locs[i].absolute_path || locs[i].path)] += 1
            @callers[where][owner][locs[i + 1].label] += 1 if locs[i + 1]
            if i > 0
              @owner_c[where][owner] += 1
              @cfuncs[where][owner][locs[i - 1].label] += 1
              @in_c[where] += 1
              # (mb-sound's own C: FastPlan, FastSynth, ...; the rest is
              # Ruby's core and Numo)
              @in_kernels[where] += 1 if locs[0, i].any? { |l| l.label.start_with?('MB::') }
            end
            locs.map { |l| frame_key(l) }.uniq.each { |k| @inclusive[where][k] += 1 }
          end
        end
      end

      def stop
        @thread&.kill
        @thread&.join
      end

      # Per place (:render, :build): the sample count, the Ruby methods
      # with the most self time (C functions they call directly folded in:
      # [method, self %, C %, [[C function, %], ...], [[caller, %], ...]]),
      # the top frames
      # as sampled, and the most inclusive time.
      def report(top)
        pct = ->(c, n) { (100.0 * c / n).round(2) }
        @totals.keys.to_h { |w|
          n = @totals[w]
          [w, {
            samples: n,
            in_c: pct.(@in_c[w], n), in_kernels: pct.(@in_kernels[w], n),
            files: @files[w].sort_by { |_, c| -c }.first(top).map { |k, c| [k, pct.(c, n)] },
            self: @owner[w].sort_by { |_, c| -c }.first(top).map { |k, c|
              [k, pct.(c, n), pct.(@owner_c[w][k], n), @cfuncs[w][k].sort_by { |_, cc| -cc }.first(3).map { |f, cc| [f, pct.(cc, n)] },
               @callers[w][k].sort_by { |_, cc| -cc }.first(2).map { |f, cc| [f, pct.(cc, n)] }]
            },
            top_frames: @top[w].sort_by { |_, c| -c }.first(top).map { |k, c| [k, pct.(c, n)] },
            inclusive: @inclusive[w].sort_by { |_, c| -c }.first(top * 3).map { |k, c| [k, pct.(c, n)] },
          }]
        }
      end
    end

    module SessionHook
      def process_buffer(...)
        old = Sampler.where
        Sampler.where = :render
        super
      ensure
        Sampler.where = old
      end
    end

    module SchedulerHook
      def run(...)
        old = Sampler.where
        Sampler.where = :build
        super
      ensure
        Sampler.where = old
      end
    end
  end

  # Runs one render (or profile) child as +spec+ (a Hash from the parent)
  # asks, returning its results.
  def run_render_child(spec)
    load File.join(ROOT, 'bin/scene_profile.rb') unless defined?(::SceneProfile)
    yjit = !!(defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?)
    buffer = spec.fetch('buffer')
    piece = spec.fetch('piece')
    profile = spec['profile']

    SceneProfile.install
    # (with YJIT the warm-up a live start does; without, what play_form
    # does live: no form warm-up)
    SceneProfile.form_warm_up = yjit ? true : nil
    MB::Sound::Arrangement.prepend(SceneProfile::FormWarmUp)
    MB::Sound::ScriptRunner.prepend(SceneProfile::SongCapture)
    if profile
      MB::Sound::Session.prepend(Sampler::SessionHook)
      MB::Sound::Session::Scheduler.prepend(Sampler::SchedulerHook)
    end

    song = nil
    if piece['song']
      song = File.expand_path(piece['song'], ROOT)
      ARGV.replace(piece['args'] + ['-q'])
      program = $PROGRAM_NAME
      $PROGRAM_NAME = song
      runner, song_bars, block = catch(:scene_profile_song) { load song; nil }
      $PROGRAM_NAME = program
      raise ArgumentError, "#{song} isn't a song script (song_script)" unless block
      # (songs without a length, such as genre_demo's short form, play to
      # their end: the render stops once every sound has ended)
      bars = spec['bars'] || song_bars
    end

    warm_up = MB::Sound.warm_up(midi: !song) # (as live scripts do: synth scripts warm MIDI voices too)
    SceneProfile.buffer_size = buffer
    SceneProfile.realtime = false
    # (scene_profile's own hooks compile on a throwaway Session first)
    begin
      box = MB::Sound::Session.new(realtime: false, output: SceneProfile::CountingOutput.new(buffer), buffer_size: buffer, channels: 2,
        transport: MB::Sound::Sequence::Transport.new(bpm: 120))
      MB::Sound::Session.with_context(session: box) do
        box.add(0.constant, on: :now)
        60.times { box.process_buffer }
      end
    ensure
      box&.close
      SceneProfile.buffers.clear
    end

    quiet = File.open(File::NULL, 'w')
    out = SceneProfile::CountingOutput.new(buffer)
    gc0 = GC.stat.slice(:minor_gc_count, :major_gc_count, :time, :total_allocated_objects)
    y0 = SceneProfile.yjit
    Sampler.start(Thread.current) if profile
    t0 = clock
    begin
      $stdout = quiet
      if song
        length = bars ? { bars: bars } : { max_seconds: MAX_SONG_SECONDS }
        MB::Sound.render(out, **length, buffer_size: buffer, loudness: false) {
          SceneProfile.recording(:setup) { runner.send(:arrange_song, &block) }
        }
      else
        seconds = spec['seconds'] || MB::Sound::MIDI::MIDIFile.new(File.join(ROOT, piece['midi'])).music_end.ceil
        params = piece['params'].to_h.transform_keys(&:to_sym)
        MB::Sound.render(out, seconds: seconds, buffer_size: buffer, loudness: false) {
          MB::Sound.bg(:dense, MB::Sound.preset(piece['synth'].to_sym, midi: MB::Sound.midi_file(File.join(ROOT, piece['midi'])), **params))
        }
      end
    ensure
      $stdout = STDOUT
      Sampler.stop if profile
    end
    wall = clock - t0
    gc = GC.stat.slice(:minor_gc_count, :major_gc_count, :time, :total_allocated_objects).to_h { |k, v| [k, v - gc0[k]] }

    buffers = SceneProfile.buffers
    raise 'jit_bench: no render buffers were profiled (scene_profile\'s SessionHook found no CountingOutput)' if buffers.empty?
    buffer_ms = buffer * 1000.0 / 48000
    secs = buffers.map { |b| b[:secs] }.sort
    cpu = buffers.map { |b| b[:cpu] }.sort
    landing = buffers.select { |b| b[:landed] > 0 }
    worst_landing = landing.max_by { |b| b[:secs] }
    blocks = SceneProfile.blocks.select { |b| b[:secs] }
    worst_block = blocks.max_by { |b| b[:secs] }
    yd = SceneProfile.ydelta(y0, SceneProfile.yjit)

    result = {
      kind: profile ? 'profile' : 'render', piece: spec['name'], buffer: buffer, yjit: yjit, threshold: MB::Sound::JIT.threshold,
      bars: bars, buffers: buffers.length, buffer_ms: buffer_ms, wall_s: wall,
      music_s: buffers.length * buffer / 48000.0,
      mean_ms: secs.sum * 1000 / secs.length, p50_ms: percentile(secs, 0.5) * 1000,
      p99_ms: percentile(secs, 0.99) * 1000, max_ms: secs.last * 1000,
      cpu_mean_ms: cpu.sum * 1000 / cpu.length, cpu_p99_ms: percentile(cpu, 0.99) * 1000,
      worst_buffer_bar: buffers.max_by { |b| b[:secs] }[:bar],
      landing: {
        buffers: landing.length,
        max_ms: worst_landing && worst_landing[:secs] * 1000, max_bar: worst_landing&.[](:bar),
        mean_ms: landing.empty? ? nil : landing.sum { |b| b[:secs] } * 1000 / landing.length,
      },
      blocks: {
        count: blocks.length, total_ms: blocks.sum { |b| b[:secs] } * 1000,
        max_ms: worst_block && worst_block[:secs] * 1000, max_desc: worst_block&.[](:desc), max_bar: worst_block&.[](:bar),
      },
      warm_up_s: warm_up, form_warm_up_s: SceneProfile.warmed&.last,
      gc: gc, gc_ms_per_s: gc[:time] / (buffers.length * buffer / 48000.0),
      yjit_compile_ms: yd[:compile_time_ns] && yd[:compile_time_ns] / 1e6,
      rss_mb: rss_mb,
    }
    result[:profile] = Sampler.report(spec['top'] || 15) if profile
    result
  end

  def rss_mb
    status = File.read('/proc/self/status')
    status[/^VmHWM:\s+(\d+) kB/, 1].to_i / 1024.0
  rescue SystemCallError
    `ps -o rss= -p #{Process.pid}`.to_i / 1024.0
  end

  # -- Parent ------------------------------------------------------------

  class Runner
    attr_reader :results

    def initialize(p, out_path)
      @p = p
      @out_path = out_path
      @md_path = out_path.sub(/\.json\z/, '') + '.md'
      @dir = Dir.mktmpdir('jit_bench')
      @results = { machine: JitBench.machine, options: options_hash, startup: [], render: [], profile: [], failures: [] }
      @count = 0
    end

    def options_hash
      { repeats: repeats, buffers: buffers, pieces: pieces, sections: sections, bars: bars, seconds: seconds,
        profile_buffer: @p.profile_buffer, quick: @p.quick }
    end

    def repeats = @p.quick ? 1 : @p.repeats
    def buffers = @p.buffers.split(',').map { |v| Integer(v) }
    def pieces = @p.pieces.split(',').map(&:strip)
    def sections = @p.sections.split(',').map(&:strip)
    def bars = @p.bars || (@p.quick ? 8 : nil)
    def seconds = @p.seconds || (@p.quick ? 4 : nil)

    # Children with YJIT on (MB::Sound::JIT's threshold) or off; the
    # environment otherwise as this process has it, without the switches
    # that would start YJIT at boot.
    def env(yjit, extra = {})
      rubyopt = ENV['RUBYOPT'].to_s.split.reject { |o| o.start_with?('--yjit') || o == '-rbundler/setup' }.join(' ')
      {
        'MB_SOUND_YJIT' => yjit ? '1' : '0', 'RUBY_YJIT_ENABLE' => nil, 'RUBYOPT' => rubyopt,
        'RUBY_THREAD_TIMESLICE' => '10', 'BUNDLE_GEMFILE' => ENV['BUNDLE_GEMFILE'] || File.join(ROOT, 'Gemfile'),
      }.merge(extra)
    end

    # Runs a child, returning its parsed result or nil (with the failure
    # recorded and its log's tail printed).
    def child(label, yjit, spec, extra_env = {})
      @count += 1
      out = File.join(@dir, "child_#{@count}.json")
      log = File.join(@dir, "child_#{@count}.log")
      kind = spec == 'startup' ? 'startup' : JSON.generate(spec)
      e = env(yjit, extra_env.merge('JIT_BENCH_CHILD' => kind, 'JIT_BENCH_OUT' => out))
      $stderr.print format('[%d/%d] %s, YJIT %s... ', @count, @total, label, yjit ? 'on' : 'off')
      spawned = Process.clock_gettime(Process::CLOCK_REALTIME)
      t0 = JitBench.clock
      pid = Process.spawn(e, RbConfig.ruby, SCRIPT, chdir: ROOT, in: File::NULL, out: log, err: [:child, :out])
      begin
        _, status = Process.wait2(pid)
      rescue Interrupt
        Process.kill('TERM', pid) rescue nil
        Process.wait(pid) rescue nil
        raise
      end
      elapsed = JitBench.clock - t0
      unless status.success? && File.exist?(out)
        tail = File.exist?(log) ? File.readlines(log).last(15).join : ''
        $stderr.puts "FAILED (#{status})\n#{tail}"
        @results[:failures] << { label: label, yjit: yjit, status: status.to_s, log: tail }
        return nil
      end
      r = JSON.parse(File.read(out))
      r['process_s'] = elapsed
      r['spawned'] = spawned
      r['yjit_requested'] = yjit
      if yjit && !r['yjit']
        @results[:yjit_missing] = true
      end
      $stderr.puts format('%.1f s%s', elapsed, r['mean_ms'] ? format(' (mean %.1f%% of realtime)', 100 * r['mean_ms'] / r['buffer_ms']) : '')
      r
    end

    def total_children
      n = 0
      n += 2 * repeats if sections.include?('startup')
      n += 2 * repeats * pieces.length * buffers.length if sections.include?('render')
      n += pieces.length if sections.include?('profile')
      n
    end

    def run
      pieces.each { |n| JitBench.piece(n) } # (unknown names fail before anything runs)
      @total = total_children
      $stderr.puts "jit_bench: #{@total} child processes; raw results in #{@out_path}"
      repeats.times do |r|
        order = r.even? ? [true, false] : [false, true]
        if sections.include?('startup')
          order.each do |yjit|
            res = child('startup', yjit, 'startup')
            next unless res
            res['steps']['Ruby boot (process start to the first line)'] = res['first_line'] - res['spawned']
            @results[:startup] << res
            save
          end
        end
        next unless sections.include?('render')
        pieces.each do |name|
          buffers.each do |buffer|
            order.each do |yjit|
              res = child("#{name} at #{buffer}", yjit, render_spec(name, buffer))
              @results[:render] << res if res
              save
            end
          end
        end
      end
      if sections.include?('profile')
        pieces.each do |name|
          res = child("#{name} at #{@p.profile_buffer} (profile)", false, render_spec(name, @p.profile_buffer).merge('profile' => true, 'top' => @p.top))
          @results[:profile] << res if res
          save
        end
      end
      save
      markdown
    ensure
      FileUtils.rm_rf(@dir) if @dir
    end

    def render_spec(name, buffer)
      { 'name' => name, 'piece' => JitBench.piece(name).transform_keys(&:to_s), 'buffer' => buffer, 'bars' => bars, 'seconds' => seconds }
    end

    def save
      FileUtils.mkdir_p(File.dirname(@out_path))
      File.write(@out_path, JSON.pretty_generate(@results))
      File.write(@md_path, JitBench.markdown(JSON.parse(JSON.generate(@results))))
    end

    def markdown = JitBench.markdown(JSON.parse(JSON.generate(@results)))

    def md_path = @md_path
  end

  # -- Report --------------------------------------------------------------

  def fmt(v, digits = 1) = v.nil? ? '-' : format("%.#{digits}f", v)
  def ratio(off, on) = off && on && on > 0 ? format('%.2fx', off / on) : '-'

  # The Markdown report of +r+ (results as parsed JSON: String keys).
  def markdown(r)
    m = r['machine']
    o = r['options']
    lines = []
    lines << "## jit_bench: #{m['cpu']} (#{m['cores']} threads)"
    lines << ''
    lines << "- #{m['os']}; #{m['ruby']}"
    lines << "- YJIT: #{m['yjit_support'] ? "built in (Ruby #{RUBY_VERSION}), MB_SOUND_YJIT=1 at call threshold #{m['yjit_threshold']}" : 'NOT AVAILABLE in this Ruby (the on columns ran without it)'}; Ruby built with #{m['ruby_cc']} #{m['ruby_optflags']}"
    lines << "- mb-sound #{m['git']}, #{m['date']}; #{o['repeats']} repeat#{o['repeats'] == 1 ? '' : 's'} alternating YJIT on and off (medians)#{o['quick'] ? ', --quick' : ''}"
    lines << '- WARNING: YJIT did not start in the YJIT-on children' if r['yjit_missing']
    lines << ''

    unless r['startup'].empty?
      on = r['startup'].select { |x| x['yjit_requested'] }
      off = r['startup'].reject { |x| x['yjit_requested'] }
      lines << '### Startup (bin/sound.rb steps without Pry; seconds)'
      lines << ''
      lines << '| step | YJIT on | YJIT off | off/on |'
      lines << '|---|---:|---:|---:|'
      STARTUP_ROWS.each do |row|
        a = median(on.map { |x| x['steps'][row] })
        b = median(off.map { |x| x['steps'][row] })
        lines << "| #{row} | #{fmt(a, 2)} | #{fmt(b, 2)} | #{ratio(b, a)} |"
      end
      lines << ''
    end

    groups = r['render'].group_by { |x| [x['piece'], x['buffer']] }
    unless groups.empty?
      lines << "### Render cost (% of realtime per buffer: offline Session#process_buffer, plans on#{o['bars'] ? ", songs #{o['bars']} bars" : ', whole songs'})"
      lines << ''
      lines << '| piece | frames | on mean | off mean | off/on | on p99 | off p99 | on max | off max | GC ms/s on/off | music s |'
      lines << '|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|'
      groups.each do |(piece, buffer), runs|
        on = runs.select { |x| x['yjit_requested'] }
        off = runs.reject { |x| x['yjit_requested'] }
        pct = ->(set, key) { median(set.map { |x| 100.0 * x[key] / x['buffer_ms'] }) }
        a = pct.(on, 'mean_ms')
        b = pct.(off, 'mean_ms')
        lines << "| #{piece} | #{buffer} | #{fmt(a)}% | #{fmt(b)}% | #{ratio(b, a)} | #{fmt(pct.(on, 'p99_ms'))}% | #{fmt(pct.(off, 'p99_ms'))}% | " \
          "#{fmt(pct.(on, 'max_ms'), 0)}% | #{fmt(pct.(off, 'max_ms'), 0)}% | #{fmt(median(on.map { |x| x['gc_ms_per_s'] }), 0)}/#{fmt(median(off.map { |x| x['gc_ms_per_s'] }), 0)} | #{fmt(median(runs.map { |x| x['music_s'] }), 0)} |"
      end
      lines << ''

      lines << '### Scene changes (ms: the slowest buffer where a change landed, the slowest scheduled block; YJIT on after the live warm-ups)'
      lines << ''
      lines << '| piece | frames | buffer ms | landings | on landing max | off landing max | on block max | off block max | slowest block | warm-ups on (s) |'
      lines << '|---|---:|---:|---:|---:|---:|---:|---:|---|---:|'
      groups.each do |(piece, buffer), runs|
        on = runs.select { |x| x['yjit_requested'] }
        off = runs.reject { |x| x['yjit_requested'] }
        land = ->(set) { median(set.map { |x| x['landing']['max_ms'] }) }
        blk = ->(set) { median(set.map { |x| x['blocks']['max_ms'] }) }
        desc = (off.first || on.first)&.dig('blocks', 'max_desc')
        warm = median(on.map { |x| x['warm_up_s'].to_f + x['form_warm_up_s'].to_f })
        lines << "| #{piece} | #{buffer} | #{fmt(runs.first['buffer_ms'], 2)} | #{runs.first['landing']['buffers']} | #{fmt(land.(on))} | #{fmt(land.(off))} | " \
          "#{fmt(blk.(on))} | #{fmt(blk.(off))} | #{desc ? desc[0, 24] : '-'} | #{fmt(warm, 2)} |"
      end
      lines << ''
    end

    unless r['profile'].empty?
      lines << "### YJIT off: Ruby methods with the most self time (sampled; a method's share includes the C functions it calls directly)"
      r['profile'].each do |x|
        prof = x['profile'] || {}
        render = prof['render']
        next unless render
        lines << ''
        lines << format('#### %s at %d frames: %.1f%% of realtime, %d samples on the render path, GC %.0f ms/s', x['piece'], x['buffer'], 100.0 * x['mean_ms'] / x['buffer_ms'], render['samples'], x['gc_ms_per_s'])
        lines << ''
        if render['in_c']
          lines << format('In C functions: %.0f%% of the samples (mb-sound\'s own extensions %.0f%%, Ruby core and Numo the rest); the rest is Ruby.', render['in_c'], render['in_kernels'])
          lines << ''
          lines << "Self time by file: #{render['files'].first(10).map { |f, v| "`#{f}` #{fmt(v, 0)}%" }.join(', ')}"
          lines << ''
        end
        lines << '| self % | in C | Ruby method (file) | C functions it calls (%) | called from (%) |'
        lines << '|---:|---:|---|---|---|'
        list = ->(fs) { fs.to_a.map { |f, fv| "`#{f}` #{fmt(fv)}" }.join(', ') }
        render['self'].each { |k, v, c, fs, callers| lines << "| #{fmt(v)} | #{fmt(c)} | `#{k}` | #{list.(fs)} | #{list.(callers)} |" }
        # (the frames every sample has, and the benchmark's own, left out)
        incl = render['inclusive'].reject { |k, v| v >= 95 || k.match?(%r{bin/(jit_bench|scene_profile)\.rb}) }.first(8)
        lines << ''
        lines << "Inclusive (the subtrees): #{incl.map { |k, v| "`#{k.sub(/ \(.*\)\z/, '')}` #{fmt(v, 0)}%" }.join(', ')}"
        build = prof['build']
        if build && build['samples'] > 0
          lines << ''
          lines << "Scene builds (scheduled blocks, #{build['samples']} samples), self: #{build['self'].first(6).map { |k, v| "`#{k.sub(/ \(.*\)\z/, '')}` #{fmt(v, 0)}%" }.join(', ')}"
        end
      end
      lines << ''
    end

    unless r['failures'].empty?
      lines << "### Failures: #{r['failures'].map { |f| "#{f['label']} (YJIT #{f['yjit'] ? 'on' : 'off'}): #{f['status']}" }.join('; ')}"
      lines << ''
    end
    lines.join("\n")
  end
end

if MB::Sound.main_script?(__FILE__)
  if (spec = ENV.delete('JIT_BENCH_CHILD'))
    # A render or profile child (see JitBench::Runner#child)
    result = JitBench.run_render_child(JSON.parse(spec))
    File.write(ENV.fetch('JIT_BENCH_OUT'), JSON.generate(result))
    exit
  end

  MB::Sound.script(
    args: 0,
    repeats: [3, Integer, '-n', 'Repeats of each measurement (alternating YJIT on and off)', 1..100],
    quick: [false, '-Q', 'One repeat, 8 bars per song and 4 s of the synth (about 10 minutes)'],
    pieces: [JitBench::PIECES.keys.join(','), String, '-p', "Comma-separated pieces: #{JitBench::PIECES.keys.join(', ')}, or song script paths"],
    buffers: ['128,512', String, '-b', 'Comma-separated buffer sizes in frames'],
    sections: [JitBench::SECTIONS.join(','), String, '-S', 'Comma-separated measurements: startup, render (render cost and scene changes), profile (YJIT off)'],
    bars: [nil, Integer, 'Bars of each song (default: whole songs; 8 with --quick)', 1..],
    seconds: [nil, Float, 'Seconds of the synth piece (default: its MIDI file; 4 with --quick)', 0.5..],
    profile_buffer: [128, Integer, 'Buffer size of the profile runs', 16..8192],
    top: [15, Integer, '-t', 'Methods listed per profile', 1..100],
    output: ['tmp/jit_bench.json', String, '-o', 'Raw results (JSON; the tables go next to it as .md)'],
  ) { |_args, p|
    p.buffers.split(',').each { |v| Integer(v) }
    (p.sections.split(',') - JitBench::SECTIONS).then { |bad| raise ArgumentError, "Unknown sections #{bad.join(', ')} (#{JitBench::SECTIONS.join(', ')})" unless bad.empty? }
    out = File.expand_path(p.output)
    runner = JitBench::Runner.new(p, out)
    text = runner.run
    puts text
    puts
    puts "(raw results in #{out}, the tables in #{runner.md_path})"
  }
end
