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
      # filter and envelope states), plays the note, and:
      #
      # - samples whole periods of the note until a period's shape stops
      #   changing (the filters settled), then keeps that period from a
      #   rising zero crossing; when no period repeats (detuned unison
      #   copies), a few periods from a zero crossing after the longest
      #   settle time (.cycle);
      # - plays the note again from the same state for PatchRender.seconds
      #   (with the role's hold) for the envelope view and the figures.
      #
      # The copy runs at the lowest of RATES that keeps every lowpass
      # cutoff under 1/RATE_FACTOR of the rate (.rate_for), else (moving
      # cutoffs, no lowpass, a voice that can't change rate) 48 kHz.
      #
      # It runs in this process on a Worker thread at low priority, in
      # CHUNK-frame blocks with the GVL passed between them, sleeping to
      # keep to PatchRender.duty; never on the painter or render thread,
      # never under the render lock, never sampling the live graph.
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
        # blocks).
        CHUNK = 128

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
        # refused).
        Source = Data.define(:track, :synth, :clip, :bpm, :bar_length, :key, :tuning, :channels, :note, :words, :live) do
          def initialize(words: nil, live: nil, synth: nil, **rest) = super(words: words, live: live, synth: synth, **rest)
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

          def read_events(from, to)
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
        # the note streams after the build), +rate+, +ms+ (build time),
        # +error+.
        Copy = Struct.new(:key, :scope, :feed, :outputs, :states, :streams, :start, :rate, :ms, :error, keyword_init: true) do
          def close
            scope&.close
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
              len = ev.length.to_r * 240 / source.bpm.to_f
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
            return failed(job, t0, src.note || 'no voice to copy') if src.synth.nil?
            copy = cache[:copy]
            unless copy && copy.key == job.copy_key
              copy&.close
              copy = cache[:copy] = build(job)
            end
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
            settled, = settle_scan(mix, rate, freq, 2)
            extract(data, mix, rate, freq, settled)
          end

          # Scans periods +k+, k + 1, ... of +mix+ (see .cycle) as far as it
          # reaches (and no further than SETTLE_MAX): [the settled period's
          # number, or nil; the next period to scan].
          def settle_scan(mix, rate, freq, k)
            period = rate / freq.to_f
            len = period.floor
            idx = Numo::DFloat.new(len).seq
            while ((k + 1) * period).ceil + 1 < mix.length && k * period <= SETTLE_MAX * rate
              s0 = ((k - 1) * period).round
              a = mix[s0...(s0 + len)]
              # (the next period read a fractional period later, linearly
              # interpolated: periods are rarely whole samples)
              pos = idx + (s0 + period)
              i0 = Numo::Int64.cast(pos.floor)
              f = pos - pos.floor
              b = mix[i0] * (1 - f) + mix[i0 + 1] * f
              ra = Math.sqrt((a**2).mean)
              rb = Math.sqrt((b**2).mean)
              if ra > 1e-6 && rb > 1e-6
                diff = Math.sqrt(((a / ra - b / rb)**2).mean)
                return [k, k + 1] if 20 * Math.log10(diff + 1e-12) < SETTLED_DB
              end
              k += 1
            end
            [nil, k]
          end

          # The cycle view's [cycle, periods, settled seconds] (see .cycle)
          # from period +settled+ (nil: UNISON_PERIODS periods from
          # SETTLE_MAX or the end).
          def extract(data, mix, rate, freq, settled)
            period = rate / freq.to_f
            periods = settled ? 1 : UNISON_PERIODS
            from = settled ? (settled * period).round : [(SETTLE_MAX * rate).round, mix.length - ((periods + 1) * period).ceil].min
            from = [from, 0].max
            z = rising_zero(mix, from, (from + period).ceil)
            len = (periods * period).round
            len = [len, mix.length - z].min
            [data.map { |d| d[z...(z + len)].dup.freeze }.freeze, periods, settled && (settled * period / rate)]
          end

          # The mean of channels +data+ (a DFloat).
          def mix_of(data)
            data.length == 1 ? Numo::DFloat.cast(data[0]) : data.sum { |d| Numo::DFloat.cast(d) } / data.length
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
                rows = Numo::SFloat.cast(d[0...(m * columns)]).reshape(columns, m)
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

          # Builds the Copy for +job+: the voice at 48 kHz, its lowpass
          # cutoffs read for the rate (.rate_for), and when that is lower,
          # the voice built again and set to it (a voice that can't change
          # rate stays at 48 kHz).
          def build(job)
            t0 = now
            copy = build_at(job, RATES.last)
            return copy if copy.error
            rate = @rate || rate_for(lowpass_cutoffs(copy.outputs))
            if rate != RATES.last
              low = build_at(job, rate)
              if low.error
                low.close
              else
                copy.close
                copy = low
              end
            end
            copy.ms = ((now - t0) * 1000).round(1)
            copy
          end

          # One copy of the voice at +rate+ (see .build).
          def build_at(job, rate)
            src = job.source
            synth = src.synth
            scope = nil
            Internal.strictly do
              Internal.with_private_rng(synth.seed) do
                scope = scope_for(job, rate)
                feed = NoteFeed.new
                v = Notes.new(feed, sustain: false, sample_rate: rate)
                graph = Session.with_context(session: scope) {
                  Synth.with_lane(0, synth.lanes.length) { MB::Sound.with_seed(synth.seed) { synth.voice_block.call(v, 0) } }
                }
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
                  return Copy.new(key: job.copy_key, scope: scope, error: 'the voice reads nodes made outside it (shared with the live graph): no preview')
                end
                if rate != RATES.last && nodes.any? { |n| n.respond_to?(:sample_rate) && n.sample_rate.to_f != rate }
                  begin
                    outs.each { |o| o.sample_rate = rate }
                  rescue GraphNode::SampleRateHelper::SampleRateSupportError, RuntimeError => e
                    return Copy.new(key: job.copy_key, scope: scope, error: "#{e.class}: #{e.message}")
                  end
                end
                Plan.install(outs)
                # One block before any note, so every node has made its state
                # (oscillators make theirs on their first block) before the
                # snapshot every render goes back to
                prime = Copy.new(outputs: outs)
                run(prime, (CHUNK * rate / 48000.0).round, false) # (the same time at every rate: oscillators' phases at the note)
                start = feed.position
                # (knobs and their readers keep counting forward: the values
                # set before each render land on the next frame they read)
                states = nodes.select { |n| n.respond_to?(:plan_snapshot) && !n.is_a?(GraphNode::Knob) && !n.is_a?(GraphNode::Knob::Reader) }
                              .map { |n| [n, n.plan_snapshot] }
                # The note streams go back to stream time 0 with the nodes
                # reading them (their readers' cursors are in the nodes'
                # snapshots)
                streams = streams_of(v).map { |st| [st, stream_state(st)] }
                return Copy.new(key: job.copy_key, scope: scope, feed: feed, outputs: outs, states: states, streams: streams, start: start, rate: rate, error: nil)
              end
            end
          rescue Exception => e # rubocop:disable Lint/RescueException
            raise if e.is_a?(Interrupt) || e.is_a?(SystemExit)
            Copy.new(key: job.copy_key, scope: scope, error: "#{e.class}: #{e.message}".lines.first.chomp)
          end

          # The nodes of the graph of +outputs+ (numbers left out).
          def graph_nodes(outputs)
            outputs.flat_map { |o| [o, *o.graph(include_tees: true)] }.uniq(&:__id__).reject { |n| n.is_a?(Numeric) }
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

          # The cutoffs (Hz, nil for one that moves) of the lowpass filters in
          # the graph of +outputs+.
          def lowpass_cutoffs(outputs)
            nodes = outputs.flat_map { |o| [o, *o.graph] }.uniq(&:__id__)
            nodes.filter_map { |n|
              lowpass = n.is_a?(GraphNode::FourPole) || (defined?(GraphNode::DiodeLadder) && n.is_a?(GraphNode::DiodeLadder)) ||
                        (n.respond_to?(:preview_data) && (n.preview_data rescue nil).is_a?(Hash) && n.preview_data[:filter_type] == :lowpass)
              next unless lowpass
              v = n.respond_to?(:param_info) ? n.param_info[:cutoff]&.value : nil
              v = n.instance_variable_get(:@cutoff) if v.nil? && n.instance_variable_defined?(:@cutoff)
              [held_value(v)]
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

          # Renders the cycle view and the envelope view from the copy's
          # state after its build: [cycle data, envelope data, settled
          # samples for the spectrum].
          def play(copy, job, pace)
            rate = copy.rate
            freq = (job.source.tuning || Tuning.default).frequency_of(job.input.note).to_f

            restore(copy)
            set_knobs(copy, job)
            copy.feed.play(job.input.note, job.input.velocity)
            # (in pieces of a few periods, stopping a period after the one
            # that settled)
            limit = ((SETTLE_MAX + (UNISON_PERIODS + 2) / freq) * rate).ceil
            piece = [(4 * rate / freq).ceil, CHUNK].max
            bufs = copy.outputs.map { Numo::SFloat.zeros(limit) }
            mix = Numo::DFloat.zeros(limit)
            got = 0
            k = 2
            settled = nil
            while got < limit
              n = [piece, limit - got].min
              run(copy, n, pace, into: bufs, at: got)
              bufs.each { |b| mix[got...(got + n)] += b[got...(got + n)] }
              got += n
              settled, k = settle_scan(mix[0...got], rate, freq, k) unless settled
              rest(pace)
              break if settled && got >= ((settled + 3) * rate / freq).ceil
            end
            copy.feed.release(job.input.note)
            settle = bufs.map { |b| b[0...got] }
            mix = mix[0...got] / bufs.length
            cyc = extract(settle, mix, rate, freq, settled)
            rest(pace)

            restore(copy)
            set_knobs(copy, job)
            hold = job.input.hold || job.seconds * (role_of(job.source.words)[:hold])
            copy.feed.play(job.input.note, job.input.velocity, [hold, job.seconds].min)
            frames = (job.seconds * rate).round
            env = copy.outputs.map { Numo::SFloat.zeros(frames) }
            run(copy, frames, pace, into: env, at: 0)
            copy.feed.release(job.input.note)
            [cyc, env, settle, freq]
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
          # into +into+ (an SFloat per output, from +at+), else new SFloats.
          # Pauses after each block (.rest).
          def run(copy, frames, pace, into: nil, at: 0)
            outs = copy.outputs
            into ||= outs.map { Numo::SFloat.zeros(frames) }
            off = at
            left = frames
            while left > 0
              n = [CHUNK, left].min
              t = MB::U.clock_now
              outs.each_with_index do |o, i|
                d = o.sample(n)
                into[i][off...(off + n)] = d unless d.nil?
              end
              off += n
              left -= n
              rest(pace, MB::U.clock_now - t)
            end
            into
          end

          # Gives the GVL to the other threads after +busy+ seconds of work:
          # with +pace+ (Worker renders) a sleep keeping to PatchRender.duty
          # (at least a pass), else Thread.pass.
          def rest(pace, busy = 0.0005)
            if pace && @duty < 1
              sleep([busy * (1 - @duty) / @duty, 0.0001].max)
            else
              Thread.pass
            end
          end

          def result_of(job, copy, out, t0, pace: false)
            cyc, env, settle, freq = out
            cycle_data, periods, settled = cyc
            rate = copy.rate
            lo, hi = envelope(env)
            rest(pace)
            peak = env.map { |d| d.abs.max.to_f }.max.to_f
            sum = env.sum { |d| (Numo::DFloat.cast(d)**2).sum }
            count = env.sum(&:length)
            rms = count > 0 ? Math.sqrt(sum / count) : 0.0
            lufs = loudness(env, rate, pace)
            rest(pace)
            tail = settle.map { |d| d[(d.length / 2)..].dup }
            Result.new(seq: job.seq, key: job.key, track: job.source.track, cycle: cycle_data, periods: periods, settled: settled, frequency: freq,
                       lo: lo, hi: hi, frames: env[0].length, rate: rate, peak: db(peak), rms: db(rms), lufs: lufs,
                       spectrum: spectrum(tail, rate, pace: pace), ms: ((now - t0) * 1000).round(1), input: job.input.text, error: nil)
          end

          # The integrated loudness of +data+ (LUFS; -Infinity under 400 ms),
          # measured a tenth of a second at a time (.rest between).
          def loudness(data, rate, pace)
            n = data[0].length
            return -Float::INFINITY if n < rate * 0.4
            an = Loudness::Analyzer.new(channels: data.length, sample_rate: rate, true_peak: false)
            step = (rate / 10).round
            (0...n).step(step) do |a|
              an.process(data.map { |d| d[a...[a + step, n].min] })
              rest(pace)
            end
            an.result.integrated.to_f
          end

          # [frequencies, dB] of +data+'s average spectrum (the channels
          # mixed; Hann windows, half overlapped, of up to 4096 samples; a
          # full-scale sine reads 0 dB), at SPECTRUM_POINTS log-spaced
          # frequencies from 20 Hz to Nyquist (the loudest bin near each).
          def spectrum(data, rate, n = 4096, pace: false)
            mono = data.length == 1 ? Numo::DFloat.cast(data[0]) : data.sum { |d| Numo::DFloat.cast(d) } / data.length
            n = 2**Math.log2(mono.length).floor while mono.length < n && n > 256
            return nil if mono.length < n
            w = 0.5 - 0.5 * Numo::NMath.cos(Numo::DFloat.new(n).seq * (2 * Math::PI / n))
            acc = Numo::DFloat.zeros(n / 2 + 1)
            count = 0
            (0..mono.length - n).step(n / 2) do |a|
              acc += Numo::Pocketfft.rfft(mono[a...(a + n)] * w).abs**2
              count += 1
              rest(pace)
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
              rest(pace) if i % 64 == 63
            end
            [f.freeze, out.freeze].freeze
          rescue StandardError
            nil
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
            @cache = {} # (PatchRender.render: the Copy)
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
            @cache.delete(:copy)&.close
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
