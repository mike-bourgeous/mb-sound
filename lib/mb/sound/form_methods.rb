module MB
  module Sound
    # Console methods for song forms, performing them, markers, and meter
    # changes (see Form, Form::Playback, Session::Markers, and
    # design/notes/arrangement.md).  MB::Sound extends itself with this
    # module.
    #
    # Example (bin/sound.rb, after defining scenes :intro, :verse, ...):
    #     flow do
    #       intro  4.bars
    #       label  :top
    #       verse  8.bars, times: 2
    #       pick   chorus: 3, drop: 1
    #       goto   :top, times: 1
    #       outro  8.bars
    #     end
    #     loop!            # stay in this section...
    #     onward           # ...then move on
    #     goto :chorus     # what plays after this section (or goto :top, a label)
    #     skip             # leave at the next bar line
    #     finish           # the outro next
    #     practice :drop   # go to the drop and stay there
    #     seek :verse      # move the timeline to the verse and play on from there
    #     marker :vo, at: bar(5, beat: 2); at_marker(:vo) { bg :vox, vox }
    #     meter 7, 8       # 7/8 from the next bar line
    module FormMethods
      # With a block, builds a song form (see Form::Builder) and plays it
      # from its launch point (+on:+, +in:+, +at:+; the next bar while
      # something plays, else now), unless +play: false+.  +seed:+ seeds
      # chance (weighted gotos and picks).  Returns the Form (its inspect prints the
      # block back).  Without a block, returns the form playing
      # (Form::Playback; its inspect says where it is and what comes next).
      # Also available as #form.
      def flow(play: true, seed: nil, at: nil, on: nil, in: nil, &block)
        arrangement = Session.current.arrangement
        return arrangement.playback unless block

        point = LaunchPoint.of(binding) or return nil
        f = arrangement.build_form(&block)
        arrangement.play_form(f, at: point, seed: seed) if play
        f
      end
      alias form flow

      # Plays a Form (built with `flow(play: false) { }` or Form.build, or
      # from `take.form`).  See #flow.  Returns the Form::Playback.
      def play_form(form, seed: nil, at: nil, on: nil, in: nil)
        point = LaunchPoint.of(binding) or return nil
        Session.current.arrangement.play_form(form, at: point, seed: seed)
      end

      # Declares a section outside a flow block, so `flow do ... end` can
      # play it with a bare call (see Arrangement#section): `section
      # :verse, 8.bars, fill: :roll`.  Also available as #define_section.
      def section(name, length, **options)
        Session.current.arrangement.section(name, length, **options)
      end
      alias define_section section

      # Repeats the section playing now until #onward (from the next
      # boundary that hasn't been decided yet).  Returns where it applies.
      # Also available as #loop_section.
      def loop!
        form_playback.loop!
      end
      alias loop_section loop!

      # Ends #loop!: the form moves on at the next undecided boundary.  Also
      # available as #unloop! and #continue_form.
      def onward
        form_playback.onward
      end
      alias unloop! onward
      alias continue_form onward

      # Goes to +name+ next (at the next undecided boundary): a label of the
      # form (the flow carries on from there), or a section (its next
      # appearance in the play order).  Also available as #goto_section.
      def goto(name)
        form_playback.goto(name)
      end
      alias goto_section goto

      # Leaves the section playing now at the next bar line, for what
      # follows it in the flow (or +name+, a section or label as in #goto).
      # Also available as #skip_section.
      def skip(name = nil)
        form_playback.skip(name)
      end
      alias skip_section skip

      # Goes to the form's last section (the ending) at the next undecided
      # boundary.  Also available as #finish_form.
      def finish
        form_playback.finish
      end
      alias finish_form finish

      # Goes to +name+ (a section or label, as in #goto) next and repeats
      # it until #onward (#goto and #loop!).  Also available as #rehearse.
      def practice(name)
        form_playback.practice(name)
      end
      alias rehearse practice

      # Sets marker +name+ (see Session::Markers) at a bar position (+at:
      # bar(5, beat: 2)+, a :position marker that follows the tempo) or an
      # absolute time (+at: 12.5.seconds+ or another Length, a :time marker
      # that doesn't move with the tempo).  Returns the marker.
      def marker(name, at:)
        session = Session.current
        pb = session.arrangement.playback
        if pb && !pb.ended? && (pb.form.sections.key?(name) || pb.form.labels.key?(name))
          kind = pb.form.sections.key?(name) ? 'section' : 'label'
          raise ArgumentError, "#{name.inspect} is a #{kind} of the song form playing (the form moves that marker); give your marker another name"
        end
        case at
        when LaunchPoint::Bar
          session.markers.set(name, kind: :position, pos: session.transport.bar_position(at.bar) + (at.beat.to_r - 1) / 4)
        when Length
          session.markers.set(name, kind: :time, seconds: at.to_seconds)
        else
          raise ArgumentError, "marker at: takes bar(n) or bar(n, beat: b) (a bar position), or a Length like 12.5.seconds (an absolute time); got #{at.inspect}"
        end
      end

      # Lists the markers (sections, labels, positions, times): name =>
      # where.
      def markers
        Session.current.markers.info
      end

      # Runs the block at marker +name+ (like #at_bar): now if the marker is
      # ahead, else the next time it is set (e.g. when a song form next
      # reaches section or label +name+).  Commands inside land exactly at the
      # marker.  Returns true if it was scheduled right away.  Warns (with
      # suggestions) for a name that is neither a marker yet nor a section
      # or label of the form playing, which is often a typo.  Also
      # available as #on_marker.
      def at_marker(name, &block)
        raise ArgumentError, 'Pass a block to run at the marker' unless block
        session = Session.current
        pb = session.arrangement.playback
        known = session.markers.to_h.keys
        known += pb.form.sections.keys + pb.form.labels.keys if pb
        unless known.include?(name)
          hint = Form.suggest(name, known.uniq)
          warn "at_marker: no marker #{name.inspect} yet; the block runs when one is set#{hint}" unless hint.empty?
        end
        session.markers.on(name) { |_m, pos|
          session.schedule(pos, description: "marker #{name.inspect}", &block)
        }
      end
      alias on_marker at_marker

      # Changes the meter to +beats+ beats of 1/+unit+ notes (`meter 7, 8`
      # for 7/8, `meter 3` for 3/4) from the next bar line (or the launch
      # point +on:+, +in:+, +at:+, aligned to a bar line), keeping every bar
      # number before it (see Sequence::Transport#meter).  With no
      # arguments, returns the meter map.  Also available as
      # #time_signature.
      def meter(beats = nil, unit = 4, at: nil, on: nil, in: nil)
        session = Session.current
        transport = session.transport
        return transport.meters.map(&:to_s) if beats.nil?

        raise ArgumentError, "meter needs a positive Integer number of beats (got #{beats.inspect})" unless beats.is_a?(Integer) && beats > 0
        raise ArgumentError, "meter's note value must be a power of two like 4 or 8 (got #{unit.inspect})" unless unit.is_a?(Integer) && unit > 0 && (unit & (unit - 1)).zero?

        point = LaunchPoint.of(binding) or return nil
        time = session.send(:launch_time, point, [], default: :bar)
        time = transport.next_bar_line(time)
        transport.meter(Rational(beats, unit), at: time)
      end
      alias time_signature meter

      private

      # The form playing, or an error.
      def form_playback
        pb = Session.current.arrangement.playback
        raise 'No song form is playing (start one with flow do ... end)' if pb.nil? || pb.ended?
        pb
      end
    end
  end
end
