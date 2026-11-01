module MB
  module Sound
    module UI
      # One cycle of an oscillator for the sound-design screen's preview
      # pane (ux-notes-2; the maintainer's note 4, "An oscillator should
      # have a preview of one wave cycle", and his choice "Render one
      # cycle", 2026-11-02): a copy of the inspected track's voice
      # (PatchRender's copy, unplanned) plays the render pane's note, and
      # the picked oscillator alone is sampled for one of its periods from
      # the note-on, so the drawing is the oscillator's own output:
      # wavetable frames, FM from its modulators, pwm, sync, and the
      # band-limiting are all exact.  The period is the oscillator's
      # frequency as it played (Tone::State#last_freq), or a sync master's.
      #
      # Renders run on a PatchRender::Worker (in the windows after the live
      # render thread's buffers, at low priority; never on the painter or
      # render thread), and are kept by what decides them (the voice block,
      # the note, the oscillator's recipe key, and the values of the knobs
      # the voice reads), so a knob turn renders again and going back to a
      # row shown before doesn't.
      module ToneCycle
        # What one render plays: +seq+, +key+ (Driver.key_of), +source+ (a
        # PatchRender::Source), +input+ (a PatchRender::Input), +knobs+
        # (frozen [name, value, Knob::Spec] rows), +tone+ (the oscillator's
        # recipe key, GraphNode::Recipe.key_of).
        Job = Data.define(:seq, :key, :source, :input, :knobs, :tone) do
          # The PatchRender::Job whose copy it samples.
          def copy_job = PatchRender::Job.new(seq: seq, key: key, source: source, input: input, knobs: knobs, seconds: PatchRender.seconds)
        end

        # A finished render: +seq+, +key+, +track+, +cycle+ (a frozen SFloat:
        # one period from the note-on, decimated to at most POINTS),
        # +frames+ (samples in the period, before decimation), +rate+,
        # +frequency+ (Hz), +synced+ (the period is a sync master's),
        # +partial+ (true when the period was longer than MAX_SECONDS: the
        # first MAX_SECONDS of it), +noise+ (a noise oscillator, which has
        # no cycle: NOISE_FRAMES of it), +input+ (text), +ms+ (render time,
        # with the copy's build when built for it), +error+.
        Result = Data.define(:seq, :key, :track, :cycle, :frames, :rate, :frequency, :synced, :partial, :input, :ms, :error, :noise)

        # Samples of a noise oscillator shown (it repeats no cycle).
        NOISE_FRAMES = 1024

        # The longest period rendered (seconds; an LFO's longer cycle shows
        # its start).
        MAX_SECONDS = 8.0

        # Points of the drawn cycle at most (longer periods are decimated).
        POINTS = 2048

        # Samples after the note-on before the cycle may start (whole
        # periods past it): a key-synced oscillator's phase reset is a
        # band-limited step (BandLimit::SYNC_TAPS samples of correction).
        LEAD = 2 * BandLimit::SYNC_TAPS

        # Frames sampled per block (passing the GVL between blocks).
        CHUNK = 256

        # Results a Driver keeps.
        KEEP = 16

        # The rate copies run at (an oscillator's band-limiting as heard).
        RATE = PatchRender::RATES.last

        class << self
          # Renders +job+ (see Job), keeping copies in +cache+ (a Hash the
          # caller keeps).  Never raises: errors are the Result's.
          def render(job, cache: {}, pace: false)
            t0 = PatchRender.send(:now)
            src = job.source
            Thread.current[:mb_sound_preview_frames] = pace ? src.frames : nil
            pr.send(:slack, src.frames, pace)
            return failed(job, t0, src.note || 'no voice to copy') if src.synth.nil?
            return failed(job, t0, 'no recorded call to copy (an oscillator made outside the voice)') if job.tone.nil?

            cj = job.copy_job
            copies = (cache[:copies] ||= {})
            key = cj.copy_key
            copy = copies.delete(key)
            built = copy.nil?
            copy ||= pr.send(:build, cj, RATE, pace, (cache[:scopes] ||= {}), plan: false)
            copies[key] = copy
            copies.shift[1].close while copies.length > PatchRender::COPIES
            return failed(job, t0, copy.error) if copy.error

            tone = find_tone(copy, job.tone)
            return failed(job, t0, 'this oscillator is outside the voice (no copy of it to play)') unless tone

            data = freq = synced = partial = noise = nil
            Internal.strictly { data, freq, synced, partial, noise = play(copy, cj, tone, pace) }
            return failed(job, t0, 'no frequency (the oscillator stood still)') unless data

            n = data.length
            cycle = n > POINTS ? decimate(data, POINTS) : data
            Result.new(seq: job.seq, key: job.key, track: src.track, cycle: cycle.freeze, frames: n, rate: copy.rate, frequency: freq, synced: synced,
                       partial: partial, input: job.input.text, ms: ((PatchRender.send(:now) - t0) * 1000).round(1), error: nil, noise: noise)
          rescue Exception => e # rubocop:disable Lint/RescueException (a patch's SystemStackError is its result too)
            raise if e.is_a?(Interrupt) || e.is_a?(SystemExit)
            failed(job, t0, "#{e.class}: #{e.message}".lines.first.chomp)
          end

          # The Tone of +copy+ made by the call +key+ names (the first, for
          # copies of one call: a unison's oscillators).
          def find_tone(copy, key)
            pr.send(:graph_nodes, copy.outputs).find { |n| n.is_a?(Tone) && key_of(n) == key }
          end

          # The oscillator's recipe key (GraphNode::Recipe.key_of), or nil.
          def key_of(tone)
            call = GraphNode::Recipe.call_of(tone)
            call && GraphNode::Recipe.key_of(call)
          end

          private

          def pr = PatchRender

          # Plays the note from the copy's reset state and samples +tone+
          # alone for one period from the note-on: [SFloat, Hz, synced,
          # partial] (nil when it has no frequency).
          def play(copy, job, tone, pace)
            rate = copy.rate
            pr.send(:restore, copy)
            pr.send(:set_knobs, copy, job)
            copy.feed.play(job.input.note, job.input.velocity, nil)
            work = (copy.work[:tone_cycle] ||= {})
            master = sync_master(tone)
            # (its frequency: the mean of what it played over a lead-in of a
            # few of the note's periods, every sample its kernel was given,
            # so an FM'd oscillator's period is its carrier's)
            sums = tap_frequency(master || tone, work)
            sums[0] = 0.0
            sums[1] = 0
            buf = work[:buf] ||= Numo::SFloat.zeros(16 * CHUNK)
            note_hz = (job.source.tuning || Tuning.default).frequency_of(job.input.note).to_f
            # (whole periods of the note: a modulator at the note's pitch
            # averages out)
            note_period = rate / note_hz
            lead = ([(LEAD / note_period).ceil, 2].max * note_period).round.clamp(LEAD, (0.25 * rate).round)
            have = 0
            buf = grow(work, buf, lead)
            while have < lead
              n = [CHUNK, lead - have].min
              buf[have...(have + n)] = sample(tone, n)
              have += n
            end
            freq = sums[1] > 0 ? (sums[0] / sums[1]).abs : nil
            if freq.nil? || !freq.finite? || freq <= 0
              copy.feed.release(job.input.note)
              return nil
            end
            period = rate / freq
            partial = period > MAX_SECONDS * rate
            # (whole periods past the note-on's phase reset, whose
            # band-limited step rings for LEAD samples: the cycle starts at
            # the same phase, settled)
            noise = tone.instance_variable_get(:@noise).to_f >= 1
            start = partial ? 0 : ((LEAD / period).ceil * period).round
            len = partial ? (MAX_SECONDS * rate).round : period.ceil + 1
            partial, start, len = false, LEAD, NOISE_FRAMES if noise
            frames = start + len
            chunk = frames > 16 * CHUNK ? 16 * CHUNK : CHUNK
            buf = grow(work, buf, frames + chunk)
            while have < frames
              t = MB::U.clock_now
              d = sample(tone, chunk)
              buf[have...(have + chunk)] = d
              have += chunk
              pr.send(:rest, pace, MB::U.clock_now - t)
            end
            copy.feed.release(job.input.note)
            [buf[start...frames].dup, freq.to_f, !master.nil?, partial, noise]
          end

          # +buf+, or a longer one kept in +work+ when it holds fewer than
          # +n+ samples.
          def grow(work, buf, n)
            return buf if buf.length >= n
            nb = Numo::SFloat.zeros([n, buf.length * 2].max)
            nb[0...buf.length] = buf
            work[:buf] = nb
          end

          # +tone+'s next +n+ samples as SFloat (the real part of a complex
          # tone).
          def sample(tone, n)
            d = tone.sample(n)
            d = Numo::SFloat.zeros(n) if d.nil?
            d = d.real if d.is_a?(Numo::DComplex) || d.is_a?(Numo::SComplex)
            d.is_a?(Numo::SFloat) ? d : Numo::SFloat.cast(d)
          end

          # The Tone a synced +tone+ follows (its period is the master's), or
          # nil.
          def sync_master(tone)
            src = tone.instance_variable_get(:@sync_source) or return nil
            [src, *(src.respond_to?(:graph) ? src.graph : [])].find { |n| n.is_a?(Tone) && !n.equal?(tone) }
          end

          # [sum, count] of the frequencies +tone+'s kernel is given from now
          # on (Hz per sample; a copy's tone only: its #compute gets a
          # singleton wrapper once, kept in +work+).
          def tap_frequency(tone, work)
            taps = (work[:taps] ||= {}.compare_by_identity)
            taps[tone] ||= begin
              sums = [0.0, 0]
              tone.define_singleton_method(:compute) do |count, freq, *rest|
                if freq.is_a?(Numeric)
                  sums[0] += freq * count
                else
                  sums[0] += freq[0...count].sum.to_f
                end
                sums[1] += count
                super(count, freq, *rest)
              end
              sums
            end
          end

          # +data+ at +points+ points (every k-th sample, the last kept).
          def decimate(data, points)
            idx = Numo::Int64.cast(Numo::DFloat.linspace(0, data.length - 1, points).round)
            data[idx]
          end

          def failed(job, t0, why)
            Result.new(seq: job.seq, key: job.key, track: job.source&.track, cycle: nil, frames: 0, rate: RATE, frequency: nil, synced: false,
                       partial: false, input: job.input&.text, ms: ((PatchRender.send(:now) - t0) * 1000).round(1), error: why.to_s.freeze, noise: false)
          end
        end

        # Decides and keeps one pane placement's renders (painter thread):
        # #tick(source, tone, knobs, read) starts a render through a
        # PatchRender::Debounce when what decides it changes, and #shown is
        # the Result for what is picked now (or the last one for the same
        # oscillator while a new one renders: #pending?).
        class Driver
          def initialize(clock: -> { MB::U.clock_now }, worker: nil)
            @clock = clock
            @worker = worker
            @debounce = PatchRender::Debounce.new
            @key = nil
            @seq = 0
            @kept = {} # key => Result (the newest KEEP)
            @job = nil
            @input = nil
            @input_of = nil
          end

          # The key deciding a render: the track, its voice block, the
          # note, the oscillator, and the values of the knobs the voice
          # reads (+read+: names).
          def self.key_of(source, input, tone, knobs, read)
            values = read.map { |n| knobs.find { |k| k.name == n }&.value }
            [source.track, source.synth&.voice_block.object_id, input.id, tone, *values].freeze
          end

          # One tick (see the class description).  Returns self.
          def tick(source, tone, knobs, read)
            now = @clock.call
            collect
            return self if source.nil?

            input = input_for(source)
            key = Driver.key_of(source, input, tone, knobs, read)
            if key != @key
              @key = key
              rows = knobs.map { |k| [k.name, k.value, k.spec].freeze }.freeze
              @job = [source, input, rows, tone]
              @debounce.change(now) unless @kept.key?(key)
            end
            if @kept.key?(@key)
              # (back to something kept while a render waited: nothing to
              # render; the Debounce goes waiting -> busy -> idle)
              @debounce.done if @debounce.state == :waiting && @debounce.submit?(now, urgent: true)
            elsif @debounce.submit?(now, urgent: shown.nil?)
              src, inp, rows, tn = @job
              worker.submit(Job.new(seq: @seq += 1, key: @key, source: src, input: inp, knobs: rows, tone: tn))
              collect
            end
            self
          end

          # The Result for what is picked now, else the newest for the same
          # oscillator (shown while it renders again), else nil.
          def shown
            return nil unless @key
            @kept[@key] || @kept.values.reverse.find { |r| same_tone?(r.key, @key) }
          end

          # True while what's shown is out of date.
          def pending? = @debounce.state != :idle || (!@key.nil? && !@kept.key?(@key))

          # Stops the worker thread.
          def close
            @worker&.close
            nil
          end

          # The Worker (made on first use).
          def worker = (@worker ||= PatchRender.inline ? PatchRender::InlineWorker.new(ToneCycle) : PatchRender::Worker.new(ToneCycle))

          private

          # The same track, voice, and oscillator (another note or knob
          # values).
          def same_tone?(a, b) = a && b && a[0] == b[0] && a[1] == b[1] && a[3] == b[3]

          def input_for(source)
            of = [source.clip.object_id, source.words, source.bpm]
            return @input if @input_of == of
            @input_of = of
            @input = PatchRender.input(source, PatchRender.seconds)
          end

          # Takes a finished render, keeping the newest KEEP.
          def collect
            return unless @debounce.state == :busy || @debounce.state == :dirty
            r = @worker&.result
            return if r.nil? || @worker.busy? || @kept[r.key]&.seq.to_i >= r.seq
            @debounce.done
            @kept.delete(r.key)
            @kept[r.key] = r
            @kept.shift while @kept.length > KEEP
          end
        end
      end
    end
  end
end
