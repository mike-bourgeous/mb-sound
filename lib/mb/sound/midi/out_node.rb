module MB
  module Sound
    module MIDI
      # The graph of a MIDI out track (MIDI::Destination#play): reads a MIDI
      # stream (a clip's, a generator's, live input) like a Notes node and
      # sends its notes, controllers, bend, and pressure to a Destination,
      # each on its exact session frame: the event at stream time t lands on
      # sample floor((t - from) * rate) of the read starting at stream time
      # +from+, the sample an audio voice puts it on, and the read starts on
      # the Session's #player_frame.  So the same clip sends the same frames
      # at any buffer size.  Its audio is silence (the synth makes the
      # sound).
      #
      # Note hygiene: a table of the keys it holds (no allocation per note)
      # ends a held key before striking it again and drops note-offs for
      # keys it doesn't hold, and never uses running status.  When the
      # Session stops reading it while it holds notes (a cut stop, a mute,
      # a replaced graph, a cleared set, a panic) their note-offs go out on
      # the frame its reading stopped (MIDI::OutNode.end_span, called by the
      # Session after each span).  Swaps, pauses, seeks, and ring-outs end
      # notes through the clip source's own note-offs.
      #
      # Live input (a stream whose source is real-time input: an armed
      # track's keyboard or MIDI) is sent at once, not timed, so the player
      # hears the key now.
      class OutNode
        include GraphNode
        include GraphNode::SampleRateHelper
        node_traits memory: :short, fresh: 'a rebuilt MIDI out graph starts with no notes held: the old one sends its note-offs when it stops being read'

        # Status nibbles by event type (channel added by the Destination).
        KINDS = { note_off: 0x80, note_on: 0x90, poly_pressure: 0xa0, cc: 0xb0, program: 0xc0, channel_pressure: 0xd0, bend: 0xe0 }.freeze

        # The Destination this node sends to.
        attr_reader :destination

        # The stream it reads.
        attr_reader :stream

        def initialize(stream, destination, sample_rate: 48000)
          @stream = stream
          @destination = destination
          @reader = stream.reader
          @sample_rate = sample_rate.to_f
          @rate_r = sample_rate.to_r
          @live = stream.realtime_input?
          @held = Array.new(128, false)
          @held_count = 0
          @next_frame = 0 # the session frame of this node's next sample
          @seen_frame = nil # the Session#player_frame of the read in progress
          @read_end = nil # the session frame after the last sample read
          @session = nil
          @registered = false
          @started = false # program and bank sent
          @zeros = nil
          @ended = false
          @level_knob = nil # the track's level knob (Session::Faders), once found
          @level_cc = nil # the CC 7 value last sent
          # knob binds: [name, CC number, knob or nil, last value sent]
          @cc_binds = destination.ccs.map { |name, n| [name, n, nil, nil] }
          @cc_look = 0 # buffers until missing knobs are looked for again
        end

        # Silence (+count+ samples, a frozen buffer), or nil once the stream
        # has ended and no notes are held (the player then ends).  Sends the
        # buffer's events to the destination (see the class description).
        def sample(count)
          count = count.round
          span = Session.span
          session = span&.session
          pf = session&.player_frame
          if pf && pf != @seen_frame
            # A new read (the Session reads players from their first frame
            # in each span); pieces of one read go on from the last sample
            @seen_frame = pf
            @next_frame = pf
          end
          frame = @next_frame
          @session = session

          from = @reader.cursor
          to = @stream.advance(from, count, @sample_rate)
          events = @reader.events(from, to)

          unless @started
            @started = true
            select_program(session, frame)
          end
          if session && !@live
            follow_level(session, frame, count)
            follow_ccs(session, frame, count) unless @cc_binds.empty?
          end

          i = 0
          n = events.length
          while i < n
            e = events[i]
            off = ((e.time - from) * @rate_r).floor
            off = 0 if off < 0
            off = count - 1 if off >= count
            emit(e, session, frame + off)
            i += 1
          end

          @next_frame = frame + count
          @read_end = @next_frame
          if @held_count > 0 && session && !@registered
            @registered = true
            session.note_midi_out(self)
          end

          if @held_count == 0 && @reader.ended?
            @ended = true
            return nil
          end

          z = @zeros
          if z.nil? || z.length != count
            z = @zeros = Numo::SFloat.zeros(count).freeze
          end
          z
        end

        # True once the stream ended with no notes held.
        def ended?
          @ended
        end

        # Called by the Session after each span that ends at session frame
        # +span_end+ (see Session#note_midi_out): if this node wasn't read
        # to the span's end while holding notes, it stopped being read (a
        # stop, a mute, a replaced graph), so its notes end on the frame its
        # reading stopped.  Returns true while it still holds notes and was
        # read to the end (keep calling).
        def end_span(session, span_end)
          if @read_end.nil? || @read_end < span_end
            release_held(session, @read_end || span_end)
          end
          @registered = @held_count > 0
        end

        # Sends note-offs for every key this node holds, for session frame
        # +frame+.
        def release_held(session, frame)
          return if @held_count == 0
          k = 0
          while k < 128
            if @held[k]
              @held[k] = false
              @destination.send_at(session, frame, 0x80, k, 0)
            end
            k += 1
          end
          @held_count = 0
        end

        # Keys this node holds now (note numbers).
        def held_notes
          (0...128).select { |k| @held[k] }
        end

        def sources
          { stream: @stream }
        end

        def port_type
          :audio
        end

        def to_s
          "MIDI out to #{@destination}"
        end

        private

        def select_program(session, frame)
          d = @destination
          if (b = d.bank)
            if b.is_a?(Array)
              transmit(session, frame, 0xb0, 0, b[0])
              transmit(session, frame, 0xb0, 32, b[1])
            else
              transmit(session, frame, 0xb0, 0, b)
            end
          end
          transmit(session, frame, 0xc0, d.program - 1, 0) if d.program
        end

        # The track's level as CC 7 (channel volume), sent when it changes
        # once the track has a level (maintainer, 2026-11-22: "cc7 works for
        # now"): GM's volume curve, gain = (cc / 127) ** 2, so cc = 127 *
        # sqrt(gain), capped at 127 (levels over unity can't go louder).
        # Sent on the frame the level changes (a glide sends its last value
        # where it starts, once per buffer).
        def follow_level(session, frame, count)
          k = @level_knob
          if k.nil?
            p = session.reading_player or return
            k = @level_knob = session.fader(p.name) or return
          end
          v = k.read(frame, count)
          at = 0
          if v.is_a?(Numeric)
            cc = level_cc(v)
          else
            # (a moving level: sent where it first changes, at the
            # buffer's last value)
            cc = level_cc(v[-1])
            return if cc == @level_cc
            at += 1 while at < count - 1 && level_cc(v[at]) == @level_cc
          end
          return if cc == @level_cc
          @level_cc = cc
          transmit(session, frame + at, 0xb0, 7, cc)
        end

        # Knobs bound to controllers (Destination#ccs): each sends its
        # position along its range (0..127) when it changes, on the frame it
        # changes.  Knobs not defined yet are looked for every 32 buffers.
        def follow_ccs(session, frame, count)
          look = (@cc_look -= 1) <= 0
          @cc_look = 32 if look
          i = 0
          while i < @cc_binds.length
            b = @cc_binds[i]
            i += 1
            k = b[2]
            if k.nil?
              next unless look
              k = b[2] = session.knobs[b[0]] or next
            end
            v = k.read(frame, count)
            at = 0
            if v.is_a?(Numeric)
              cc = knob_cc(k, v)
            else
              cc = knob_cc(k, v[-1])
              next if cc == b[3]
              at += 1 while at < count - 1 && knob_cc(k, v[at]) == b[3]
            end
            next if cc == b[3]
            b[3] = cc
            transmit(session, frame + at, 0xb0, b[1], cc)
          end
        end

        def knob_cc(k, value)
          p = k.spec.position(value).to_f
          p = 0.0 if p < 0
          p = 1.0 if p > 1
          (p * 127).round
        end

        def level_cc(gain)
          g = gain.to_f
          g = 1.0 if g > 1.0
          g = 0.0 if g < 0.0
          (127 * Math.sqrt(g)).round
        end

        def emit(e, session, frame)
          case e.type
          when :note_on
            k = e.note
            return unless k.is_a?(Integer) && k >= 0 && k < 128
            if @held[k]
              # (a held key struck again: end it first, as NoteBalancer does)
              transmit(session, frame, 0x80, k, 0)
            else
              @held[k] = true
              @held_count += 1
            end
            transmit(session, frame, 0x90, k, e.raw || 100)
          when :note_off
            k = e.note
            return unless k.is_a?(Integer) && k >= 0 && k < 128 && @held[k]
            @held[k] = false
            @held_count -= 1
            transmit(session, frame, 0x80, k, e.raw || 64)
          when :cc
            transmit(session, frame, 0xb0, e.note, e.raw)
            # (all notes off and friends forget what this node holds)
            if e.note >= 123
              @held.fill(false)
              @held_count = 0
            end
          when :bend
            transmit(session, frame, 0xe0, e.raw & 0x7f, e.raw >> 7)
          when :channel_pressure
            transmit(session, frame, 0xd0, e.raw, 0)
          when :poly_pressure
            k = e.note
            transmit(session, frame, 0xa0, k, e.raw) if k.is_a?(Integer) && k >= 0 && k < 128
          when :program
            transmit(session, frame, 0xc0, e.raw || e.value.to_i, 0)
          end
        end

        def transmit(session, frame, kind, data1, data2)
          if @live
            @destination.send_now(kind, data1, data2)
          else
            @destination.send_at(session, frame, kind, data1, data2)
          end
        end
      end
    end
  end
end
