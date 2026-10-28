module MB
  module Sound
    class Session
      # Ringing out: a player stopped with `remove(name, ring: true)` (the
      # Set's default when a scene drops a track; see Arrangement) stops
      # sending notes on the exact sample of its stop time, but keeps
      # rendering, so envelopes release and delays and reverbs inside the
      # graph ring out naturally.  It sleeps (is kept for #resume, like any
      # stopped player) once its output has stayed below
      # Master::TAIL_THRESHOLD (-90 dB) for RING_QUIET_SECONDS, cut on the
      # exact sample where that quiet stretch ends (so the result is the
      # same at any buffer size; the graph is read in pieces ending there,
      # so it sleeps having rendered exactly that far and a revived graph
      # continues from the same state too, omnibus13).  A tail still ringing after
      # Master::MAX_TAIL_SECONDS fades out over Master::TAIL_FADE_SECONDS
      # from that exact sample.
      #
      # "Stops sending notes" means every MIDI::ClipSource in the graph
      # switches to a silent clip (notes in progress get their note-offs);
      # the real clips come back when the player sleeps, so #resume (and
      # scenes) play them again.  A graph without clip sources (a drone, a
      # file, a raw oscillator) can't stop its notes, so it fades out over
      # RING_DRONE_FADE bars instead.
      #
      # Launching the same player again while it rings (#resume, undo, or a
      # scene bringing the track back) revives the ringing graph instead of
      # starting a second copy of it, so its notes come back in time with
      # the graph's state intact.
      module Tails
        # How long a ringing tail must stay below Master::TAIL_THRESHOLD
        # before the player sleeps.
        RING_QUIET_SECONDS = Master::TAIL_QUIET_SECONDS

        # Bars to fade a graph that has no clips to stop (see the module
        # comment).
        RING_DRONE_FADE = 1/4r

        # A ringing player's state: +stop_frame+ is the session frame of the
        # stop sample (nil until the stop lands in a buffer); +quiet_from+
        # the session frame where the current quiet stretch began; +sources+
        # the clip sources silenced; +capped+ true once the cap fade began;
        # +active+ false once another stop (a fade or cut) took over.
        Ring = Struct.new(:stop_frame, :quiet_from, :sources, :capped, :active, keyword_init: true)

        # True if the player named +name+ is ringing out (see the module
        # comment).
        def ringing?(name)
          @mutex.synchronize { !ringing_player(name).nil? }
        end

        # True if #resume can bring back the player named +name+: it is
        # stopped or ringing out.
        def resumable?(name)
          @mutex.synchronize { @stopped.key?(name) || !ringing_player(name).nil? }
        end

        private

        # The player named +name+ that is ringing out (not replaced by a
        # newer graph that is playing), or nil.  Called with @mutex held.
        def ringing_player(name)
          @players.each_value.find { |p| p.name == name && p.ring&.active }
        end

        # Marks player +p+ to ring out from timeline position +time+
        # (applied by the change queue through #remove_now).  Returns false
        # (and does nothing) for players without clip sources.  Called with
        # @mutex held.
        def start_ringing(p, time)
          sources = p.timeline_nodes.grep(MIDI::ClipSource)
          return false if sources.empty?

          p.stop_at = time
          p.fade_out = nil
          p.fading_out = false
          p.ring = Ring.new(stop_frame: nil, quiet_from: nil, sources: sources, capped: false, active: true)
          true
        end

        # Silences a ringing player's clips at its stop time, in the buffer
        # that holds it (+stop_idx+ frames in, from session frame +base+).
        def begin_ring(p, base, stop_idx)
          ring = p.ring
          ring.stop_frame = base + stop_idx
          ring.quiet_from = ring.stop_frame
          ring.sources.each { |s| s.ring_out(p.stop_at) }
        end

        # Ends ringing for +p+ when it is retired or kept stopped: its clip
        # sources get their real clips back for #resume.  Safe to call more
        # than once.
        def end_ring(p)
          ring = p.ring or return
          p.ring = nil
          ring.sources.each(&:end_ring_out)
        end

        # Revives a ringing player named +name+ whose graph is +input+ (any
        # graph if nil) at timeline position +start+: its clips come back
        # at +start+, it stops ringing, and a cap fade in progress ramps
        # back up.  Returns the player, or nil if none is ringing.  Called
        # with @mutex held.
        def revive_ringing(name, start, input: nil)
          p = ringing_player(name)
          return nil if p.nil? || (input && !p.input.equal?(input))

          ring = p.ring
          p.ring = nil
          p.stop_at = nil
          p.fade_out = nil
          p.keep = false
          ring.sources.each { |s| s.end_ring_out(time: start) }
          if p.fading_out || p.ramp
            p.ramp = Fades::Ramp.after(p.ramp, p.gain, 1.0, @landing_frame || @frame, fade_frames(declick_bars, output.sample_rate.to_f))
            p.fading_out = false
          end
          @order.delete(name)
          @order << name
          p
        end

        # Starts the cap fade of a ringing player if its tail reaches
        # Master::MAX_TAIL_SECONDS before session frame +until_frame+.
        def cap_ring(p, until_frame, rate)
          ring = p.ring
          return if ring.capped || ring.stop_frame.nil?

          cap_frame = ring.stop_frame + (Master::MAX_TAIL_SECONDS * rate).round
          return if cap_frame >= until_frame

          ring.capped = true
          level = fade_level(p, cap_frame)
          p.ramp = Fades::Ramp.new(level, 0.0, cap_frame, MB::M.max((Master::TAIL_FADE_SECONDS * rate).round, 1))
          p.fading_out = true
        end

        # Records in the journal that player +p+ rang out and went to sleep
        # at session frame +frame+ (during #render_player).
        def note_rung_out(p, frame, rate)
          ring = p.ring
          pos = @transport.position + (frame - @frame) * @transport.whole_notes_per_second / rate.to_r
          seconds = ((frame - ring.stop_frame) / rate.to_f).round(3)
          @journal.note_entry(
            kind: :rung_out, subject: p.name, lands: stamp(pos, frame: frame),
            data: { seconds: seconds, capped: ring.capped }
          )
        end

        # d.abs.max without allocating for real SFloat/DFloat buffers
        # (FastArithmetic.min_max; dropouts-2), as a Float.
        def abs_peak(d)
          r = (@tail_range ||= [0.0, 0.0])
          return d.abs.max unless MB::Sound::FastArithmetic.min_max(d, r)
          lo, hi = r
          p = -lo > hi ? -lo : hi
          p.nan? ? d.abs.max : p
        end

        # Follows a ringing player's output +data+ (+frames+ frames from
        # session frame +frame+), returning how many of those frames to mix:
        # all of them, or fewer if the tail's quiet stretch reaches
        # RING_QUIET_SECONDS inside this buffer (the player then sleeps).
        def follow_ring(p, data, frame, frames, rate)
          ring = p.ring
          quiet = (RING_QUIET_SECONDS * rate).round

          chans = data.filter_map { |d|
            next if d.nil? || d.empty?
            d = d.real if d.is_a?(Numo::SComplex) || d.is_a?(Numo::DComplex)
            d.length > frames ? d[0...frames] : d
          }

          # Fast paths for buffers shorter than the quiet stretch (no quiet
          # stretch can start and end inside one): a silent buffer, or one
          # whose last sample is loud (the tail is still going)
          if frames < quiet
            peak = 0
            chans.each { |d| v = abs_peak(d); peak = v if v > peak }
            if peak < Master::TAIL_THRESHOLD
              ending = ring.quiet_from + quiet
              return ending <= frame + frames ? MB::M.max(ending - frame, 0) : frames
            elsif chans.any? { |d| d.length == frames && d[-1].abs >= Master::TAIL_THRESHOLD }
              ring.quiet_from = MB::M.max(ring.quiet_from, frame + frames)
              return frames
            end
          end

          loud = nil
          chans.each do |d|
            next if d.nil? || d.empty?
            d = d.real if d.is_a?(Numo::SComplex) || d.is_a?(Numo::DComplex)
            m = d[0...MB::M.min(d.length, frames)].abs.ge(Master::TAIL_THRESHOLD)
            loud = loud ? (loud | m) : m
          end

          # Gaps between loud samples (and from the quiet stretch's start to
          # the first one, and from the last one to the buffer's end)
          # (loud samples before the quiet stretch's start don't count)
          idx = loud ? loud.where : Numo::Int32[]
          rel = ring.quiet_from - frame
          idx = idx[idx.ge(rel)] if rel > 0 && idx.length > 0
          if idx.length > 0
            first_gap = idx[0] - rel
            if first_gap >= quiet
              return MB::M.max(rel + quiet, 0)
            end

            if idx.length > 1
              gaps = idx[1..] - idx[0...-1] - 1
              long = gaps.ge(quiet).where
              return idx[long[0]] + 1 + quiet unless long.empty?
            end

            ring.quiet_from = MB::M.max(ring.quiet_from, frame + idx[-1] + 1)
          end

          ending = ring.quiet_from + quiet
          ending <= frame + frames ? MB::M.max(ending - frame, 0) : frames
        end
      end
    end
  end
end
