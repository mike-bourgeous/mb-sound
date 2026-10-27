module MB
  module Sound
    module UI
      # One-shot offline renders of a track's patch for the sound-design
      # screen's RENDER pane (sound-design-ui-2; design/notes/sound_design_ui.md):
      # "a one-shot render of the processed waveform updated periodically
      # when parameters change" (maintainer, 2026-10-26).
      #
      # What renders: one note (the clip's first note, else a guess from
      # the track's role: .input) through a fresh instance of the track's
      # patch, built by calling its patch block again (the code the live
      # track built its graph with, so the same sound) in a throwaway
      # Session (a sandbox like Arrangement#warm_up's: the session's tempo,
      # meter, key, tuning, and copies of every knob), for the first
      # PatchRender.seconds (half a second by default).
      #
      # Cost (round 2, the maintainer's goal: no dropouts): a render Server
      # process, forked once per patch and note (never per knob turn),
      # builds the instance there (a build is ~100 ms of Ruby, which in this
      # process held the GVL against the live render thread), and answers
      # each render by forking a copy of the never-sampled instance that
      # sets the knobs, renders, and writes the figures back; so every
      # render starts from the same fresh state, and this process only
      # writes a request and reads the answer.  Where fork is missing (or
      # PatchRender.fork is false, and in the UI specs' inline mode) each
      # render builds its own instance in-process instead, checking once per
      # patch and note that a second build shares no node with the first (a
      # patch reaching nodes made outside it would advance them; in a
      # forked copy they advance only there).
      #
      # Builds and in-process renders use their own random seeds
      # (Internal.with_private_rng: the live set's seed draws are
      # untouched), live mode off on their thread (Internal.strictly: a
      # patch's mistakes are the result, not warnings), and major GCs held
      # off (GCQuiet).  The work happens on a Worker thread at low priority,
      # never on the painter or render thread and never under the render
      # lock; a Driver (one per pane placement, ticked by the pane on the
      # painter thread) decides when to render with a Debounce and keeps the
      # newest result.
      module PatchRender
        # How much of the note a render plays by default (seconds;
        # PatchRender.seconds=).
        SECONDS = 0.5

        # Render lengths allowed (seconds).
        SECONDS_RANGE = (0.1..20.0)

        # The quiet time after the last change before a render starts.
        DEBOUNCE = 0.1

        # While changes keep coming (a held sweep), a render starts at most
        # this long after the first change it hasn't rendered.
        SWEEP = 0.2

        # The seed the instance's build starts the root generator from, and
        # the seed the render itself starts it from (renders differ only by
        # what changed).
        SEED = 0
        RENDER_SEED = 1

        # Frames per buffer of an offline render.
        BUFFER = 256

        # The share of wall time an in-process Worker render may take (it
        # sleeps after each buffer for the rest; PatchRender.duty=); forked
        # renders run at full speed in their own process.
        DUTY = 0.5

        # Columns of the min/max envelope kept per render (enough for a
        # 236-column terminal's Braille dots).
        ENVELOPE = 1024

        # Points of a render's spectrum (the pane's spectrum view).
        SPECTRUM_POINTS = 256

        # A Worker thread with nothing to do for this long ends, closing its
        # instance (a new request starts another).
        IDLE = 10.0

        # A forked render taking longer than this is killed (seconds).
        FORK_TIMEOUT = 10.0

        # The note a render plays when the track has no clip (or p asks for
        # the guess): the first row whose words match the track's name or
        # its graph's code (the preset or patch it plays) wins.  +hold+ is
        # the note's length as a share of the render.
        ROLES = [
          { role: :kick, words: /kick|bd\b|808_kick/, note: 36, hold: 0.25 },
          { role: :drums, words: /drum|perc|snare|hat|clap|tr808|tr909|kit/, note: 38, hold: 0.25 },
          { role: :bass, words: /bass|reese|sub\b|wobble|acid/, note: 33, hold: 0.6 },
          { role: :pad, words: /pad|string|choir|drone|swell|ambient/, note: 48, hold: 0.9 },
          { role: :pluck, words: /pluck|keys|piano|bell|mallet|marimba|tine|arp/, note: 60, hold: 0.3 },
          { role: :lead, words: /lead|solo|vox|vocal|melody/, note: 67, hold: 0.6 },
        ].freeze

        # The guess when no role matches.
        DEFAULT_ROLE = { role: :default, note: 48, hold: 0.6 }.freeze

        # The inspected track's patch and what a render needs from the
        # live session (gathered by Poll; nothing here is read from the
        # session again): +track+ the player name, +patch+ the track's
        # patch block (nil for a graph track: +note+ says why there is no
        # render), +clip+ the track's clip (nil: a guessed note), +bpm+,
        # +bar_length+, +key+ (a MusicalKey), +tuning+, +channels+,
        # +sample_rate+, +words+ (the track's name and its graph's code, for
        # the role guess).
        Source = Data.define(:track, :patch, :clip, :bpm, :bar_length, :key, :tuning, :channels, :sample_rate, :note, :words) do
          def initialize(words: nil, **rest) = super(words: words, **rest)
        end

        # What a render plays: +clip+ (a one-note Clip, or a Kit as given),
        # +kind+ (:clip_note, :kit, or :guess), +role+ (the guessed role, or
        # nil), +text+ (for the pane: "first note A1", "bass guess A1"), +id+
        # (a value that is equal when the input is the same).
        Input = Data.define(:clip, :kind, :role, :text, :id)

        # One render request: +seq+ (increasing), +key+ (what decides
        # whether a render is current: Driver.key_of), +source+, +input+ (an
        # Input), +knobs+ (frozen [name, value, Knob::Spec] rows for the
        # sandbox), +seconds+.
        Job = Data.define(:seq, :key, :source, :input, :knobs, :seconds) do
          # What decides whether an instance can render this job: the patch,
          # the input, and the transport's settings (not the knob values).
          def instance_key
            s = source
            [s.patch.object_id, input.id, s.bpm, s.bar_length, s.key, s.tuning.object_id, s.channels, s.sample_rate].freeze
          end
        end

        # A finished render: +seq+ and +key+ of its Job, +track+, +lo+ and
        # +hi+ (frozen SFloat min/max envelopes over every channel, ENVELOPE
        # columns), +frames+, +sample_rate+, +peak+ (dBFS), +rms+ (dBFS),
        # +lufs+ (integrated, -Infinity for silence or renders under 400 ms),
        # +ms+ (wall time of the render, with the instance's build when it
        # was built for it), +input+ (the Input's text), +spectrum+
        # ([frequencies, dB] frozen DFloats, or nil), +how+ (:fork or
        # :inline), +error+ (why there is no audio, or nil).
        Result = Data.define(:seq, :key, :track, :lo, :hi, :frames, :sample_rate, :peak, :rms, :lufs, :ms, :input, :spectrum, :how, :error)

        # A built, never-sampled patch instance (see PatchRender; a
        # Server's, or an in-process render's): +key+
        # (Job#instance_key), +box+ (its sandbox Session), +out+ (the
        # CaptureOutput), +ms+ (build time), +error+ (why it couldn't be
        # built, or nil).
        Instance = Struct.new(:key, :box, :out, :ms, :error, keyword_init: true) do
          def close
            box&.close
            self.box = nil
          end
        end

        @seconds = SECONDS
        @inline = false
        @clock = nil
        @duty = Float(ENV['MB_SOUND_RENDER_DUTY'] || DUTY)
        @fork = Process.respond_to?(:fork) && ENV['MB_SOUND_RENDER_FORK'] != '0'

        class << self
          # The length of each render (seconds).
          attr_reader :seconds

          # True: Drivers render on the calling thread (InlineWorker), for
          # specs and the golden captures.
          attr_accessor :inline

          # True (the default where Process.fork exists;
          # MB_SOUND_RENDER_FORK=0 off): Workers render in forked processes
          # from one instance per patch and note.
          attr_accessor :fork

          # The share of wall time an in-process Worker render may take
          # (0 < duty <= 1; 1: no pauses, only Thread.pass).
          attr_reader :duty

          def duty=(d)
            raise ArgumentError, "duty is a share of wall time, 0 < duty <= 1 (got #{d.inspect})" unless d.is_a?(Numeric) && d > 0 && d <= 1
            @duty = d.to_f
          end

          # The clock renders time themselves with (seconds; nil for
          # MB::U.clock_now; the golden captures fix it).
          attr_accessor :clock

          # Sets the length of each render (seconds within SECONDS_RANGE).
          def seconds=(s)
            unless s.is_a?(Numeric) && SECONDS_RANGE.cover?(s.to_f)
              raise ArgumentError, "Render lengths are #{SECONDS_RANGE.begin}..#{SECONDS_RANGE.end} seconds (got #{s.inspect})"
            end
            @seconds = s.to_f
          end

          # What +source+'s render plays (an Input): the first note of the
          # track's clip (its value, velocity, length, and marks, from the
          # start), a Kit as it is (its first hits), or with +guess+ (or no
          # clip) the note of the track's role (ROLES, from Source#words)
          # held for its share of +seconds+.
          def input(source, seconds, guess: false)
            clip = source.clip
            if !guess && clip.respond_to?(:rows)
              return Input.new(clip: clip, kind: :kit, role: nil, text: 'the kit', id: [:kit, clip.object_id].freeze)
            end
            if !guess && clip.respond_to?(:events)
              ev = first_note(clip)
              if ev
                one = ev.dup
                one.start = 0r
                one.probability = nil
                one.condition = nil
                c = Sequence::Clip.new([one])
                name = note_name(ev.value)
                return Input.new(clip: c, kind: :clip_note, role: nil, text: "first note #{name}".freeze,
                                 id: [:note, ev.value, ev.length, ev.velocity, ev.accented, ev.slid, ev.pitch].freeze)
              end
            end
            row = role_of(source.words)
            wn = Rational((seconds * row[:hold] * source.bpm.to_f / 240).round(4).to_s)
            ev = Sequence::Event.new(start: 0r, length: wn, value: row[:note], velocity: 0.8)
            Input.new(clip: Sequence::Clip.new([ev]), kind: :guess, role: row[:role], text: "#{row[:role]} guess #{note_name(row[:note])}".freeze,
                      id: [:guess, row[:role], wn].freeze)
          end

          # The ROLES row for +words+ (a String; nil: DEFAULT_ROLE).
          def role_of(words)
            text = words.to_s.downcase
            ROLES.find { |r| r[:words].match?(text) } || DEFAULT_ROLE
          end

          # Renders +job+ (a Job) and returns a Result.  +cache+ is a Hash the
          # caller keeps between jobs: with +fork+ it holds the Instance
          # (built when the job's instance_key changes), else the
          # self-contained checks per patch and input.  +pace+ (in-process
          # Worker renders) sleeps after each buffer to keep to
          # PatchRender.duty.  Never raises.
          def render(job, cache: {}, fork: false, pace: false)
            t0 = now
            fork ? render_served(job, cache, t0) : render_inline(job, cache, pace, t0)
          rescue Exception => e # rubocop:disable Lint/RescueException (a patch's SystemStackError or NotImplementedError is its result too)
            raise if e.is_a?(Interrupt) || e.is_a?(SystemExit)
            failed(job, t0, "#{e.class}: #{e.message}".lines.first.chomp)
          end

          # [lo, hi]: the min and max of every channel of +data+ (SFloats)
          # in +columns+ equal spans (frozen SFloats).
          def envelope(data, columns = ENVELOPE)
            n = data.map(&:length).min.to_i
            lo = Numo::SFloat.zeros(columns)
            hi = Numo::SFloat.zeros(columns)
            return [lo.freeze, hi.freeze] if n == 0
            columns.times do |i|
              a = i * n / columns
              b = [(i + 1) * n / columns, a + 1].max
              b = [b, n].min
              lo[i] = data.map { |d| d[a...b].min }.min
              hi[i] = data.map { |d| d[a...b].max }.max
            end
            [lo.freeze, hi.freeze]
          end

          private

          # Builds a fresh instance for +job+ (renders it here once), never
          # sampled before.
          def render_inline(job, cache, pace, t0)
            src = job.source
            return failed(job, t0, src.note || 'no patch to rebuild') if src.patch.nil?
            inst = build(job, check: cache)
            return failed(job, t0, inst.error) if inst.error
            data = nil
            Internal.strictly do
              GCQuiet.during { data = play(inst, job.knobs, job.seconds, src.sample_rate, pace) }
            end
            finish(job, t0, data, :inline)
          ensure
            inst&.close
          end

          # Renders +job+ through the cached Server (started first if the job
          # needs another instance).
          def render_served(job, cache, t0)
            src = job.source
            return failed(job, t0, src.note || 'no patch to rebuild') if src.patch.nil?
            server = cache[:server]
            unless server&.key == job.instance_key && server.alive?
              server&.close
              server = cache[:server] = Server.new(job)
            end
            payload = server.render(job)
            ms = (now - t0) * 1000
            if payload.is_a?(String)
              server.close
              cache.delete(:server)
              return failed(job, t0, payload, ms: ms)
            end
            result_of(job, payload, ms, :fork)
          end

          # (Server process) Builds the instance for +job+, then answers each
          # render request read from +jobs+ with a frame on +results+, from a
          # forked copy of the never-sampled instance; leaves without exit
          # hooks when +jobs+ closes (the parent closed it, or ended).
          def serve(job, jobs, results)
            Process.setpriority(Process::PRIO_PROCESS, 0, 10) rescue nil
            $stdout.reopen(File::NULL)
            $stderr.reopen(File::NULL)
            inst = build(job, check: nil)
            warm(job) if defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled? && !inst.error
            loop do
              msg = Server.read_frame(jobs, nil) or break
              knobs, seconds = msg
              if inst.error
                Server.write_frame(results, inst.error)
                next
              end
              rd, wr = IO.pipe
              pid = Process.fork do
                rd.close
                begin
                  GC.disable # (no marking pass copying every heap page)
                  data = Internal.strictly { play(inst, knobs, seconds, job.source.sample_rate, false) }
                  Server.write_frame(wr, figures(data, job.source.sample_rate))
                rescue Exception => e # rubocop:disable Lint/RescueException
                  Server.write_frame(wr, "#{e.class}: #{e.message}".lines.first.chomp) rescue nil
                ensure
                  exit!(0)
                end
              end
              wr.close
              payload = Server.read_frame(rd, FORK_TIMEOUT)
              Process.kill(:KILL, pid) rescue nil if payload.nil?
              Process.wait(pid) rescue nil
              rd.close
              Server.write_frame(results, payload || 'the render process ended without a result')
            end
          rescue Exception # rubocop:disable Lint/RescueException
            nil
          ensure
            exit!(0)
          end

          # A sandbox and the patch's graph built in it, added (plans
          # installed, never sampled), as an Instance.  With +check+ (a Hash),
          # the first build of a patch and input also builds a second one and
          # refuses a patch whose builds share a node.
          def build(job, check:)
            t0 = now
            src = job.source
            box = nil
            err = nil
            Internal.strictly do
              GCQuiet.during do
                Internal.with_private_rng(SEED) do
                  box, out = sandbox(job)
                  graph = Session.with_context(session: box) { src.patch.call(job.input.clip) }
                  if graph.nil?
                    err = 'the patch made nothing to play'
                  elsif check
                    key = [src.patch, job.input.id]
                    ok = check.fetch(key) { check.clear if check.length >= 8; check[key] = self_contained?(job, box, graph) }
                    err = 'the patch reads nodes made outside it (shared with the live graph): no render' unless ok
                  end
                  box.add(graph, on: :now) unless err
                  return Instance.new(key: job.instance_key, box: box, out: out, ms: ((now - t0) * 1000).round(1), error: err)
                end
              end
            end
          rescue Exception => e # rubocop:disable Lint/RescueException
            raise if e.is_a?(Interrupt) || e.is_a?(SystemExit)
            box&.close
            Instance.new(key: job.instance_key, box: nil, out: nil, ms: ((now - t0) * 1000).round(1), error: "#{e.class}: #{e.message}".lines.first.chomp)
          end

          # (Server process, with YJIT) Builds and renders a second instance
          # once, so the render's code is compiled here and every forked
          # copy inherits it (each copy compiling it again made a 0.5 s
          # dnb_reese render take ~480 ms instead of ~55).
          def warm(job)
            w = build(job, check: nil)
            play(w, job.knobs, job.seconds, job.source.sample_rate, false) unless w.error
          rescue StandardError
            nil
          ensure
            w&.close
          end

          # Sets +inst+'s knobs to +knobs+ ([name, value, ...] rows; exact
          # jumps before its first frame) and renders +seconds+: the
          # captured channels.
          def play(inst, knobs, seconds, rate, pace)
            box = inst.box
            have = box.knobs
            knobs.each do |name, value, _|
              k = have[name] or next
              k.set(value, frame: 0, smooth: 0)
            end
            frames = (seconds * rate).round
            rest = pace ? (1 - @duty) / @duty : 0
            Internal.with_private_rng(RENDER_SEED) do
              (frames.to_f / BUFFER).ceil.times do
                t = MB::U.clock_now
                box.process_buffer
                rest > 0 ? sleep((MB::U.clock_now - t) * rest) : Thread.pass
              end
            end
            inst.out.captured(frames)
          end

          # True if a second build of the patch shares no node with +graph+
          # (see PatchRender).
          def self_contained?(job, box, graph)
            other, = sandbox(job)
            second = Session.with_context(session: other) { job.source.patch.call(job.input.clip) }
            a = nodes_of(box, graph)
            b = nodes_of(other, second)
            a.each_key.none? { |n| b.include?(n) }
          ensure
            other&.close
          end

          def nodes_of(box, graph)
            set = {}.compare_by_identity
            box.send(:to_nodes, graph).each { |o| [o, *o.graph].each { |n| set[n] = true unless n.is_a?(Numeric) } }
            set
          end

          # A throwaway Session and its CaptureOutput for +job+ (see
          # PatchRender).
          def sandbox(job)
            src = job.source
            transport = Sequence::Transport.new(bpm: src.bpm, bar_length: src.bar_length)
            transport.reset_key(src.key) if src.key
            out = Sampler::CaptureOutput.new(channels: src.channels, sample_rate: src.sample_rate, buffer_size: BUFFER)
            opts = { output: out, transport: transport, channels: src.channels, buffer_size: BUFFER, realtime: false, raise_errors: true, master_gain: 1 }
            opts[:tuning] = src.tuning if src.tuning
            box = Session.new(**opts)
            job.knobs.each do |name, value, sp|
              box.knob(name, value, range: sp.range, curve: sp.curve, unit: sp.unit, takeover: sp.takeover, smooth: sp.smooth)
            end
            [box, out]
          end

          # The figures of rendered channels +data+ (a Hash: lo, hi, frames,
          # peak, rms, lufs, spectrum).
          def figures(data, rate)
            lo, hi = envelope(data)
            peak = data.map { |d| d.abs.max.to_f }.max.to_f
            sum = data.sum { |d| (Numo::DFloat.cast(d)**2).sum }
            count = data.sum(&:length)
            rms = count > 0 ? Math.sqrt(sum / count) : 0.0
            lufs = data[0].length >= rate * 0.4 ? MB::Sound.loudness(data, sample_rate: rate, true_peak: false).integrated.to_f : -Float::INFINITY
            { lo: lo, hi: hi, frames: data[0].length, peak: db(peak), rms: db(rms), lufs: lufs, spectrum: spectrum(data, rate) }
          end

          def finish(job, t0, data, how)
            result_of(job, figures(data, job.source.sample_rate), (now - t0) * 1000, how)
          end

          def result_of(job, f, ms, how)
            Result.new(seq: job.seq, key: job.key, track: job.source.track, lo: f[:lo].freeze, hi: f[:hi].freeze, frames: f[:frames],
                       sample_rate: job.source.sample_rate, peak: f[:peak], rms: f[:rms], lufs: f[:lufs], ms: ms.round(1), input: job.input.text,
                       spectrum: f[:spectrum]&.map(&:freeze)&.freeze, how: how, error: nil)
          end

          # [frequencies, dB] of the render's average spectrum (the channels
          # mixed; Hann windows of 4096 samples, half overlapped, powers
          # averaged; a full-scale sine reads 0 dB; shorter renders use one
          # window of their length's power of two), at SPECTRUM_POINTS
          # log-spaced frequencies from 20 Hz (the loudest bin near each).
          def spectrum(data, rate, n = 4096)
            mono = data.length == 1 ? Numo::DFloat.cast(data[0]) : data.sum { |d| Numo::DFloat.cast(d) } / data.length
            n = 2**Math.log2(mono.length).floor while mono.length < n && n > 256
            return nil if mono.length < n
            w = 0.5 - 0.5 * Numo::NMath.cos(Numo::DFloat.new(n).seq * (2 * Math::PI / n))
            acc = Numo::DFloat.zeros(n / 2 + 1)
            count = 0
            (0..mono.length - n).step(n / 2) do |a|
              acc += Numo::Pocketfft.rfft(mono[a...(a + n)] * w).abs**2
              count += 1
            end
            mag = Numo::NMath.sqrt(acc / count) * (2.0 / w.sum)
            db = 20 * Numo::NMath.log10(mag.clip(1e-5, nil))
            df = rate.to_f / n
            edges = Numo::DFloat.logspace(Math.log10(20.0), Math.log10(rate / 2.0), SPECTRUM_POINTS + 1)
            f = Numo::DFloat.zeros(SPECTRUM_POINTS)
            out = Numo::DFloat.zeros(SPECTRUM_POINTS)
            SPECTRUM_POINTS.times do |i|
              a = (edges[i] / df).round.clamp(1, n / 2)
              b = [(edges[i + 1] / df).round, a + 1].max.clamp(a + 1, n / 2 + 1)
              f[i] = Math.sqrt(edges[i] * edges[i + 1])
              out[i] = db[a...b].max
            end
            [f, out]
          rescue StandardError
            nil
          end

          def note_name(v)
            n = v.respond_to?(:number) ? v.number.round : v.to_i
            "#{Poll::NOTE_NAMES[n % 12]}#{n / 12 - 1}"
          rescue StandardError
            v.to_s
          end

          def first_note(clip)
            evs = (clip.send(:first_cycle_events) rescue clip.events)
            Array(evs).select { |e| e.value }.min_by(&:start)
          rescue StandardError
            nil
          end

          def now = @clock ? @clock.call : MB::U.clock_now

          def db(x) = x > 0 ? 20 * Math.log10(x) : -Float::INFINITY

          def failed(job, t0, why, ms: nil)
            Result.new(seq: job.seq, key: job.key, track: job.source.track, lo: nil, hi: nil, frames: 0, sample_rate: job.source.sample_rate,
                       peak: nil, rms: nil, lufs: nil, ms: (ms || (now - t0) * 1000).round(1), input: job.input&.text, spectrum: nil, how: nil,
                       error: why.to_s.freeze)
          end
        end

        # A render server for one instance (PatchRender.fork): a process
        # forked from this one that builds the patch's instance (so builds
        # never take this process's GVL) and, for each request, forks a copy
        # of the never-sampled instance that sets the knobs, renders, and
        # answers.  This process's cost per render is a small write and a
        # read (the GVL free while waiting); the fork it pays once per
        # instance, 1-5 ms of GVL by the heap's size.  A server ends when its
        # request pipe closes (#close, or this process ending).
        class Server
          # The Job#instance_key it renders.
          attr_reader :key

          # The server's process id.
          attr_reader :pid

          def initialize(job)
            @key = job.instance_key
            jr, @jobs = IO.pipe
            @results, rw = IO.pipe
            [jr, @jobs, @results, rw].each(&:binmode)
            @pid = Process.fork do
              @jobs.close
              @results.close
              PatchRender.send(:serve, job, jr, rw)
            end
            jr.close
            rw.close
            @dead = false
          end

          # True until a request failed or #close.
          def alive? = !@dead

          # Renders +job+'s knobs and length: the figures (a Hash) or a String
          # saying why not.
          def render(job)
            Server.write_frame(@jobs, [job.knobs.map { |n, v, _| [n, v] }, job.seconds])
            Server.read_frame(@results, FORK_TIMEOUT + 30) || begin
              @dead = true
              'the render process ended without a result'
            end
          rescue SystemCallError, IOError => e
            @dead = true
            "the render process failed (#{e.class})"
          end

          # Ends the server and reaps it.
          def close
            @dead = true
            @jobs.close unless @jobs.closed?
            @results.close unless @results.closed?
            Process.kill(:KILL, @pid) rescue nil
            Process.wait(@pid) rescue nil
            nil
          end

          # Writes +obj+ as one frame (a 4-byte length, then Marshal) to +io+.
          def self.write_frame(io, obj)
            data = Marshal.dump(obj)
            io.write([data.bytesize].pack('N'), data)
            io.flush
          end

          # The next frame's object from +io+, or nil at its end or after
          # +timeout+ seconds (nil: no limit).
          def self.read_frame(io, timeout)
            head = read_exactly(io, 4, timeout) or return nil
            body = read_exactly(io, head.unpack1('N'), timeout) or return nil
            Marshal.load(body) # (frames from our own forked process only)
          end

          def self.read_exactly(io, n, timeout)
            buf = +''.b
            deadline = timeout && MB::U.clock_now + timeout
            while buf.bytesize < n
              left = deadline && deadline - MB::U.clock_now
              return nil if left && left <= 0
              return nil unless io.wait_readable(left)
              chunk = io.read_nonblock(n - buf.bytesize, exception: false)
              return nil if chunk.nil?
              buf << chunk unless chunk == :wait_readable
            end
            buf
          end
        end

        # When to render (an explicit state machine; the maintainer's
        # preference for named states and a transition table, 2026-10-17):
        #
        #   state     event   condition                       next     action
        #   idle      change                                  waiting  pending since now
        #   waiting   change                                  waiting  last change now
        #   waiting   tick    quiet DEBOUNCE, or pending       busy     submit
        #                     SWEEP, or nothing shown yet
        #   busy      change                                  dirty    pending since now
        #   busy      done                                    idle
        #   dirty     change                                  dirty    last change now
        #   dirty     done                                    waiting
        #
        # Times are the caller's clock (seconds), so specs drive it.
        class Debounce
          TABLE = {
            [:idle, :change] => :waiting, [:waiting, :change] => :waiting, [:waiting, :submit] => :busy,
            [:busy, :change] => :dirty, [:busy, :done] => :idle, [:dirty, :change] => :dirty, [:dirty, :done] => :waiting,
          }.freeze

          # The states (Symbols).
          STATES = %i[idle waiting busy dirty].freeze

          attr_reader :state

          def initialize
            @state = :idle
            @changed_at = nil
            @pending_since = nil
          end

          # A change of what to render at +now+.
          def change(now)
            pending = @state == :idle || @state == :busy
            go(:change)
            @pending_since = now if pending
            @changed_at = now
            self
          end

          # True (and busy from now) if a render should start at +now+:
          # quiet for DEBOUNCE, changes pending for SWEEP, or +urgent+
          # (nothing shown for the track yet).
          def submit?(now, urgent: false)
            return false unless @state == :waiting
            return false unless urgent || now - @changed_at >= DEBOUNCE || now - @pending_since >= SWEEP
            go(:submit)
            true
          end

          # The running render finished.
          def done
            go(:done)
            self
          end

          private

          def go(event)
            nxt = TABLE[[@state, event]] or raise ArgumentError, "PatchRender::Debounce: no #{event.inspect} in state #{@state.inspect}"
            @state = nxt
          end
        end

        # The render thread of one Driver: runs the newest Job submitted
        # (one at a time; a newer one replaces a waiting one) at low priority
        # and keeps the newest Result.  The thread starts on the first
        # #submit and ends after IDLE seconds without work (or #close).
        class Worker
          def initialize(&on_done)
            @mutex = Mutex.new
            @cond = ConditionVariable.new
            @job = nil
            @result = nil
            @thread = nil
            @closed = false
            @running = false
            @cache = {} # (PatchRender.render: the Instance, or self-contained checks)
            @on_done = on_done
          end

          # Queues +job+ (replacing a job not yet started).
          def submit(job)
            @mutex.synchronize do
              raise 'PatchRender::Worker is closed' if @closed
              @job = job
              start unless @thread&.alive?
              @cond.signal
            end
            self
          end

          # The newest Result (nil before the first).
          def result = @mutex.synchronize { @result }

          # True while a job waits or runs.
          def busy? = @mutex.synchronize { !@job.nil? || @running }

          # The worker thread (nil when none runs), for specs.
          def thread = @mutex.synchronize { @thread }

          # Stops the thread (waiting for a render in progress).
          def close
            t = @mutex.synchronize {
              @closed = true
              @job = nil
              @cond.signal
              @thread
            }
            t&.join
            nil
          end

          private

          # (worker thread, holding the mutex) Closes the kept instance.
          def drop_instance
            @cache.delete(:server)&.close
            @cache.clear
          end

          def start
            @thread = Thread.new { run }
            @thread.name = 'mb-sound patch render'
            @thread.priority = -3
            @thread.report_on_exception = false
          end

          def run
            loop do
              job = @mutex.synchronize {
                deadline = MB::U.clock_now + IDLE
                while @job.nil? && !@closed
                  left = deadline - MB::U.clock_now
                  if left <= 0
                    @thread = nil
                    drop_instance
                    return
                  end
                  @cond.wait(@mutex, left)
                end
                if @closed
                  @thread = nil
                  drop_instance
                  return
                end
                @running = true
                j = @job
                @job = nil
                j
              }
              r = PatchRender.render(job, cache: @cache, fork: PatchRender.fork, pace: true)
              @mutex.synchronize {
                @result = r if @result.nil? || r.seq > @result.seq
                @running = false
              }
              @on_done&.call(r)
            end
          end
        end

        # A Worker that renders on the calling thread as #submit is called
        # (PatchRender.inline).
        class InlineWorker
          def initialize
            @result = nil
            @cache = {}
          end

          def submit(job)
            @result = PatchRender.render(job, cache: @cache)
            self
          end

          attr_reader :result

          def busy? = false

          def thread = nil

          def close = nil
        end

        # Decides and keeps renders for one pane placement (painter
        # thread): #tick(source, knobs, now) with the inspected track's
        # Source and the snapshot's knob values starts a render through the
        # Debounce when they change, and #shown is the Result to draw (the
        # newest for the track; results for another track are dropped),
        # #previous the one before it (the faint overlay), #pending? true
        # while what's shown is out of date.
        class Driver
          attr_reader :shown, :previous, :debounce

          # +clock+ gives the time (specs pass their own); +worker+ a Worker
          # (made on the first render).
          def initialize(clock: -> { MB::U.clock_now }, worker: nil)
            @clock = clock
            @worker = worker
            @debounce = Debounce.new
            @key = nil
            @seq = 0
            @running_key = nil
            @shown = nil
            @previous = nil
            @source = nil
            @knobs = nil
            @guess = false
            @input = nil
            @input_of = nil
            @job_input = nil
          end

          # True: renders play the role's guessed note instead of the clip's
          # first note.
          attr_accessor :guess

          # The key that decides whether a render is current: the track, its
          # patch by identity, the input (PatchRender.input's id), the
          # length, and the values of the knobs the graph reads (+read+:
          # names).
          def self.key_of(source, input, knobs, read, seconds)
            values = read.map { |n| knobs.find { |k| k.name == n }&.value }
            [source.track, source.patch.object_id, input.id, seconds, *values].freeze
          end

          # The Input for +source+ now (kept while its clip, words, the guess
          # flag, and the length stay the same).
          def input_for(source)
            of = [source.clip.object_id, source.words, @guess, PatchRender.seconds, source.bpm]
            return @input if @input_of == of
            @input_of = of
            @input = PatchRender.input(source, PatchRender.seconds, guess: @guess)
          end

          # One tick: +source+ (a Source, or nil: nothing to render), +knobs+
          # (the snapshot's KnobValues), +read+ (the knob names the graph
          # reads).  Starts a render when the debounce says so.  Returns
          # self.
          def tick(source, knobs, read)
            now = @clock.call
            collect
            return self if source.nil?

            input = input_for(source)
            key = Driver.key_of(source, input, knobs, read, PatchRender.seconds)
            if key != @key
              @key = key
              @source = source
              @job_input = input
              @knobs = knobs
              @debounce.change(now) unless @debounce.state == :idle && @shown&.key == key
            else
              @knobs = knobs
            end
            urgent = @shown.nil? || @shown.track != source.track
            if @debounce.submit?(now, urgent: urgent)
              @seq += 1
              rows = @knobs.map { |k| [k.name, k.value, k.spec].freeze }.freeze
              worker.submit(Job.new(seq: @seq, key: @key, source: @source, input: @job_input, knobs: rows, seconds: PatchRender.seconds))
              @running_key = @key
              collect
            end
            self
          end

          # Forces a render on the next tick (the pane's r key).
          def again
            @key = nil
            @shown = @shown&.with(key: nil)
            self
          end

          # True while what's shown is out of date (a render waits or runs).
          def pending? = @debounce.state != :idle

          # The debounce's state (:idle, :waiting, :busy, :dirty).
          def state = @debounce.state

          # The current track's key (nil before the first tick).
          attr_reader :key

          # Stops the worker thread.
          def close
            @worker&.close
            nil
          end

          # The Worker (made on first use).
          def worker = (@worker ||= PatchRender.inline ? InlineWorker.new : Worker.new)

          private

          # Takes a finished render: kept if it's newer than the shown one
          # and for the track inspected now (else dropped: stale).
          def collect
            return unless @debounce.state == :busy || @debounce.state == :dirty
            r = @worker&.result
            return if r.nil? || (@shown && r.seq <= @shown.seq) || @worker.busy?
            @debounce.done
            @running_key = nil
            return if @key && r.key[0] != @key[0] # (another track's render)
            # (the faint overlay: the last render of the same track, none
            # after a track change)
            @previous = @shown && @shown.track == r.track ? (@shown.error ? @previous : @shown) : nil
            @shown = r
          end
        end
      end
    end
  end
end
