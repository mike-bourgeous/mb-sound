module MB
  module Sound
    module UI
      # Previews of the inspected patch for the sound-design screen's RENDER
      # pane (sound-design-ui-2; design/notes/sound_design_ui.md): "a
      # one-shot render of the processed waveform updated periodically when
      # parameters change" (maintainer, 2026-10-26).
      #
      # Round 3, his method (2026-10-27): "keeping two copies and calling
      # sample one time on the second copy".  When the patch's structure
      # changes (another patch, track, or note), a Copy is built: one
      # voice's graph from the live Synth's voice block (not a Synth, no
      # clip, never in a Session's render), driven by a NoteFeed, reading
      # knob copies that the pane sets to the live knobs' values before each
      # render (so knob turns need no rebuild), with its plans installed.
      # Each render puts every node's state back as it was after the build
      # (Plan::Describable#plan_snapshot/#plan_restore: oscillator phases,
      # filter and envelope states) and plays the note once, held for the
      # clip note's length or the role's share: whole periods are compared
      # until one stops changing (the filters settled) and that period is
      # kept from a rising zero crossing; when no period repeats (detuned
      # unison copies), a few periods from a zero crossing (.cycle).  The
      # same render gives the envelope view, the figures, and the spectrum
      # of the settled part.
      #
      # The copy runs at the lowest of RATES that keeps every lowpass
      # cutoff under 1/RATE_FACTOR of the rate (.rate_for), else (moving
      # cutoffs, no lowpass, a voice that can't change rate) 48 kHz.
      #
      # It runs in this process on a Worker thread at low priority,
      # in CHUNK-frame blocks and short analysis steps, each followed by
      # .rest: with a live Session to follow (Source#frames), the worker
      # works only in a window right after each buffer the render thread
      # finishes (a share of the time between buffers), so the two don't
      # want the GVL at once.  Renders reuse their buffers (Copy#work) and
      # the last few copies (COPIES), so they make few objects (2-3
      # thousand an update) for the garbage collector.  Never on the
      # painter or render thread, never under the render lock, never
      # sampling the live graph.
      module PatchRender
        # How long the envelope view plays (seconds; PatchRender.seconds=).
        SECONDS = 0.5

        # Envelope lengths allowed (seconds).
        SECONDS_RANGE = (0.1..20.0)

        # The quiet time after the last change before a render starts.
        DEBOUNCE = 0.1

        # While changes keep coming (a held sweep), a render starts at most
        # this long after the first change it hasn't rendered.
        SWEEP = 0.2

        # Frames per block of a preview render (the GVL is passed between
        # blocks; a voice's graph allocates a few objects per block, so
        # 256 rather than 128).
        CHUNK = 256

        # The share of wall time a Worker render may take (it sleeps after
        # each block for the rest; PatchRender.duty=).
        DUTY = 0.5

        # Rates a copy may run at, lowest first (12 and 16 kHz rounded a
        # saw's edge visibly at 472 columns: 12-23% of the peak beyond a
        # column's shift, against at most 4.7% at 24 kHz; the design note's
        # measurements).
        RATES = [24000, 32000, 48000].freeze

        # A copy's rate keeps every lowpass cutoff at most 1/RATE_FACTOR of
        # it (an eighth of the rate is a quarter of Nyquist, far from the
        # SVF and four-pole responses' warping near Nyquist; plotted, the
        # cycle moved at most an edge by a column: the design note's
        # measurements).
        RATE_FACTOR = 8

        # A period has settled when it differs from the one before by less
        # than this (dB of the period's RMS, after both are scaled to the
        # same RMS: slow envelopes don't count as change).
        SETTLED_DB = -40.0

        # Samples .settle_scan compares between pauses, and the points of
        # each period it compares.
        SCAN_FRAMES = 4096
        SCAN_POINTS = 64

        # The longest the cycle view waits for a period to settle (seconds);
        # notes whose periods never repeat (unison) show UNISON_PERIODS
        # periods from here.
        SETTLE_MAX = 0.4

        # Periods shown when no single period repeats.
        UNISON_PERIODS = 4

        # Columns of the min/max envelope kept per render.
        ENVELOPE = 1024

        # Points of a render's spectrum.
        SPECTRUM_POINTS = 256

        # Windows a spectrum averages (the last ones of the settled sound).
        SPECTRUM_WINDOWS = 3

        # Copies a render cache keeps (the most recent ones: switching back
        # to a track or note just previewed doesn't build again, and drops
        # no copy for the garbage collector to find in the old generation).
        COPIES = 4

        # A Worker thread with nothing to do for this long ends, dropping
        # its copy (a new request starts another).
        IDLE = 10.0

        # The note a render plays: the clip's first note, else (or with p)
        # the first row whose words match the track's name or its graph's
        # code (the preset or patch it plays).  +hold+ is the note's length
        # in the envelope view as a share of PatchRender.seconds.
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

        # The inspected track's patch and what a copy needs from the live
        # session (gathered by Poll): +track+, +synth+ (the live Synth whose
        # voice block builds the copy, or nil: +note+ says why there is no
        # preview), +clip+ (the track's clip, for its first note), +bpm+,
        # +bar_length+, +key+, +tuning+, +channels+, +note+, +words+ (the
        # track's name and its graph's code, for the role guess), +live+
        # (the live graph's nodes by identity, so a copy that shares one is
        # refused), +frames+ (a Proc giving the live session's
        # Session#frames_rendered, or nil: the heavier steps start right
        # after the render thread finishes a buffer, .slack).
        Source = Data.define(:track, :synth, :clip, :bpm, :bar_length, :key, :tuning, :channels, :note, :words, :live, :frames) do
          def initialize(words: nil, live: nil, synth: nil, frames: nil, **rest) = super(words: words, live: live, synth: synth, frames: frames, **rest)
        end

        # What a render plays: +note+ (a MIDI note number), +velocity+
        # (0..1), +hold+ (seconds held in the envelope view, or nil for the
        # role's share), +kind+ (:clip_note or :guess), +role+, +text+ (for
        # the pane: "first note E1", "bass guess A1"), +id+ (equal when the
        # input is the same).
        Input = Data.define(:note, :velocity, :hold, :kind, :role, :text, :id)

        # One render request: +seq+, +key+ (Driver.key_of), +source+,
        # +input+, +knobs+ (frozen [name, value, Knob::Spec] rows), +seconds+.
        Job = Data.define(:seq, :key, :source, :input, :knobs, :seconds) do
          # What decides whether a Copy can render this job: the voice block,
          # the note, and the session's settings (not knob values).
          def copy_key
            s = source
            [s.synth&.voice_block.object_id, s.synth&.seed, input.note, s.bpm, s.bar_length, s.key, s.tuning.object_id, s.channels].freeze
          end
        end

        # A finished render: +seq+, +key+, +track+; the cycle view's +cycle+
        # (frozen SFloats, one per channel, from a rising zero crossing),
        # +periods+ (how many periods it holds), +settled+ (seconds until
        # the period settled, or nil when it never repeated: unison),
        # +frequency+ (the note's, Hz); the envelope view's +lo+ and +hi+
        # (ENVELOPE-column min/max over the channels) and +frames+; +rate+
        # (the copy's sample rate); +peak+, +rms+ (dBFS), +lufs+ (integrated,
        # -Infinity under 400 ms) of the envelope render; +spectrum+
        # ([frequencies, dB] of the settled sound); +ms+ (the render's time,
        # with the copy's build when it was built for it); +input+ (text);
        # +error+.
        Result = Data.define(:seq, :key, :track, :cycle, :periods, :settled, :frequency, :lo, :hi, :frames, :rate,
                             :peak, :rms, :lufs, :spectrum, :ms, :input, :error)

        # A MIDI source a render plays notes into (see MIDI::Source): #play
        # queues a note-on at the stream's position and its note-off after
        # +length+ seconds.
        class NoteFeed
          include MIDI::Source

          def initialize
            @position = 0r
            @generation = 0
            @jump_pending = false
            @chase = nil
            @node_type_name = nil
            @pending = []
            @sounding = {}
          end

          # Back to stream time +to+ with nothing queued (PatchRender's
          # restore, with the streams and nodes reading it).
          def rewind(to = 0r)
            @position = to
            @jump_pending = false
            @pending = []
            @sounding = {}
            self
          end

          # Plays +note+ (+velocity+ 0..1) from where the stream has read to,
          # for +length+ seconds (nil: until #release).
          def play(note, velocity, length = nil)
            t = position
            @sounding[note] = true
            @pending << MIDI::Event.note_on(note, velocity, time: t)
            @pending << MIDI::Event.note_off(note, time: t + length.to_r) if length
            @pending.sort_by!(&:time)
            self
          end

          # Releases +note+ at the stream's position unless its note-off is
          # already queued.
          def release(note)
            return self if !@sounding[note] || @pending.any? { |e| e.type == :note_off && e.note == note }
            @pending << MIDI::Event.note_off(note, time: position)
            self
          end

          # (No events: the same frozen Array, so blocks without notes make
          # no objects)
          NONE = [].freeze

          def read_events(from, to)
            return NONE if @pending.empty? || @pending[0].time >= to
            out = @pending.take_while { |e| e.time < to }
            @pending = @pending.drop(out.length)
            out.each { |e| @sounding.delete(e.note) if e.type == :note_off }
            out.map { |e| e.time < from ? e.with(time: from) : e }
          end
        end

        # One copy of a voice (see PatchRender): +key+ (Job#copy_key),
        # +scope+ (the Session that gives knob(:x) its knob copies while the
        # voice block runs; it never renders), +feed+ (the NoteFeed),
        # +outputs+ (the voice's output nodes), +states+ ([node, snapshot]
        # pairs from after the build), +streams+ ([MIDI::Stream, ivars] of
        # the note streams after the build), +rate+, +want+ (the rate
        # .rate_for chose; +rate+ differs when the voice couldn't change
        # rate), +work+ (buffers reused by every render), +ms+ (build time),
        # +error+.
        Copy = Struct.new(:key, :scope, :shared, :feed, :outputs, :states, :streams, :start, :rate, :want, :work, :ms, :error, keyword_init: true) do
          # Closes its scope unless the scope is +shared+ (kept by a Worker
          # for the next copy).
          def close
            scope&.close unless shared
            self.scope = nil
          end
        end

        @seconds = SECONDS
        @inline = false
        @clock = nil
        @duty = Float(ENV['MB_SOUND_RENDER_DUTY'] || DUTY)
        @rate = nil

        class << self
          # The length of the envelope view (seconds).
          attr_reader :seconds

          # True: Drivers render on the calling thread (InlineWorker), for
          # specs and the golden captures.
          attr_accessor :inline

          # The share of wall time a Worker render may take (0 < duty <= 1).
          attr_reader :duty

          def duty=(d)
            raise ArgumentError, "duty is a share of wall time, 0 < duty <= 1 (got #{d.inspect})" unless d.is_a?(Numeric) && d > 0 && d <= 1
            @duty = d.to_f
          end

          # A rate every copy runs at instead of .rate_for's (nil: chosen per
          # voice; measurements compare rates with it).
          attr_accessor :rate

          # The clock renders time themselves with (nil: MB::U.clock_now).
          attr_accessor :clock

          # Sets the envelope view's length (seconds within SECONDS_RANGE).
          def seconds=(s)
            unless s.is_a?(Numeric) && SECONDS_RANGE.cover?(s.to_f)
              raise ArgumentError, "Render lengths are #{SECONDS_RANGE.begin}..#{SECONDS_RANGE.end} seconds (got #{s.inspect})"
            end
            @seconds = s.to_f
          end

          # What +source+'s render plays (an Input): the first note of the
          # track's clip (a Kit's first hit's note, a clip's first note's
          # number, velocity, and length), or with +guess+ (or no note) the
          # note of the track's role (ROLES, from Source#words).
          def input(source, seconds, guess: false)
            ev = guess ? nil : first_note(source.clip)
            if ev
              n = note_number(ev.value)
              len = Sequence::TempoMap.seconds_at(ev.length.to_r, source.bpm.to_f)
              return Input.new(note: n, velocity: ev.velocity.to_f, hold: len, kind: :clip_note, role: nil, text: "first note #{note_name(n)}".freeze,
                               id: [:note, n, ev.velocity.to_f, len.round(6)].freeze)
            end
            row = role_of(source.words)
            Input.new(note: row[:note], velocity: 0.8, hold: nil, kind: :guess, role: row[:role], text: "#{row[:role]} guess #{note_name(row[:note])}".freeze,
                      id: [:guess, row[:role], row[:note]].freeze)
          end

          # The ROLES row for +words+ (a String; nil: DEFAULT_ROLE).
          def role_of(words)
            text = words.to_s.downcase
            ROLES.find { |r| r[:words].match?(text) } || DEFAULT_ROLE
          end

          # The rate a copy runs at for lowpass cutoffs +cutoffs+ (Hz; nil in
          # the list: a cutoff that moves, which keeps 48 kHz; an empty list:
          # nothing limits the content, 48 kHz): the lowest of RATES at least
          # RATE_FACTOR times the highest.
          def rate_for(cutoffs)
            return RATES.last if cutoffs.empty? || cutoffs.any?(&:nil?)
            hi = cutoffs.max * RATE_FACTOR
            RATES.find { |r| r >= hi } || RATES.last
          end

          # Renders +job+ and returns a Result.  +cache+ (a Hash the caller
          # keeps) holds the Copy, rebuilt when the job's copy_key changes.
          # +pace+ (Worker renders) sleeps after each block to keep to
          # PatchRender.duty.  Never raises.
          def render(job, cache: {}, pace: false)
            t0 = now
            src = job.source
            Thread.current[:mb_sound_preview_frames] = pace ? src.frames : nil
            slack(src.frames, pace) # (everything from here on in the windows after buffers)
            return failed(job, t0, src.note || 'no voice to copy') if src.synth.nil?
            want = @rate || rate_for(live_cutoffs(job))
            copies = (cache[:copies] ||= {})
            key = [job.copy_key, want]
            copy = copies.delete(key) # (then put back last: the most recent)
            copy ||= build(job, want, pace, cache[:scopes])
            copies[key] = copy
            copies.shift[1].close while copies.length > COPIES
            cache[:copy] = copy
            return failed(job, t0, copy.error) if copy.error

            out = nil
            Internal.strictly { out = play(copy, job, pace) }
            result_of(job, copy, out, t0, pace: pace)
          rescue Exception => e # rubocop:disable Lint/RescueException (a patch's SystemStackError is its result too)
            raise if e.is_a?(Interrupt) || e.is_a?(SystemExit)
            failed(job, t0, "#{e.class}: #{e.message}".lines.first.chomp)
          end

          # The cycle view of channels +data+ (SFloats at +rate+) of a note at
          # +freq+ Hz, sampled from its start: [cycle (per channel, from a
          # rising zero crossing of their mix), periods, settled seconds or
          # nil].  A period has settled once it differs from the period
          # before by less than SETTLED_DB (both scaled to the same RMS);
          # data that never settles within SETTLE_MAX gives UNISON_PERIODS
          # periods from a zero crossing after it.
          def cycle(data, rate, freq)
            mix = mix_of(data)
            settled = settle_scan(mix, rate, freq, mix.length)
            extract(data, mix, rate, freq, settled, SETTLE_MAX)
          end

          # The first period of +mix+ (counting from 2, within its first
          # +frames+ and SETTLE_MAX) that differs from the one before by
          # less than SETTLED_DB (see .cycle), or nil.  Every period at once:
          # rows of a matrix, the next period read a fractional period
          # later (linearly interpolated: periods are rarely whole samples).
          def settle_scan(mix, rate, freq, frames, pace: false)
            period = rate / freq.to_f
            len = period.floor
            top = [frames, mix.length].min
            count = ((top - 2 - len - period) / period).floor
            count = [count, (SETTLE_MAX * rate / period).floor].min
            return nil if count < 1 || len < 2
            # (at most SCAN_POINTS points of each period: enough to see a
            # shape still changing, and few temporary arrays)
            points = [len, SCAN_POINTS].min
            cols = (Numo::DFloat.new(points).seq * (len.to_f / points)).floor.reshape(1, points)
            step = [(SCAN_FRAMES / points), 1].max
            (0...count).step(step) do |first|
              rows = [step, count - first].min
              # Period k - 1 starts at round((k - 1) * period), k = first + 2..
              starts = ((Numo::DFloat.new(rows).seq + (first + 1)) * period).round
              idx = starts.reshape(rows, 1) + cols
              a = mix[Numo::Int64.cast(idx)]
              pos = idx + period
              i0 = pos.floor
              f = pos - i0
              i0 = Numo::Int64.cast(i0)
              b = mix[i0] * (1 - f)
              (b.inplace + mix[i0 + 1] * f).not_inplace!
              ra = Numo::NMath.sqrt((a * a).mean(axis: 1))
              rb = Numo::NMath.sqrt((b * b).mean(axis: 1))
              ok = ra.gt(1e-6) & rb.gt(1e-6)
              d = a / ra.reshape(rows, 1)
              (d.inplace - b / rb.reshape(rows, 1)).not_inplace!
              diff = Numo::NMath.sqrt((d * d).mean(axis: 1))
              hit = (ok & diff.lt(10**(SETTLED_DB / 20.0))).where
              return first + hit[0] + 2 unless hit.empty?
              rest(pace)
            end
            nil
          end

          # The cycle view's [cycle, periods, settled seconds] (see .cycle)
          # from period +settled+ (nil: UNISON_PERIODS periods from +at+
          # seconds, or as late as the data allows).
          def extract(data, mix, rate, freq, settled, at)
            period = rate / freq.to_f
            periods = settled ? 1 : UNISON_PERIODS
            from = settled ? (settled * period).round : [(at * rate).round, mix.length - ((periods + 1) * period).ceil].min
            from = [from, 0].max
            z = rising_zero(mix, from, (from + period).ceil)
            len = (periods * period).round
            len = [len, mix.length - z].min
            [data.map { |d| d[z...(z + len)].dup.freeze }.freeze, periods, settled && (settled * period / rate)]
          end

          # The mean of channels +data+ (a DFloat; into +out+ when given).
          def mix_of(data, out = nil)
            out ||= Numo::DFloat.zeros(data[0].length)
            out.fill(0)
            data.each { |d| (out.inplace + d).not_inplace! }
            (out.inplace / data.length).not_inplace! if data.length > 1
            out
          end

          # The first sample at or after +from+ (before +to+) where +mix+
          # rises through zero (the nearest of the two samples around it), or
          # +from+ without one.
          def rising_zero(mix, from, to)
            to = [to, mix.length - 1].min
            (from...to).each do |i|
              return(mix[i].abs <= mix[i + 1].abs ? i : i + 1) if mix[i] <= 0 && mix[i + 1] > 0
            end
            from
          end

          # [lo, hi]: the min and max of every channel of +data+ in +columns+
          # equal spans (frozen SFloats).
          def envelope(data, columns = ENVELOPE)
            n = data.map(&:length).min.to_i
            lo = Numo::SFloat.zeros(columns)
            hi = Numo::SFloat.zeros(columns)
            return [lo.freeze, hi.freeze] if n == 0
            if n >= columns
              # (whole spans as rows of a matrix; the remainder joins the last)
              m = n / columns
              data.each_with_index do |d, c|
                part = d[0...(m * columns)]
                rows = (part.reshape(columns, m) rescue Numo::SFloat.cast(part).reshape(columns, m)) # (a view of the render's buffer: no copy)
                l = rows.min(axis: 1)
                h = rows.max(axis: 1)
                if n > m * columns
                  rest = d[(m * columns)...n]
                  l[-1] = [l[-1], rest.min].min
                  h[-1] = [h[-1], rest.max].max
                end
                lo = c == 0 ? l : Numo::SFloat.minimum(lo, l)
                hi = c == 0 ? h : Numo::SFloat.maximum(hi, h)
              end
            else
              columns.times do |i|
                a = i * n / columns
                b = [[(i + 1) * n / columns, a + 1].max, n].min
                lo[i] = data.map { |d| d[a...b].min }.min
                hi[i] = data.map { |d| d[a...b].max }.max
              end
            end
            [lo.freeze, hi.freeze]
          end

          private

          # Builds the Copy for +job+ at +rate+ (a voice that can't change
          # rate stays at 48 kHz), in steps with a pause (.rest) between them,
          # so the render thread gets the GVL between steps; only the voice
          # block's own call is one stretch.
          def build(job, rate, pace, scopes = nil)
            t0 = now
            copy = build_at(job, rate, pace, scopes)
            if copy.error && rate != RATES.last && copy.error.start_with?('MB::Sound::GraphNode::SampleRateHelper', 'RuntimeError')
              copy.close unless scopes
              copy = build_at(job, RATES.last, pace, scopes)
            end
            copy.want = rate
            copy.ms = ((now - t0) * 1000).round(1)
            copy
          end

          # One copy of the voice at +rate+ (see .build).
          def build_at(job, rate, pace, scopes = nil)
            src = job.source
            synth = src.synth
            scope = nil
            Internal.strictly do
              Internal.with_private_rng(synth.seed) do
                slack(src.frames, pace)
                scope = scopes ? scope_kept(job, rate, scopes) : scope_for(job, rate)
                rest(pace)
                feed = NoteFeed.new
                v = Notes.new(feed, sustain: false, sample_rate: rate)
                slack(src.frames, pace)
                graph = Session.with_context(session: scope) {
                  Synth.with_lane(0, synth.lanes.length) { MB::Sound.with_seed(synth.seed) { synth.voice_block.call(v, 0) } }
                }
                rest(pace)
                outs = (graph.respond_to?(:outputs) ? graph.outputs.to_a : [graph]).map(&:get_sampler)
                nodes = graph_nodes(outs)
                # Readers of the live knobs (a document param bound to a
                # knob is resolved when the preset loads, so the voice block
                # holds the live Knob) read the copy's knob of that name
                # instead: sampling a live Knob would move it
                nodes.each do |n|
                  next unless n.is_a?(GraphNode::Knob::Reader) && !scope.knobs.value?(n.knob)
                  mine = scope.knobs[n.knob.name] or next
                  n.rebind(mine)
                end
                nodes = graph_nodes(outs)
                live = src.live
                if live && nodes.any? { |n| live.key?(n.__id__) }
                  return Copy.new(key: job.copy_key, scope: scope, shared: !scopes.nil?, error: 'the voice reads nodes made outside it (shared with the live graph): no preview')
                end
                rest(pace)
                slack(src.frames, pace)
                if rate != RATES.last && nodes.any? { |n| n.respond_to?(:sample_rate) && n.sample_rate.to_f != rate }
                  begin
                    outs.each { |o| o.sample_rate = rate }
                  rescue GraphNode::SampleRateHelper::SampleRateSupportError, RuntimeError => e
                    return Copy.new(key: job.copy_key, scope: scope, shared: !scopes.nil?, error: "#{e.class}: #{e.message}")
                  end
                end
                rest(pace)
                slack(src.frames, pace)
                Plan.install(outs)
                rest(pace)
                # One block before any note, so every node has made its state
                # (oscillators make theirs on their first block) before the
                # snapshot every render goes back to
                prime = Copy.new(outputs: outs)
                # (the same time at every rate: oscillators' phases at the note)
                prime.outputs.each { |o| o.sample((CHUNK * rate / 48000.0).round) }
                start = feed.position
                # (knobs and their readers keep counting forward: the values
                # set before each render land on the next frame they read)
                states = nodes.select { |n| n.respond_to?(:plan_snapshot) && !n.is_a?(GraphNode::Knob) && !n.is_a?(GraphNode::Knob::Reader) }
                              .map { |n| [n, n.plan_snapshot] }
                # The note streams go back to stream time 0 with the nodes
                # reading them (their readers' cursors are in the nodes'
                # snapshots)
                streams = streams_of(v).map { |st| [st, stream_state(st)] }
                rest(pace)
                return Copy.new(key: job.copy_key, scope: scope, shared: !scopes.nil?, feed: feed, outputs: outs, states: states, streams: streams,
                                start: start, rate: rate, work: {}, error: nil)
              end
            end
          rescue Exception => e # rubocop:disable Lint/RescueException
            raise if e.is_a?(Interrupt) || e.is_a?(SystemExit)
            Copy.new(key: job.copy_key, scope: scope, shared: !scopes.nil?, error: "#{e.class}: #{e.message}".lines.first.chomp)
          end

          # The nodes of the graph of +outputs+ (numbers left out).
          def graph_nodes(outputs)
            outputs.flat_map { |o| [o, *o.graph(include_tees: true)] }.uniq(&:__id__).reject { |n| n.is_a?(Numeric) }
          end

          # A scope (.scope_for) kept in +scopes+ (a Hash the caller keeps)
          # while the session's settings and the knob specs stay the same: a
          # Session takes 5-30 ms to make, and the copy's knobs are set
          # before every render anyway.
          def scope_kept(job, rate, scopes)
            src = job.source
            key = [src.bpm, src.bar_length, src.key, src.tuning.object_id, src.channels, rate, job.knobs.map { |n, _, sp| [n, sp] }].freeze
            scopes.delete_if { |k, sc| k != key && (sc.close || true) } if scopes.length > 2
            scopes[key] ||= scope_for(job, rate)
          end

          # The Session knob(:x) reads while the voice block builds the copy:
          # the session's tempo, meter, key, tuning, and a copy of every knob,
          # at +rate+ (a live knob read through a document param stays at
          # 48 kHz, so its voice can't change rate: the copy stays at 48 kHz).
          # It never renders (the copy is sampled directly); it is only a
          # namespace for the copy's knobs and build-time tempo.
          def scope_for(job, rate)
            src = job.source
            transport = Sequence::Transport.new(bpm: src.bpm, bar_length: src.bar_length)
            transport.reset_key(src.key) if src.key
            out = NullOutput.new(channels: src.channels, sleep: false, sample_rate: rate) # (the knobs count frames at the copy's rate)
            opts = { output: out, transport: transport, channels: src.channels, realtime: false, raise_errors: true }
            opts[:tuning] = src.tuning if src.tuning
            scope = Session.new(**opts)
            job.knobs.each do |name, value, sp|
              scope.knob(name, value, range: sp.range, curve: sp.curve, unit: sp.unit, takeover: sp.takeover, smooth: sp.smooth)
            end
            scope
          end

          # The lowpass cutoffs (.lowpass_cutoffs) of the live voice the job
          # copies (the Synth's first lane, read without sampling it), knobs
          # at the job's values.
          def live_cutoffs(job)
            graph = job.source.synth.instance_variable_get(:@lane_graphs)&.first
            return [nil] unless graph
            values = job.knobs.to_h { |name, value, _| [name, value] }
            lowpass_cutoffs(graph, values)
          rescue StandardError
            [nil]
          end

          # The cutoffs (Hz, nil for one that moves) of the lowpass filters
          # among +nodes+; knob readers read +values+ (name => value) when
          # given, else the knob.
          def lowpass_cutoffs(nodes, values = {})
            nodes.filter_map { |n|
              lowpass = n.is_a?(GraphNode::FourPole) || (defined?(GraphNode::DiodeLadder) && n.is_a?(GraphNode::DiodeLadder)) ||
                        (n.respond_to?(:preview_data) && (n.preview_data rescue nil).is_a?(Hash) && n.preview_data[:filter_type] == :lowpass)
              next unless lowpass
              v = n.instance_variable_defined?(:@cutoff) ? n.instance_variable_get(:@cutoff) : nil
              v = n.param_info[:cutoff]&.value if v.nil? && n.respond_to?(:param_info)
              v = GraphNode.climb_tee_tree(v) if v.is_a?(GraphNode)
              [v.is_a?(GraphNode::Knob::Reader) && values.key?(v.knob.name) ? values[v.knob.name].to_f : held_value(v)]
            }.flatten(1)
          end

          # +v+ as Hz if it holds still (a number, a Constant, a knob), else
          # nil.
          def held_value(v)
            case v
            when Numeric then v.to_f
            when GraphNode::Knob::Reader then v.knob.value.to_f
            when GraphNode::Knob then v.value.to_f
            when GraphNode::Constant then v.constant.to_f
            end
          rescue StandardError
            nil
          end

          # Plays the note once from the copy's state after its build, held
          # for the clip note's length (or the role's share of the envelope
          # view), for the envelope view's length or as long as the cycle
          # view needs (SETTLE_MAX of the held note, and a few periods):
          # [cycle, envelope data, the held sound after the cycle (for the
          # spectrum), freq].  Every buffer is the copy's own (Copy#work).
          def play(copy, job, pace)
            rate = copy.rate
            freq = (job.source.tuning || Tuning.default).frequency_of(job.input.note).to_f
            hold = job.input.hold || job.seconds * role_of(job.source.words)[:hold]
            held = (hold * rate).floor
            show = (job.seconds * rate).round
            need = ([SETTLE_MAX, hold.to_f].min * rate + (UNISON_PERIODS + 2) * rate / freq).ceil
            frames = [show, need].max

            restore(copy)
            set_knobs(copy, job)
            copy.feed.play(job.input.note, job.input.velocity, hold)
            work = copy.work
            padded = (frames + CHUNK - 1) / CHUNK * CHUNK
            unless work[:bufs] && work[:bufs][0].length >= padded
              work[:bufs] = copy.outputs.map { Numo::SFloat.zeros(padded) }
              work[:mix] = Numo::DFloat.zeros(padded)
            end
            bufs = work[:bufs]
            mix = work[:mix]
            run(copy, frames, pace, into: bufs, at: 0)
            copy.feed.release(job.input.note)
            data = bufs.map { |b| b[0...frames] }
            m = mix_of(data, mix[0...frames])
            rest(pace)
            settled = settle_scan(m, rate, freq, held, pace: pace)
            rest(pace)
            at = [SETTLE_MAX, hold.to_f - (UNISON_PERIODS + 1) / freq].min
            cyc = extract(data, m, rate, freq, settled, [at, 0].max)
            from = settled ? (settled * rate / freq).round : [(at * rate).round, 0].max
            to = [[held, frames].min, from + 1].max
            tail = data.map { |d| d[from...to] }
            [cyc, data.map { |d| d[0...[show, frames].min] }, tail, freq]
          end

          # Puts every node's state, the note streams, and the feed back as
          # they were after the build (stream time 0, nothing read).
          def restore(copy)
            copy.feed.rewind(copy.start)
            copy.streams.each { |st, ivars| Marshal.load(ivars).each { |iv, val| st.instance_variable_set(iv, val) } }
            copy.states.each { |n, snap| n.plan_restore(snap) }
          end

          # Stream instance variables that aren't state (kept as they are).
          STREAM_KEEP = %i[@source @readers @spies @spy_session @graph_node_name].freeze

          # +st+'s state (Marshal data of its instance variables but
          # STREAM_KEEP).
          def stream_state(st)
            Marshal.dump((st.instance_variables - STREAM_KEEP).to_h { |iv| [iv, st.instance_variable_get(iv)] })
          end

          # The MIDI::Streams +notes+ reads, through transforms to the feed.
          def streams_of(notes)
            out = []
            [notes.instance_variable_get(:@stream), notes.instance_variable_get(:@control_stream)].each do |st|
              while st.is_a?(MIDI::Stream)
                out << st unless out.any? { |x| x.equal?(st) }
                st = st.instance_variable_get(:@source)
              end
            end
            out
          rescue NoMethodError
            out
          end

          # Sets the copy's knobs to the job's values (exact jumps).
          def set_knobs(copy, job)
            have = copy.scope.knobs
            job.knobs.each do |name, value, _|
              k = have[name] or next
              k.set(value, frame: k.next_frame, smooth: 0)
            end
          end

          # Samples +frames+ frames of the copy's outputs in CHUNK blocks:
          # into +into+ (an SFloat per output, from +at+, at least +frames+
          # rounded up to whole blocks long), else new SFloats.  Each block
          # is copied without views (FastArithmetic.copy_range), so a block
          # makes no objects of its own.  Pauses after each block (.rest).
          def run(copy, frames, pace, into: nil, at: 0)
            outs = copy.outputs
            blocks = (frames + CHUNK - 1) / CHUNK
            into ||= outs.map { Numo::SFloat.zeros(blocks * CHUNK) }
            blocks.times do |k|
              t = MB::U.clock_now
              off = at + k * CHUNK
              outs.each_with_index do |o, i|
                d = o.sample(CHUNK)
                next if d.nil?
                FastArithmetic.copy_range(into[i], off, d, 0, CHUNK) || (into[i][off...(off + CHUNK)] = d)
              end
              rest(pace, MB::U.clock_now - t)
            end
            into
          end

          # Waits (up to +timeout+ seconds, in short sleeps) for the live
          # render thread to finish a buffer (+frames+, Source#frames,
          # changes), so the work that follows runs while the render thread
          # waits on its output, and starts the thread's work window (see
          # .rest).  Without +frames+ (or +pace+), returns at once.
          def slack(frames, pace, timeout = 0.05)
            return unless frames && pace
            st = (Thread.current[:mb_sound_preview_slack] ||= { period: nil, step: nil, frame: nil, at: nil, window: nil })
            f0 = frames.call
            t0 = MB::U.clock_now
            deadline = t0 + timeout
            # (when this buffer's end was seen, most of the way to the next
            # one in one sleep, then short looks: each look takes the GVL for
            # a moment)
            if st[:period] && st[:frame] == f0
              ahead = st[:at] + st[:period] * 0.75 - t0
              sleep([ahead, timeout].min) if ahead > 0.0005
            end
            sleep(0.0005) while frames.call == f0 && MB::U.clock_now < deadline
            now = MB::U.clock_now
            f1 = frames.call
            if f1 != f0
              d = f1 - f0
              # (the time between buffers, from two buffer ends seen one
              # after the other; the window is a share of it)
              if st[:frame] == f0 && st[:at] && (st[:step].nil? || d <= st[:step])
                st[:step] = d
                dt = now - st[:at]
                st[:period] = st[:period] ? st[:period] * 0.8 + dt * 0.2 : dt if dt < 0.2
              end
            end
            st[:frame] = f1
            st[:at] = now
            st[:window] = now
          end

          # The share of the time between the render thread's buffers a
          # Worker works in, right after one (the rest of it the render
          # thread has the GVL to itself), and the bounds of that window.
          WINDOW_SHARE = 0.35
          WINDOW_MIN = 0.0004
          WINDOW_MAX = 0.004

          # Gives the GVL to the other threads after +busy+ seconds of work.
          # Worker renders (+pace+) following a live Session (+frames+, the
          # render's Source#frames): work in windows right after each buffer
          # the render thread finishes (WINDOW_SHARE of the time between
          # buffers), waiting for the next buffer once a window is used up.
          # Without +frames+, a sleep keeping to PatchRender.duty; else
          # Thread.pass.
          def rest(pace, busy = 0.0005, frames: Thread.current[:mb_sound_preview_frames])
            if pace && frames
              st = Thread.current[:mb_sound_preview_slack]
              return slack(frames, pace) unless st && st[:window]
              window = ((st[:period] || 0.01) * WINDOW_SHARE).clamp(WINDOW_MIN, WINDOW_MAX)
              if MB::U.clock_now - st[:window] > window
                slack(frames, pace)
              else
                Thread.pass
              end
            elsif pace && @duty < 1
              sleep([busy * (1 - @duty) / @duty, 0.0001].max)
            else
              Thread.pass
            end
          end

          def result_of(job, copy, out, t0, pace: false)
            cyc, env, tail, freq = out
            cycle_data, periods, settled = cyc
            rate = copy.rate
            lo, hi = envelope(env)
            peak = env.map { |d| d.abs.max.to_f }.max.to_f
            sum = env.sum { |d| (d * d).sum.to_f }
            count = env.sum(&:length)
            rms = count > 0 ? Math.sqrt(sum / count) : 0.0
            rest(pace)
            lufs = loudness(env, rate, pace, copy.work)
            rest(pace)
            Result.new(seq: job.seq, key: job.key, track: job.source.track, cycle: cycle_data, periods: periods, settled: settled, frequency: freq,
                       lo: lo, hi: hi, frames: env[0].length, rate: rate, peak: db(peak), rms: db(rms), lufs: lufs,
                       spectrum: spectrum(tail, rate, pace: pace, work: copy.work), ms: ((now - t0) * 1000).round(1), input: job.input.text, error: nil)
          end

          # The integrated loudness of +data+ (LUFS; -Infinity under 400 ms):
          # BS.1770 K-weighting (the filters kept per rate and channel count
          # in +work+), 400 ms blocks every 100 ms, the absolute and relative
          # gates (Loudness.gate), with the block energies from one running
          # sum (Loudness::Analyzer makes a few hundred objects per call).
          def loudness(data, rate, pace, work = {})
            n = data.map(&:length).min.to_i
            size = (0.4 * rate).round
            return -Float::INFINITY if n < size
            filters = (work[[:k_weighting, rate, data.length]] ||= Array.new(data.length) { Loudness.k_weighting(rate) })
            weights = Loudness.default_weights(data.length)
            x = work[:lufs_x]
            z = work[:lufs_z]
            if x.nil? || x.length != n
              x = work[:lufs_x] = Numo::DFloat.zeros(n)
              z = work[:lufs_z] = Numo::DFloat.zeros(n)
            end
            z.fill(0)
            any = false
            data.each_with_index do |d, c|
              next if weights[c] == 0
              shelf, highpass = filters[c]
              shelf.reset
              highpass.reset
              x[true] = d[0...n]
              # (the biquads work in place on an in-place array: no buffers
              # made per render)
              shelf.process(x.inplace)
              highpass.process(x.inplace)
              x.not_inplace!
              (x.inplace * x).not_inplace!
              (x.inplace * weights[c]).not_inplace! if weights[c] != 1
              (z.inplace + x).not_inplace!
              any = true
              rest(pace)
            end
            return -Float::INFINITY unless any
            hop = (0.1 * rate).round
            energies = Numo::DFloat.cast(((n - size) / hop + 1).times.map { |k| z[(k * hop)...(k * hop + size)].sum / size })
            Loudness.gate(energies)[0]
          end

          # [frequencies, dB] of +data+'s average spectrum (the channels
          # mixed; Hann windows, half overlapped, of up to 2048 samples; a
          # full-scale sine reads 0 dB), at SPECTRUM_POINTS log-spaced
          # frequencies from 20 Hz to Nyquist (the loudest bin near each).
          # The window, the band index matrix, and the work arrays are kept
          # per length and rate (+work+, a Hash).
          def spectrum(data, rate, n = 2048, pace: false, work: {})
            len = data.map(&:length).min.to_i
            n /= 2 while len < n && n > 256
            return nil if len < n
            tables = (work[[:spectrum, n, rate]] ||= spectrum_tables(n, rate))
            w, bands, f, mono, acc, seg = tables
            mono = tables[3] = Numo::DFloat.zeros(len) if mono.length < len
            mono = mix_of(data.map { |d| d[0...len] }, mono[0...len])
            acc.fill(0)
            count = 0
            # (the last SPECTRUM_WINDOWS windows: the sound has settled)
            starts = (0..len - n).step(n / 2).to_a.last(SPECTRUM_WINDOWS)
            starts.each do |a|
              seg[true] = mono[a...(a + n)]
              (seg.inplace * w).not_inplace!
              mag = Numo::Pocketfft.rfft(seg).abs
              (mag.inplace * mag).not_inplace!
              (acc.inplace + mag).not_inplace!
              count += 1
              rest(pace)
            end
            mag = Numo::NMath.sqrt(acc / count)
            (mag.inplace * (2.0 / w.sum)).not_inplace!
            db = 20 * Numo::NMath.log10(mag.clip(1e-5, nil))
            db = db.concatenate(Numo::DFloat[-Float::INFINITY]) # (the pad the band matrix points at)
            [f, db[bands].max(axis: 1).freeze].freeze
          rescue StandardError
            nil
          end

          # [window, band index matrix (SPECTRUM_POINTS rows of bin indices,
          # padded with the index past the last bin), band centers (frozen),
          # a mix buffer, a power accumulator, a window buffer] for .spectrum.
          def spectrum_tables(n, rate)
            w = 0.5 - 0.5 * Numo::NMath.cos(Numo::DFloat.new(n).seq * (2 * Math::PI / n))
            df = rate.to_f / n
            edges = Numo::DFloat.logspace(Math.log10(20.0), Math.log10(rate / 2.0), SPECTRUM_POINTS + 1)
            ranges = SPECTRUM_POINTS.times.map { |i|
              a = (edges[i] / df).round.clamp(1, n / 2)
              b = [(edges[i + 1] / df).round, a + 1].max.clamp(a + 1, n / 2 + 1)
              (a...b)
            }
            width = ranges.map(&:size).max
            pad = n / 2 + 1
            bands = Numo::Int64.new(SPECTRUM_POINTS, width).fill(pad)
            ranges.each_with_index { |r, i| bands[i, 0...r.size] = Numo::Int64.cast(r.to_a) }
            f = Numo::DFloat.cast(SPECTRUM_POINTS.times.map { |i| Math.sqrt(edges[i] * edges[i + 1]) }).freeze
            [w, bands, f, Numo::DFloat.zeros(0), Numo::DFloat.zeros(n / 2 + 1), Numo::DFloat.zeros(n)]
          end

          def note_number(v)
            v.respond_to?(:number) ? v.number.round : v.to_f.round
          end

          def note_name(n)
            "#{Poll::NOTE_NAMES[n % 12]}#{n / 12 - 1}"
          end

          # The first event with a note of +clip+ (a Clip, or a Kit's rows),
          # or nil.
          def first_note(clip)
            return nil if clip.nil?
            clips = clip.respond_to?(:rows) ? clip.rows.values : [clip]
            evs = clips.flat_map { |c| Array(c.send(:first_cycle_events)) rescue Array(c.events) }
            evs.select { |e| e.value.is_a?(Numeric) || e.value.respond_to?(:number) }.min_by(&:start)
          rescue StandardError
            nil
          end

          def now = @clock ? @clock.call : MB::U.clock_now

          def db(x) = x > 0 ? 20 * Math.log10(x) : -Float::INFINITY

          def failed(job, t0, why)
            Result.new(seq: job.seq, key: job.key, track: job.source.track, cycle: nil, periods: nil, settled: nil, frequency: nil,
                       lo: nil, hi: nil, frames: 0, rate: nil, peak: nil, rms: nil, lufs: nil, spectrum: nil,
                       ms: ((now - t0) * 1000).round(1), input: job.input&.text, error: why.to_s.freeze)
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
            @cache = { scopes: {} } # (PatchRender.render: the Copy, and the scopes kept for the next one)
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

          # (worker thread, holding the mutex) Closes the kept copy.
          def drop_copy
            @cache.delete(:copy)
            @cache.delete(:copies)&.each_value(&:close)
            @cache.delete(:scopes)&.each_value(&:close)
            @cache.clear
            @cache[:scopes] = {}
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
                    drop_copy
                    return
                  end
                  @cond.wait(@mutex, left)
                end
                if @closed
                  @thread = nil
                  drop_copy
                  return
                end
                @running = true
                j = @job
                @job = nil
                j
              }
              r = PatchRender.render(job, cache: @cache, pace: true)
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
          # voice block by identity, the input (PatchRender.input's id), the
          # length, and the values of the knobs the graph reads (+read+:
          # names).
          def self.key_of(source, input, knobs, read, seconds)
            values = read.map { |n| knobs.find { |k| k.name == n }&.value }
            [source.track, source.synth&.voice_block.object_id, input.id, seconds, *values].freeze
          end

          # The Input for +source+ now (kept while its clip, words, the guess
          # flag, and the length stay the same).
          def input_for(source)
            of = [source.clip.object_id, source.words, @guess, source.bpm]
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
