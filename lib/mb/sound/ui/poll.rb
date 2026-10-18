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

        # Journal kinds that change what a track plays (the clip matrix).
        LANE_KINDS = [:bg, :resume, :restore, :swap, :stop, :capture, :forget].freeze

        # Events kept per clip for the detail pane (ClipInfo#events).
        CLIP_EVENTS = 512

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
          # The clip matrix: journal entries per subject that change what
          # it plays ({ subject => { seq => Entry } }; the newest landed
          # one and the queued ones are kept), and queued scene launches
          @lanes = {}
          @scene_launches = {}
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
            TrackInfo.new(name: name, q: (tr.q || arr.quant).inspect.freeze, clip: (tr.patch? ? (tr.clip ? arr.name_of(tr.clip) : 'no clip') : 'graph').freeze, armed: armed.include?(name), key: tr.key || false)
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
            midi: midi_info(s, knobs),
            matrix: matrix_info(arr),
            racks: rack_infos(s),
            clocks: clock_infos(s)
          )
          [slow, knobs.to_a.freeze]
        end

        private

        # The clocks (Session#clocks: its own mutex; positions read without
        # the render lock, extrapolated past the last rendered cell).
        def clock_infos(s) = UI.clock_infos(s)

        # The buses (Session#bus_info: its own mutex).
        def bus_infos(s)
          routes = (s.routes rescue {})
          s.bus_info.map { |name, desc|
            to = desc[/\(to (\S+?)[,)]/, 1]&.to_sym || :master
            sends = routes.select { |_, r| (r[:send] || {}).key?(name) }.keys.freeze
            sources = routes.select { |_, r| r[:to] == name }.keys.freeze
            BusInfo.new(name: name, to: to, description: desc.sub(/ \(to .*\z/, '').freeze, asleep: desc.include?(', asleep'), muted: desc.include?(', muted'),
                        sends: sends, sources: sources)
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
          kit = clip.respond_to?(:rows)
          len = kit ? (clip.rows.each_value.map { |c| c.length.to_r }.max || 0r) : clip.length.to_r
          bar = (@session.transport.bar_length rescue 1r).to_r
          events = kit ? clip.rows.each_value.flat_map(&:events) : ((clip.send(:first_cycle_events) rescue clip.events))
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
          notes = note_infos(clip)
          values = notes.filter_map(&:note)
          ruby = begin
            clip.respond_to?(:to_ruby) ? clip.to_ruby.freeze : nil
          rescue StandardError
            nil
          end
          ClipInfo.new(name: arr.name_of(clip).freeze, kind: clip.class.name.split('::').last.downcase.to_sym,
                       bars: bar > 0 ? (len / bar) : len, pattern: cells.join.freeze, used: [].freeze,
                       key: (clip.respond_to?(:named?) && clip.named? ? clip.name.to_s.freeze : nil),
                       loop: clip.respond_to?(:looping?) ? clip.looping? : clip.rows.each_value.any?(&:looping?),
                       length: len, events: notes, ruby: ruby, range: values.empty? ? nil : (values.min..values.max),
                       history: history_of(arr, clip))
        end

        # A tweak version's lineage for ClipInfo#history (empty for other
        # clips).
        def history_of(arr, clip)
          root, ops = arr.respond_to?(:tweak_history) ? arr.tweak_history(clip) : nil
          return [].freeze unless ops
          [root.to_s, *ops].map(&:freeze).freeze
        end

        # A clip's (or kit's) first cycle as frozen NoteInfos (see
        # ClipInfo), at most CLIP_EVENTS.
        def note_infos(clip)
          rows = clip.respond_to?(:rows) ? clip.rows : { nil => clip }
          out = []
          rows.each do |row, c|
            evs = (c.send(:first_cycle_events) rescue c.events)
            Array(evs).each do |e|
              v = e.value
              note = v.is_a?(Integer) ? v : (v.respond_to?(:number) ? v.number.round : (v.is_a?(Numeric) ? v.round : nil))
              marks = []
              marks << :accent if e.accented
              marks << :slide if e.slid
              marks << :flam if e.flam
              marks << :fill if e.fill_mark
              marks << :pitch if e.pitch
              out << NoteInfo.new(start: e.start.to_r, length: e.length.to_r, note: note, velocity: e.velocity.to_f, row: row, marks: marks.freeze)
              break if out.length >= CLIP_EVENTS
            end
          end
          out.sort_by! { |n| [n.start, n.note || 0] }
          out.freeze
        rescue StandardError
          [].freeze
        end

        # The clip matrix (see MatrixInfo): each track's slots, the slot
        # playing (from the journal: the newest landed change that changed
        # what it plays, and the clip the Arrangement launched with it),
        # and launches waiting; each scene's cells.
        def matrix_info(arr)
          tracks = arr.tracks
          return nil if tracks.empty?

          lanes = @lock.synchronize { @lanes.transform_values(&:values) }
          scene_launches = @lock.synchronize { @scene_launches.values }
          all = arr.all_slots
          lane_infos = tracks.map { |name, tr|
            slots = all[name] || []
            index = ->(clip) { clip && slots.index { |c| c.equal?(clip) } }
            entries = (lanes[name] || []).sort_by(&:seq)
            landed = entries.select(&:landed?).last
            state = :stopped
            playing = nil
            if landed && ![:stop, :forget].include?(landed.kind)
              state = :playing
              clip = arr.launch_clip(landed.seq)
              clip = tr.clip if clip.nil? || landed.kind == :capture || landed.kind == :restore
              playing = index.(clip)
            end
            queued = entries.select(&:queued?).map { |e|
              kind = [:stop, :forget].include?(e.kind) ? :stop : :launch
              LaunchInfo.new(seq: e.seq, kind: kind, slot: kind == :stop ? nil : index.(arr.launch_clip(e.seq)), lands: e.lands.to_s.freeze, pos: e.lands&.pos)
            }.freeze
            infos = slots.each_with_index.map { |c, i|
              info = (@clip_cache[c] ||= clip_info(arr, c))
              info.key ? info : info.with(key: "#{name}##{i}".freeze)
            }.freeze
            LaneInfo.new(name: name, q: (tr.q || arr.quant).inspect.freeze, state: state, playing: playing, queued: queued, slots: infos)
          }.freeze

          scene_infos = arr.scenes.map { |sname, sc|
            values = sc.values || {}
            cells = tracks.keys.to_h { |t|
              v = values.key?(t) ? values[t] : (sc.others == :keep ? :keep : :stop)
              cell = case v
                     when :keep, :on, true then :keep
                     when :off, :cut, :stop, false, nil then :stop
                     else (all[t] || []).index { |c| c.equal?(v) } || :keep
                     end
              [t, cell]
            }.freeze
            q = scene_launches.select { |e| e.subject == sname && e.queued? }.max_by(&:seq)
            SceneInfo.new(name: sname, cells: cells, current: arr.current_scene == sname,
                          queued: q && LaunchInfo.new(seq: q.seq, kind: :scene, slot: nil, lands: q.lands.to_s.freeze, pos: q.lands&.pos))
          }.freeze
          MatrixInfo.new(tracks: lane_infos, scenes: scene_infos)
        rescue StandardError => e
          warn_once(e)
          nil
        end

        # The rack instances (Session::Racks#rack_info; its own mutex).
        def rack_infos(s)
          return [].freeze unless s.respond_to?(:racks)
          s.racks.rack_info.values.flatten.freeze
        rescue StandardError => e
          warn_once(e)
          [].freeze
        end

        # Warns about a poll failure once per message (the panes go on with
        # what they have).
        def warn_once(e)
          @warned ||= {}
          key = "#{e.class}: #{e.message}"
          return if @warned[key]
          @warned[key] = true
          warn "UI poll: #{key} (#{e.backtrace&.first})"
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
            if LANE_KINDS.include?(e.kind) && e.subject.is_a?(Symbol)
              lane = (@lanes[e.subject] ||= {})
              if e.status == :queued || e.status == :landed
                lane[e.seq] = e
              else
                lane.delete(e.seq)
              end
              # Only the newest landed change counts
              newest = lane.each_value.select(&:landed?).max_by(&:seq)
              lane.delete_if { |_, x| x.landed? && !x.equal?(newest) } if newest
            elsif e.kind == :scene
              e.status == :queued ? @scene_launches[e.seq] = e : @scene_launches.delete(e.seq)
            end
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
