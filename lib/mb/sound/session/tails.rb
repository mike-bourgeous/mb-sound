module MB
  module Sound
    class Session
      # Ringing out: a player stopped with `remove(name, ring: true)` (the
      # Set's default when a scene drops a track; see Arrangement) stops
      # sending notes on the exact sample of its stop time, but keeps
      # rendering, so envelopes release and delays and reverbs inside the
      # graph ring out naturally.  It sleeps (is kept for #resume, like any
      # stopped player) once its output has stayed below QuietRun::QUIET
      # (-90 dB) for RING_QUIET_SECONDS (a QuietRun), cut on the
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
        # How long a ringing tail must stay below QuietRun::QUIET before the
        # player sleeps.
        RING_QUIET_SECONDS = QuietRun::QUIET_SECONDS

        # Bars to fade a graph that has no clips to stop (see the module
        # comment).
        RING_DRONE_FADE = 1/4r

        # A ringing player's state: +stop_frame+ is the session frame of the
        # stop sample (nil until the stop lands in a buffer); +quiet+ the
        # QuietRun following its output from there (session frames); +sources+
        # the clip sources silenced; +capped+ true once the cap fade began;
        # +active+ false once another stop (a fade or cut) took over.
        # +choke+ chokes the notes in progress at the stop instead of
        # releasing them, and +spill+ marks a spill-over (carry-1): the
        # graph a rebuild or a new instrument replaced, ringing out under
        # the new one; it is never revived by a launch of its name (only by
        # an undo bringing that graph back) and not counted as the name's
        # ringing player.
        Ring = Struct.new(:stop_frame, :quiet, :sources, :capped, :active, :choke, :spill, keyword_init: true)

        # Ends the players named +name+ once every node of +nodes+ (nodes
        # with #ended?: a file's GraphNode::Ringdown, a Synth playing a MIDI
        # file) has ended and the player's output has then been quiet for
        # RING_QUIET_SECONDS, on the exact sample where that quiet stretch
        # completes (ScriptRunner's ring-down; session-2, the maintainer's
        # "Exact frame": the same at any buffer size, where a tap stopped
        # the player at the next buffer before).  The nodes are asked on
        # the sleep grid (QuietRun::GRID session frames, the player read in
        # pieces ending there), so the ring-out starts on the same frame
        # whatever the buffer size; from there the player rings out like a
        # stopped one (#follow_ring, capped after Master::MAX_TAIL_SECONDS)
        # and is kept stopped when it sleeps.  Returns the number of players
        # marked.
        def end_after(name, nodes)
          nodes = nodes.to_a
          return 0 if nodes.empty?
          raise ArgumentError, "end_after needs nodes with #ended? (got #{nodes.reject { |n| n.respond_to?(:ended?) }.map(&:class).uniq.join(', ')})" unless nodes.all? { |n| n.respond_to?(:ended?) }

          @render_lock.synchronize {
            @mutex.synchronize {
              list = @players.each_value.select { |p| p.name == name && p.ring.nil? }
              list.each { |p| p.ends_after = nodes.dup.freeze }
              list.length
            }
          }
        end

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
          @players.each_value.find { |p| p.name == name && p.ring&.active && !p.ring.spill }
        end

        # Marks player +p+ to ring out from timeline position +time+
        # (applied by the change queue through #remove_now).  Returns false
        # (and does nothing) for players without clip sources.  Called with
        # @mutex held.
        def start_ringing(p, time, choke: false, spill: false)
          sources = p.timeline_nodes.grep(MIDI::ClipSource)
          return false if sources.empty?

          p.stop_at = time
          p.fade_out = nil
          p.fading_out = false
          quiet = QuietRun.new((RING_QUIET_SECONDS * output.sample_rate).round)
          p.ring = Ring.new(stop_frame: nil, quiet: quiet, sources: sources, capped: false, active: true, choke: choke, spill: spill)
          true
        end

        # Starts player +p+'s quiet ring-out (see #end_after) at session
        # frame +frame+, returning its QuietRun.  Quiet means below
        # QuietRun::QUIET in the mix, after the master gain (as the
        # script's ring-down measured it before, on the mix).
        def start_quiet_ring(p, frame)
          g = @master_gain.to_f
          loud = g > 0 && g != 1 ? QuietRun.float_at_least(QuietRun::QUIET / g) : QuietRun::QUIET_LOUD
          quiet = QuietRun.new((RING_QUIET_SECONDS * output.sample_rate).round, loud: loud, from: frame)
          p.ring = Ring.new(stop_frame: frame, quiet: quiet, sources: [], capped: false, active: true, choke: false, spill: false)
          p.ends_after = nil
          quiet
        end

        # Silences a ringing player's clips at its stop time, in the buffer
        # that holds it (+stop_idx+ frames in, from session frame +base+).
        def begin_ring(p, base, stop_idx)
          ring = p.ring
          ring.stop_frame = base + stop_idx
          ring.quiet.reset(ring.stop_frame)
          ring.sources.each { |s| s.ring_out(p.stop_at, choke: !!ring.choke) }
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
          # (a spill-over comes back only as the graph an undo restores)
          p = input ? @players.each_value.find { |x| x.name == name && x.ring&.active && x.input.equal?(input) } : ringing_player(name)
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
          pos = Sequence::Transport.position_at(@transport.position, frame - @frame, @transport.whole_notes_per_frame(rate))
          seconds = ((frame - ring.stop_frame) / rate.to_f).round(3)
          @journal.note_entry(
            kind: :rung_out, subject: p.name, lands: stamp(pos, frame: frame),
            data: { seconds: seconds, capped: ring.capped }
          )
        end

        # d.abs.max without allocating for real SFloat/DFloat buffers
        # (Kernels.min_max; dropouts-2), as a Float.
        def abs_peak(d)
          r = (@tail_range ||= [0.0, 0.0])
          return d.abs.max unless MB::Sound::Kernels.min_max(d, r)
          lo, hi = r
          p = -lo > hi ? -lo : hi
          p.nan? ? d.abs.max : p
        end

        # Follows a ringing player's output +data+ (+frames+ frames from
        # session frame +frame+) with its QuietRun, returning how many of
        # those frames to mix: all of them, or fewer if the tail's quiet
        # stretch reaches RING_QUIET_SECONDS inside this buffer (the player
        # then sleeps).  (#render_player reads a ringing graph in pieces
        # that end where the quiet stretch would, so it completes only at a
        # piece's end.)
        def follow_ring(p, data, frame, frames, rate)
          run = p.ring.quiet
          i = -1
          while (i += 1) < data.length
            d = data[i]
            next if d.nil? || d.empty?
            d = d.real if d.is_a?(Numo::SComplex) || d.is_a?(Numo::DComplex)
            run.track(d, frame, 0, d.length > frames ? frames : d.length)
          end

          ending = run.ends_at
          ending <= frame + frames ? MB::M.max(ending - frame, 0) : frames
        end
      end
    end
  end
end
