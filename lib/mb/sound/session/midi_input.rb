module MB
  module Sound
    class Session
      # A Session's MIDI input (one per input name; see MidiIn): reads a
      # MIDI::Stream (live input, or anything Stream.for takes) once per
      # rendered span, before anything else in the Session uses it, and
      # puts every event on an exact session frame and timeline position.
      # Everything in the Session that plays or records live MIDI reads it
      # from here, so it all agrees on where each event landed:
      #
      # - taps (#stream): MIDI::Sources for graphs (console `midi`, the
      #   monitors of armed tracks) that give each span's events on the same
      #   frames, with no added latency;
      # - knobs listening to controllers (GraphNode::Knob#listen);
      # - the recent history, which `rec` and `capture` turn into clips
      #   (see MIDI::Capture and Recording);
      # - the Session's MIDI log, which takes save and replay (see Take);
      # - the journal: each controller gesture becomes a :cc entry.
      #
      # While a take replays, the input is the take's recorded events
      # (#replay), placed on the same timeline positions, so everything
      # above happens again on the same frames.
      #
      # Events that arrive while the timeline is stopped all have the
      # position where it stopped; a replay gives them in one span.
      #
      # More sources can play into the same input beside it (#add_source:
      # the terminal UI's virtual keyboard next to a hardware keyboard);
      # their events merge into each span in time order.
      class MidiInput
        # An event as it landed: the session +frame+, the timeline +pos+
        # (whole notes; the position of the frame), the Session's +epoch+
        # (see Seeks), and the MIDI::Event.
        Stamped = Data.define(:frame, :pos, :epoch, :event)

        # The events of one rendered span (see #pump).
        Span = Data.define(:id, :frame, :count, :events)

        # Whole notes of history kept for captures and recordings (64 bars
        # of 4/4).
        HISTORY = 64

        # The most events kept in the history.
        HISTORY_LIMIT = 100_000

        # Controller moves further apart than this (seconds) are separate
        # gestures in the journal.
        GESTURE_GAP = 0.25

        attr_reader :session, :name

        # The Stream being read (live input or a stand-in), or nil.
        attr_reader :input

        # The events of the last span read (a Span), or nil.
        attr_reader :span

        # The sample rate of the frames (the Session's).
        attr_reader :sample_rate

        def initialize(session, name = nil)
          @session = session
          @name = name
          @input = nil
          @reader = nil
          @replay = nil
          @span = nil
          @span_id = 0
          @history = []
          @gestures = {}
          @sample_rate = 48000
          @lock = Monitor.new
          @bends = nil
          @detached_frame = 0
          @extras = {}.compare_by_identity
          @labels = {}.compare_by_identity
          # Notes held now (see #held_notes): { [channel, note] => HeldNote }
          @held = {}
          @held_list = [].freeze
        end

        # Adds +stream+ (a MIDI::Stream, or anything MIDI::Stream.for
        # takes) as another source of this input: its events merge with the
        # input's in every span, in time order (while a take replays, they
        # are read and dropped).  +label+ names it in #held_notes (e.g.
        # :keyboard for the terminal UI's virtual keyboard).  Returns the
        # Stream.
        def add_source(stream, label: :extra)
          stream = MIDI::Stream.for(stream)
          @lock.synchronize {
            @extras[stream] ||= stream.reader
            @labels[stream] = label
          }
          stream
        end

        # Stops reading +stream+ (see #add_source).  Returns nil.
        def remove_source(stream)
          @lock.synchronize {
            @extras.delete(stream)&.close
            label = @labels.delete(stream)
            # Its held notes end with it (the source can't send their offs)
            if label && @held.any? { |_, h| h.source == label } && @labels.none? { |_, l| l == label }
              @held.delete_if { |_, h| h.source == label }
              @held_list = @held.values.freeze
            end
          }
          nil
        end

        # The notes held now on this input and its added sources (frozen
        # UI::HeldNote values, for the terminal UI's keyboard pane): updated
        # on the render thread from each span's events, read by any thread
        # without a lock (one frozen Array per change).
        def held_notes
          @held_list
        end

        # The streams added with #add_source.
        def sources
          @lock.synchronize { @extras.keys }
        end

        # Reads +stream+ (a MIDI::Stream, or anything MIDI::Stream.for
        # takes; nil to stop) from the next span on.
        def input=(stream)
          @lock.synchronize {
            @reader&.close
            @input = stream && MIDI::Stream.for(stream)
            @reader = @input&.reader
          }
        end

        # Plays +events+ (an Array of [epoch, pos, bytes], sorted; see
        # Take) instead of an input, each on the frame of its position in
        # its epoch (epochs counted from the replay's start).
        def replay(events, base_epoch: 0)
          @lock.synchronize {
            @reader&.close
            @reader = nil
            @input = nil
            @replay = events.map { |epoch, pos, bytes| [epoch + base_epoch, pos.to_r, bytes] }
            @replay_index = 0
            @bends = MIDI::Stream::BendTracker.new(Interval.semitones(MIDI::Event::DEFAULT_BEND_RANGE))
          }
        end

        # Stops playing a take's events (see #replay); the input is empty
        # until #input= gives it one.
        def end_replay
          @lock.synchronize { @replay = nil; @bends = nil }
        end

        # True while playing a take's events (see #replay).
        def replaying?
          !@replay.nil?
        end

        # True while a take's events (see #replay) are still to play.
        def replay_pending?
          @lock.synchronize { !@replay.nil? && @replay_index < @replay.length }
        end

        # True if the input was closed (live input closed with
        # MidiMethods#close_midi).
        def closed?
          src = @input&.source
          !!(src.respond_to?(:closed?) && src.closed?)
        end

        # A new MIDI::Stream of this input's events for one graph (see Tap).
        def stream
          MIDI::Stream.new(Tap.new(self))
        end

        # The span counter (see Span).
        def span_id
          @span_id
        end

        # The first frame the Session is rendering for the player being
        # rendered (see Session#player_frame), or nil.
        def player_frame
          @session.player_frame
        end

        # True if graphs should read the input themselves: a realtime
        # Session whose render thread isn't running (e.g. `play` in the
        # foreground before anything plays in the background).
        def detached?
          @session.realtime? && !@session.running? && !replaying?
        end

        # Reads the input for the span of +count+ frames starting at session
        # frame +frame+ and timeline position +from+ (+per_sample+ whole
        # notes per frame), in the Session's +epoch+.  Called by the Session
        # once per span, before its changes land and graphs render.  Returns
        # the Span.
        def pump(frame, count, from, per_sample, epoch, rate)
          @lock.synchronize {
            @sample_rate = rate
            drain_extras(count, rate) if @replay && !@extras.empty?
            events = @replay ? replay_events(frame, count, from, per_sample, epoch) : input_events(frame, count, from, per_sample, epoch, rate)
            @span = Span.new(id: @span_id += 1, frame: frame, count: count, events: events.freeze)

            unless events.empty?
              @history.concat(events)
              @session.send(:log_midi, self, events)
              track_held(events)
            end
            trim_history(from)
            follow_gestures(events, frame, rate)
            @span
          }
        end

        # Events from the history as [pos, MIDI::Event] pairs with positions
        # in [+from+, +to+) in the current epoch, for MIDI::Capture.
        def history(from, to, epoch: @session.epoch)
          @lock.synchronize {
            @history.select { |s| s.epoch == epoch && s.pos >= from && s.pos < to }.map { |s| [s.pos, s.event] }
          }
        end

        # The positions of the notes in the history (current epoch), for
        # finding the last phrase played (see Recording#capture).
        def note_positions(epoch: @session.epoch)
          @lock.synchronize {
            @history.select { |s| s.epoch == epoch && (s.event.type == :note_on || s.event.type == :note_off) }.map { |s| [s.pos, s.event.type] }
          }
        end

        # Reads the input directly for graphs reading it outside a running
        # Session (see #detached?): the events of the next +duration+
        # seconds, timed from +from+.
        def detached_events(from, duration)
          @lock.synchronize {
            readers.flat_map { |r|
              start = r.cursor
              r.next(duration).filter_map { |e|
                e.at(from + (e.time - start)) if e.is_a?(MIDI::Event)
              }
            }.sort_by.with_index { |e, i| [e.time, i] }
          }
        end

        def to_s
          "MIDI input#{@name ? " #{@name.inspect}" : ''}#{replaying? ? ' (replay)' : @input ? '' : ' (none)'}"
        end

        private

        # The readers of the input and of the added sources.
        def readers
          @extras.empty? ? [@reader].compact : [@reader, *@extras.values].compact
        end

        # Events of the input (and added sources) for one span, stamped,
        # in frame order (the input's first at equal frames).
        def input_events(frame, count, from, per_sample, epoch, rate)
          list = readers
          return [] if list.empty?

          out = []
          @span_sources = nil
          list.each do |reader|
            start = reader.cursor
            label = reader.equal?(@reader) ? :input : (@labels[@extras.key(reader)] || :extra)
            reader.next(Rational(count, rate)).each { |e|
              next unless e.is_a?(MIDI::Event)
              off = ((e.time - start) * rate).floor.clamp(0, count - 1)
              st = Stamped.new(frame: frame + off, pos: from + off * per_sample, epoch: epoch, event: e.at(Rational(frame + off, rate)))
              (@span_sources ||= {}.compare_by_identity)[st] = label unless label == :input
              out << st
            }
          end
          list.length > 1 ? out.sort_by.with_index { |st, i| [st.frame, i] } : out
        end

        # Updates the held notes (see #held_notes) from a span's events.
        def track_held(events)
          changed = false
          events.each do |st|
            e = st.event
            case e.type
            when :note_on, :note_off
              key = [e.channel, e.note]
              if e.type == :note_on && e.velocity.to_f > 0
                @held[key] = UI::HeldNote.new(
                  note: e.note, velocity: (e.velocity.to_f * 127).round.clamp(1, 127), channel: e.channel,
                  source: @span_sources&.[](st) || :input, input: @name, frame: st.frame, pos: st.pos
                )
              else
                @held.delete(key)
              end
              changed = true
            when :cc
              # All notes off (123) and all sound off (120) end held notes
              if e.note == 123 || e.note == 120
                changed ||= @held.any? { |(ch, _), _| ch == e.channel }
                @held.delete_if { |(ch, _), _| ch == e.channel }
              end
            end
          end
          @span_sources = nil
          @held_list = @held.values.freeze if changed
        end

        # Reads the added sources for a span and drops their events (while a
        # take replays: live sources must not pile up for later).
        def drain_extras(count, rate)
          @extras.each_value { |r| r.next(Rational(count, rate)) }
        end

        # Recorded events due in this span: the epoch's events before its
        # end (and any from earlier epochs left behind, at its start).
        def replay_events(frame, count, from, per_sample, epoch)
          to = from + count * per_sample
          out = []
          while @replay_index < @replay.length
            ep, pos, bytes = @replay[@replay_index]
            break if ep > epoch || (ep == epoch && pos >= to)
            @replay_index += 1

            off = ep == epoch ? ((pos - from) / per_sample).floor.clamp(0, count - 1) : 0
            MIDI::Event.parse_all(bytes).each do |e|
              e = @bends.process(e)
              out << Stamped.new(frame: frame + off, pos: from + off * per_sample, epoch: epoch, event: e.at(Rational(frame + off, @sample_rate)))
            end
          end
          out
        end

        # Drops history older than HISTORY whole notes before +pos+ (and
        # anything over HISTORY_LIMIT events).
        def trim_history(pos)
          limit = pos - HISTORY
          drop = @history.index { |s| s.pos >= limit && s.epoch == @session.epoch } || @history.length
          drop = MB::M.max(drop, @history.length - HISTORY_LIMIT)
          @history.shift(drop) if drop > 0
        end

        # Journals controller gestures (see GESTURE_GAP): a :cc entry for
        # each one once it has been still for the gap.
        def follow_gestures(events, frame, rate)
          gap = (GESTURE_GAP * rate).round

          events.each do |s|
            e = s.event
            key = case e.type
                  when :cc then [e.channel, e.note]
                  when :bend then [e.channel, :bend]
                  when :channel_pressure then [e.channel, :pressure]
                  end
            next if key.nil?

            g = @gestures[key]
            if g && s.frame - g[:last] > gap
              close_gesture(key, g)
              g = nil
            end
            g ||= @gestures[key] = { first: s, from: e.raw, moves: 0 }
            g[:to] = e.raw
            g[:moves] += 1
            g[:last] = s.frame
          end

          @gestures.each { |key, g| close_gesture(key, g) if frame - g[:last] > gap }
          @gestures.reject! { |_, g| g[:closed] }
        end

        def close_gesture(key, g)
          return if g[:closed]
          g[:closed] = true
          channel, control = key
          knobs = control.is_a?(Integer) ? @session.knobs_on_cc(self, control) : []
          subject = knobs.length == 1 ? knobs.first : (control.is_a?(Integer) ? :"cc#{control}" : control)
          first = g[:first]
          data = { control: control, channel: channel, from: g[:from], to: g[:to], moves: g[:moves], knobs: knobs }
          data[:input] = @name if @name
          @session.journal.note_entry(kind: :cc, subject: subject, lands: @session.stamp(first.pos, frame: first.frame), data: data, source: :midi)
        end

        # A MIDI::Source of a MidiInput's events for one graph (see
        # MidiInput#stream): each read gives the events of the span the
        # Session read last, on the same frames (the first read in a span
        # starts at the player's first frame, Session#player_frame, or else
        # is taken to cover the end of the span: a graph that started
        # partway through it starts there, and events before that are left
        # out; a graph may read the span in pieces, e.g. a Synth split at
        # its grid points).  Events of spans the graph
        # didn't read (asleep, not started yet) are dropped.  Outside a
        # running realtime Session it reads the input itself (see
        # MidiInput#detached?).
        class Tap
          include MIDI::Source

          attr_reader :hub

          def initialize(hub)
            @hub = hub
            @last_id = hub.span_id
            @pending = []
            @node_type_name = 'MIDI Input'
          end

          # A Session's MIDI input is real-time input, also while a take
          # replays it, so replays allocate the same way (see
          # Source#realtime_input?).
          def realtime_input?
            true
          end

          # Live input has no content position (see LiveSource).
          def seek(_time)
            self
          end

          def restart
            self
          end

          def closed?
            @hub.closed?
          end

          # The source of the input being read (e.g. a MIDI::LiveSource),
          # or nil.
          def live_source
            @hub.input&.source
          end

          # Does nothing: the input belongs to the Session's MidiInput.
          def close
            nil
          end

          def to_s
            "MIDI #{@hub}"
          end

          private

          def read_events(from, to)
            return @hub.detached_events(from, to - from) if @hub.detached?

            span = @hub.span
            if span && span.id != @last_id
              @last_id = span.id
              rate = @hub.sample_rate
              pf = @hub.player_frame
              base = pf && pf >= span.frame && pf < span.frame + span.count ? pf : span.frame + span.count - ((to - from) * rate).round
              @pending = span.events.filter_map { |s|
                s.event.at(from + Rational(s.frame - base, rate)) if s.frame >= base
              }
            end

            n = @pending.index { |e| e.time >= to } || @pending.length
            @pending.shift(n)
          end
        end
      end
    end
  end
end
