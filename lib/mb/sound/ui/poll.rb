module MB
  module Sound
    module UI
      # Gathers Slow data on the painter thread a few times a second, from
      # Session APIs that never take the render lock: the arrangement's
      # tracks, scenes, and armed tracks (its own mutex), the journal's
      # queued changes (its own mutex; reading it folds the render
      # thread's notes), the form (its own lock), and the knobs (the knob
      # lock).  Session#players, #strip_info, and #clock are avoided (render
      # lock); players and their states come from the per-buffer Snapshot.
      class Poll
        # Queued changes kept.
        QUEUED = 8

        # Landed changes kept (the log pane).
        LANDED = 40

        # MIDI events kept (the MIDI pane).
        MIDI_EVENTS = 24

        # Columns of a clip's one-line pattern.
        PATTERN = 32

        # Note names by pitch class (the MIDI pane).
        NOTE_NAMES = %w[C C# D D# E F F# G G# A A# B].freeze

        def initialize(session)
          @session = session
          # Queued changes and recordings, kept from the journal's new
          # entries (reading all of #changes grows with the session)
          @open = {}
          @landed = []
          @clip_cache = {}.compare_by_identity
          @midi_seen = nil
          @midi_events = []
          @ccs = {}
          @lock = Mutex.new
          @subscription = session.journal.subscribe { |e| note(e) }
          session.journal.changes.each { |e| note(e, seen: false) }
        end

        # Stops following the journal.
        def close
          @session.journal.unsubscribe(@subscription) if @subscription
          @subscription = nil
        end

        # A new Slow, and the knobs to read per buffer ([name, knob] pairs)
        # for Feed#knob_refs=.
        def call
          s = @session
          arr = s.arrangement
          armed = arr.armed.keys.freeze
          tracks = arr.tracks.map { |name, tr|
            TrackInfo.new(name: name, q: (tr.q || arr.quant).inspect.freeze, clip: (tr.patch? ? (tr.clip ? arr.name_of(tr.clip) : 'no clip') : 'graph').freeze, armed: armed.include?(name))
          }.freeze

          s.journal.fold # new entries reach #note
          changes = @lock.synchronize { @open.values }
          pos = s.transport.position
          queued = changes.select { |e| e.status == :queued }.last(QUEUED).map { |e|
            QueuedInfo.new(seq: e.seq, kind: e.kind, subject: e.subject, lands: e.lands.to_s.freeze, pos: e.lands&.pos)
          }.freeze
          recording = changes.select { |e| e.kind == :rec && e.status != :failed && e.status != :cancelled }.filter_map { |e|
            ends = e.data[:ends]
            next if ends.nil? || ends.pos.nil? || ends.pos <= pos
            RecordingInfo.new(name: e.subject, ends: ends.to_s.freeze, pos: ends.pos, queued: e.status == :queued)
          }.freeze

          knobs = s.knobs
          landed = @lock.synchronize { @landed.dup.freeze }
          slow = Slow.new(
            tracks: tracks,
            scenes: arr.scenes.keys.freeze,
            scene: arr.current_scene,
            queued: queued,
            recording: recording,
            armed: armed,
            form: form_info(arr.playback),
            knob_specs: knobs.transform_values(&:spec).freeze,
            buses: bus_infos(s),
            routes: (s.routes.freeze rescue {}.freeze),
            landed: landed,
            clips: clip_infos(arr),
            midi: midi_info(s, knobs)
          )
          [slow, knobs.to_a.freeze]
        end

        private

        # The buses (Session#bus_info: its own mutex).
        def bus_infos(s)
          s.bus_info.map { |name, desc|
            to = desc[/\(to (\S+?)[,)]/, 1]&.to_sym || :master
            BusInfo.new(name: name, to: to, description: desc.sub(/ \(to .*\z/, '').freeze, asleep: desc.include?(', asleep'), muted: desc.include?(', muted'))
          }.freeze
        rescue StandardError
          [].freeze
        end

        # The clips the set uses (tracks' clips and scenes' values), each
        # with a one-line pattern (cached: clips are immutable).
        def clip_infos(arr)
          used = Hash.new { |h, k| h[k] = [] }.compare_by_identity
          arr.tracks.each { |name, tr| used[tr.clip] << name if tr.respond_to?(:clip) && clip_like?(tr.clip) }
          arr.scenes.each_value do |sc|
            (sc.values || {}).each_value { |v| used[v] << sc.name if clip_like?(v) }
          end
          used.map { |clip, where|
            info = (@clip_cache[clip] ||= clip_info(arr, clip))
            info.with(used: where.uniq.freeze)
          }.sort_by { |c| [c.name.to_s, c.kind.to_s] }.freeze
        rescue StandardError
          [].freeze
        end

        def clip_like?(v) = v.respond_to?(:events) && v.respond_to?(:length) && !v.is_a?(Symbol)

        def clip_info(arr, clip)
          len = clip.length.to_r
          bar = (@session.transport.bar_length rescue 1r).to_r
          events = (clip.respond_to?(:first_cycle_events) ? clip.first_cycle_events : clip.events) rescue clip.events
          cells = Array.new(PATTERN, ' ')
          if len > 0
            Array(events).each do |e|
              a = (e.start.to_r / len * PATTERN).floor
              b = ((e.start.to_r + e.length.to_r) / len * PATTERN).ceil
              next unless a >= 0 && a < PATTERN
              (a + 1...[b, PATTERN].min).each { |i| cells[i] = '─' if cells[i] == ' ' }
              cells[a] = '█'
            end
          end
          ClipInfo.new(name: arr.name_of(clip).freeze, kind: clip.class.name.split('::').last.downcase.to_sym,
                       bars: bar > 0 ? (len / bar) : len, pattern: cells.join.freeze, used: [].freeze)
        end

        # Recent MIDI from the Session's log (its own lock), read from where
        # the last poll stopped: events as text, the last value of each
        # controller, and the knobs mapped to controllers.
        def midi_info(s, knobs)
          n = s.midi_log_length
          @midi_seen = [n - MIDI_EVENTS, 0].max if @midi_seen.nil? || @midi_seen > n
          if n > @midi_seen
            s.midi_log(@midi_seen).each do |name, _epoch, pos, bytes|
              st, d1, d2 = bytes
              next unless st
              kind, text =
                case st & 0xF0
                when 0x90 then d2.to_i > 0 ? [:on, "#{NOTE_NAMES[d1 % 12]}#{d1 / 12 - 1} v#{d2}"] : [:off, "#{NOTE_NAMES[d1 % 12]}#{d1 / 12 - 1} off"]
                when 0x80 then [:off, "#{NOTE_NAMES[d1.to_i % 12]}#{d1.to_i / 12 - 1} off"]
                when 0xB0
                  @ccs[d1] = d2
                  [:cc, "cc #{d1} = #{d2}"]
                when 0xE0 then [:bend, "bend #{((d2.to_i << 7 | d1.to_i) - 8192)}"]
                when 0xD0 then [:pressure, "pressure #{d1}"]
                else [:other, bytes.map { |b| format('%02X', b) }.join(' ')]
                end
              stamp = (Session::Stamp.at(pos, s.transport).to_s rescue '')
              @midi_events << [stamp.freeze, name, kind, text.freeze].freeze
            end
            @midi_events.shift while @midi_events.length > MIDI_EVENTS
            @midi_seen = n
          end
          mapped = knobs.filter_map { |name, k| [name, k.spec.cc] if k.spec.cc }.freeze
          MidiInfo.new(events: @midi_events.dup.freeze, ccs: @ccs.dup.freeze, mapped: mapped)
        rescue StandardError
          nil
        end

        # Keeps queued changes and recordings that may still be running,
        # and the changes that landed (the log pane).
        def note(e, seen: true)
          if e.status == :landed
            @lock.synchronize do
              unless @landed.any? { |x| x.seq == e.seq }
                @landed << LandedInfo.new(seq: e.seq, kind: e.kind, subject: e.subject, lands: e.lands.to_s.freeze, pos: e.lands&.pos,
                                          at: seen ? MB::U.clock_now : nil)
                @landed.shift while @landed.length > LANDED
              end
            end
          end
          @lock.synchronize {
            if e.status == :queued || (e.kind == :rec && e.status == :landed)
              @open[e.seq] = e
            else
              @open.delete(e.seq)
            end
            # Recordings that have ended
            pos = @session.transport.position
            @open.delete_if { |_, x| x.kind == :rec && x.status == :landed && (x.data[:ends].nil? || x.data[:ends].pos.to_r <= pos) }
          }
        end

        def form_info(pb)
          return nil if pb.nil?
          return FormInfo.new(section: nil, pass: nil, from: nil, to: nil, next: nil, next_at: nil, committed: true, looping: false, ended: true) if pb.ended?
          return nil if pb.section.nil?

          nxt = pb.upcoming
          FormInfo.new(
            section: pb.section, pass: pb.pass, from: pb.pass_start, to: pb.boundary,
            next: nxt.section, next_at: nxt.at.to_s.freeze, committed: nxt.committed,
            looping: pb.looping?, ended: false
          )
        end
      end
    end
  end
end
