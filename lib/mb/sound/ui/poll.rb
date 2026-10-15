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

        def initialize(session)
          @session = session
          # Queued changes and recordings, kept from the journal's new
          # entries (reading all of #changes grows with the session)
          @open = {}
          @lock = Mutex.new
          @subscription = session.journal.subscribe { |e| note(e) }
          session.journal.changes.each { |e| note(e) }
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
          slow = Slow.new(
            tracks: tracks,
            scenes: arr.scenes.keys.freeze,
            scene: arr.current_scene,
            queued: queued,
            recording: recording,
            armed: armed,
            form: form_info(arr.playback),
            knob_specs: knobs.transform_values(&:spec).freeze
          )
          [slow, knobs.to_a.freeze]
        end

        private

        # Keeps queued changes and recordings that may still be running.
        def note(e)
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
