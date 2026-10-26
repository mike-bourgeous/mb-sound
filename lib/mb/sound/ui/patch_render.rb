module MB
  module Sound
    module UI
      # One-shot offline renders of a track's patch for the sound-design
      # screen's RENDER pane (sound-design-ui-2; design/notes/sound_design_ui.md):
      # "a one-shot render of the processed waveform updated periodically
      # when parameters change" (maintainer, 2026-10-26).
      #
      # A render never touches the live graph: it calls the track's patch
      # block again (the same code the live track built its graph with, so
      # the same sound) in a throwaway Session (a sandbox like
      # Arrangement#warm_up's: the session's tempo, meter, key, tuning, and
      # copies of every knob at its value now), with its own random seeds
      # (Internal.with_private_rng: the live set's seed draws are
      # untouched), live mode off on that thread (Internal.strictly: a
      # patch's mistakes are the result, not warnings), and major GCs held
      # off (GCQuiet).  The first render of a patch and clip builds it
      # twice and renders only if the two builds share no node: a patch
      # that reaches nodes made outside it (shared with the live graph)
      # would have them advanced.
      #
      # The work happens on a Worker thread at low priority that passes
      # the GVL after every buffer, never on the painter or render thread
      # and never under the render lock; a Driver (one per pane placement,
      # ticked by the pane on the painter thread) decides when to render
      # with a Debounce and keeps the newest result.
      module PatchRender
        # What a render plays by default (seconds; PatchRender.seconds=).
        SECONDS = 3.0

        # Render lengths allowed (seconds).
        SECONDS_RANGE = (0.5..20.0)

        # The quiet time after the last change before a render starts.
        DEBOUNCE = 0.25

        # While changes keep coming (a held sweep), a render starts at most
        # this long after the first change it hasn't rendered.
        SWEEP = 0.5

        # The seed every render's root generator starts from (renders differ
        # only by what changed).
        SEED = 0

        # Frames per buffer of an offline render (the worker gives the GVL
        # back between buffers, so smaller buffers keep the live render
        # thread's waits short).
        BUFFER = 256

        # The share of wall time a Worker's render may take (it sleeps
        # after each buffer for the rest; PatchRender.duty=): Ruby runs one
        # thread at a time, so a render that never paused would take the
        # GVL from the live render thread whenever both have work.
        DUTY = 0.5

        # Columns of the min/max envelope kept per render (enough for a
        # 236-column terminal's Braille dots).
        ENVELOPE = 1024

        # Points of a render's spectrum (the pane's spectrum view).
        SPECTRUM_POINTS = 256

        # A Worker thread with nothing to do for this long ends (a new
        # request starts another).
        IDLE = 10.0

        # The inspected track's patch and what a render needs from the
        # live session (gathered by Poll; nothing here is read from the
        # session again): +track+ the player name, +patch+ the track's
        # patch block (nil for a graph track: +note+ says why there is no
        # render), +clip+ the track's clip (nil: the demo phrase), +bpm+,
        # +bar_length+, +key+ (a MusicalKey), +tuning+, +channels+,
        # +sample_rate+.
        Source = Data.define(:track, :patch, :clip, :bpm, :bar_length, :key, :tuning, :channels, :sample_rate, :note)

        # One render request: +seq+ (increasing), +key+ (what decides
        # whether a render is current: Driver.key_of), +source+, +knobs+
        # (frozen [name, value, Knob::Spec] rows for the sandbox), +seconds+,
        # +demo+ (true: the demo phrase instead of the track's clip).
        Job = Data.define(:seq, :key, :source, :knobs, :seconds, :demo)

        # A finished render: +seq+ and +key+ of its Job, +track+, +lo+ and
        # +hi+ (frozen SFloat min/max envelopes over every channel, ENVELOPE
        # columns), +frames+, +sample_rate+, +peak+ (dBFS), +rms+ (dBFS),
        # +lufs+ (integrated, -Infinity for silence), +ms+ (wall time of
        # the build and render), +input+ (:clip or :demo), +spectrum+
        # ([frequencies, dB] frozen DFloats, or nil), +error+ (why there is
        # no audio, or nil).
        Result = Data.define(:seq, :key, :track, :lo, :hi, :frames, :sample_rate, :peak, :rms, :lufs, :ms, :input, :spectrum, :error)

        @seconds = SECONDS
        @inline = false
        @clock = nil
        @duty = Float(ENV['MB_SOUND_RENDER_DUTY'] || DUTY)

        class << self
          # The length of each render (seconds).
          attr_reader :seconds

          # True: Drivers render on the calling thread (InlineWorker), for
          # specs and the golden captures.
          attr_accessor :inline

          # The share of wall time a Worker's render may take (0 < duty <= 1;
          # 1: no pauses, only Thread.pass).
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

          # Renders +job+ (a Job) on the calling thread and returns a Result.
          # +contained+ is a Hash the caller keeps (patch => { clip => true
          # or false }) so a patch and clip are checked for nodes shared
          # with outside graphs once, not every render.  +pace+ true (the
          # Worker) sleeps after each buffer to keep to PatchRender.duty.
          # Never raises.
          def render(job, contained: nil, pace: false)
            src = job.source
            t0 = now
            clip = job.demo || src.clip.nil? ? Playable.demo_phrase : src.clip
            input = clip.equal?(src.clip) ? :clip : :demo
            return failed(job, input, t0, src.note || 'no patch to rebuild') if src.patch.nil?

            data = nil
            Internal.strictly do
              GCQuiet.during do
                Internal.with_private_rng(SEED) do
                  data = render_patch(job, clip, contained, pace)
                end
              end
            end
            return failed(job, input, t0, data) if data.is_a?(String)

            finish(job, input, t0, data)
          rescue Exception => e # rubocop:disable Lint/RescueException (a patch's SystemStackError or NotImplementedError is its result too)
            raise if e.is_a?(Interrupt) || e.is_a?(SystemExit)
            failed(job, input, t0, "#{e.class}: #{e.message}".lines.first.chomp)
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

          # Builds the patch in a sandbox and renders it: the captured
          # channels, or a String saying why not.
          def render_patch(job, clip, contained, pace)
            src = job.source
            box, out = sandbox(job)
            graph = Session.with_context(session: box) { src.patch.call(clip) }
            return 'the patch made nothing to play' if graph.nil?

            known = contained&.dig(src.patch, clip)
            if known.nil?
              known = self_contained?(job, clip, box, graph)
              if contained
                contained.clear if contained.length >= 8 && !contained.key?(src.patch)
                (contained[src.patch] ||= {}.compare_by_identity)[clip] = known
              end
            end
            return 'the patch reads nodes made outside it (shared with the live graph): no render' unless known

            box.add(graph, on: :now)
            frames = (job.seconds * src.sample_rate).round
            rest = pace ? (1 - @duty) / @duty : 0
            (frames.to_f / BUFFER).ceil.times do
              t = MB::U.clock_now
              box.process_buffer
              # (the render and painter threads get the GVL between buffers)
              rest > 0 ? sleep((MB::U.clock_now - t) * rest) : Thread.pass
            end
            out.captured(frames)
          ensure
            box&.close
          end

          # True if a second build of the patch shares no node with +graph+
          # (see PatchRender).
          def self_contained?(job, clip, box, graph)
            other, = sandbox(job)
            second = Session.with_context(session: other) { job.source.patch.call(clip) }
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

          def finish(job, input, t0, data)
            lo, hi = envelope(data)
            peak = data.map { |d| d.abs.max.to_f }.max.to_f
            sum = data.sum { |d| (Numo::DFloat.cast(d)**2).sum }
            count = data.sum(&:length)
            rms = count > 0 ? Math.sqrt(sum / count) : 0.0
            lufs = MB::Sound.loudness(data, sample_rate: job.source.sample_rate, true_peak: false).integrated
            Result.new(seq: job.seq, key: job.key, track: job.source.track, lo: lo, hi: hi, frames: data[0].length, sample_rate: job.source.sample_rate,
                       peak: db(peak), rms: db(rms), lufs: lufs.to_f, ms: ((now - t0) * 1000).round(1), input: input,
                       spectrum: spectrum(data, job.source.sample_rate), error: nil)
          end

          # [frequencies, dB] of the render's average spectrum (the channels
          # mixed; Hann windows of 4096 samples, half overlapped, powers
          # averaged; a full-scale sine reads 0 dB), at SPECTRUM_POINTS
          # log-spaced frequencies from 20 Hz (the loudest bin near each), or
          # nil for renders shorter than a window.
          def spectrum(data, rate, n = 4096)
            mono = data.length == 1 ? Numo::DFloat.cast(data[0]) : data.sum { |d| Numo::DFloat.cast(d) } / data.length
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
            [f.freeze, out.freeze].freeze
          rescue StandardError
            nil
          end

          def now = @clock ? @clock.call : MB::U.clock_now

          def db(x) = x > 0 ? 20 * Math.log10(x) : -Float::INFINITY

          def failed(job, input, t0, why)
            Result.new(seq: job.seq, key: job.key, track: job.source.track, lo: nil, hi: nil, frames: 0, sample_rate: job.source.sample_rate,
                       peak: nil, rms: nil, lufs: nil, ms: ((now - t0) * 1000).round(1), input: input, spectrum: nil, error: why.to_s.freeze)
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
            @contained = {}.compare_by_identity
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
                    return
                  end
                  @cond.wait(@mutex, left)
                end
                if @closed
                  @thread = nil
                  return
                end
                @running = true
                j = @job
                @job = nil
                j
              }
              r = PatchRender.render(job, contained: @contained, pace: true)
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
            @contained = {}.compare_by_identity
          end

          def submit(job)
            @result = PatchRender.render(job, contained: @contained)
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
            @demo = false
          end

          # True: renders play the demo phrase instead of the track's clip.
          attr_accessor :demo

          # The key that decides whether a render is current: the track, its
          # patch and clip by identity, the demo flag, the length, and the
          # values of the knobs the graph reads (+read+: names).
          def self.key_of(source, knobs, read, demo, seconds)
            values = read.map { |n| knobs.find { |k| k.name == n }&.value }
            [source.track, source.patch.object_id, source.clip.object_id, demo, seconds, *values].freeze
          end

          # One tick: +source+ (a Source, or nil: nothing to render), +knobs+
          # (the snapshot's KnobValues), +read+ (the knob names the graph
          # reads).  Starts a render when the debounce says so.  Returns
          # self.
          def tick(source, knobs, read)
            now = @clock.call
            collect
            return self if source.nil?

            key = Driver.key_of(source, knobs, read, @demo, PatchRender.seconds)
            if key != @key
              @key = key
              @source = source
              @knobs = knobs
              @debounce.change(now) unless @debounce.state == :idle && @shown&.key == key
            else
              @knobs = knobs
            end
            urgent = @shown.nil? || @shown.track != source.track
            if @debounce.submit?(now, urgent: urgent)
              @seq += 1
              rows = @knobs.map { |k| [k.name, k.value, k.spec].freeze }.freeze
              worker.submit(Job.new(seq: @seq, key: @key, source: @source, knobs: rows, seconds: PatchRender.seconds, demo: @demo))
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
