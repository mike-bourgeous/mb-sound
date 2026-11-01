module MB
  module Sound
    class Arrangement
      # A stream wired into a track (see Wires): the MIDI::Stream, its
      # +text+ for listings (Ruby when the stream knows how it was made,
      # MIDI::Stream#lineage, else a description), and its +lineage+ (nil
      # for live streams, which set documents can't save).
      class Wire < Data.define(:stream, :text, :lineage)
        # True if +input+ (an `arm ..., input:` value) is a stream to wire
        # rather than a MIDI input name (nil, a Symbol, or a String naming
        # a device).
        def self.stream?(input)
          !(input.nil? || input.is_a?(Symbol) || input.is_a?(String) || input.is_a?(Integer))
        end

        # The Wire of +obj+ (anything MIDI::Stream.for takes), or nil after
        # MB::Sound.live_error for what isn't a stream (a Clip, a Kit, or
        # an unattached transform chain, with what to write instead).
        # +what+ names the command for the error.
        def self.of(obj, what = 'wire')
          hint =
            case obj
            when Sequence::Clip, Sequence::Kit
              "#{what} takes a MIDI stream; a clip plays on a track's instrument with swap :name, clip (bg :name, clip starts a stopped track), " \
                'and wire :name, clip.stream plays it as a stream'
            when MIDI::Transform::Spec
              "#{what} takes a MIDI stream; apply the chain to one: midi.through(#{obj}) (live input) or riff.stream.through(#{obj})"
            end
          return MB::Sound.live_error(ArgumentError.new(hint)) if hint

          stream = begin
                     MIDI::Stream.for(obj)
                   rescue ArgumentError
                     return MB::Sound.live_error(ArgumentError.new("#{what} takes a MIDI stream (midi.arp(:up), riff.stream.echo(1.n8, 3), midi_file('x.mid'); got #{obj.inspect[0, 80]})"))
                   end
          new(stream: stream, text: text(stream), lineage: stream.lineage)
        end

        # +stream+ as text: Ruby from its lineage (clips by their names),
        # else "live" and what it is.  +clip_text+ gives a root clip's
        # text, +lit+ (a Recipe::RubyWriter) the arguments'.
        def self.text(stream, clip_text: nil, lit: nil)
          ruby(stream.lineage, clip_text: clip_text, lit: lit) || "live #{stream}"
        end

        # Lineage +lineage+ as Ruby that makes the stream again
        # (`riff.stream.echo(1.n8, 3)`, `midi_file("x.mid").arp(:up)`), or
        # nil if it has none or an argument doesn't print.
        def self.ruby(lineage, clip_text: nil, lit: nil)
          return nil if lineage.nil?
          lit ||= GraphNode::Recipe::RubyWriter.new(nil)
          clip_text ||= ->(c) { c.respond_to?(:name) && c.name ? c.name.to_s : 'clip' }
          root = lineage.root
          base =
            case root
            when MIDI::ClipSource
              "#{clip_text.call(root.clip)}.stream#{root.channel.zero? ? '' : "(channel: #{root.channel})"}"
            when MIDI::FileSource
              name = root.midi_file.filename
              return nil unless name.is_a?(String)
              "midi_file(#{name.inspect}#{', loop: true' if root.loop?})"
            end
          return nil if base.nil?

          steps = lineage.steps.map { |name, args, kwargs|
            parts = args.map { |a| lit.literal(a) } + kwargs.map { |k, v| "#{lit.key_text(k)} #{lit.literal(v)}" }
            "#{name}#{"(#{parts.join(', ')})" unless parts.empty?}"
          }
          text = [base, *steps].join('.')
          text.include?("\u0003") ? nil : text # (an argument printed as a FIXME)
        end

        def to_s = text
      end

      # Streams wired into tracks (design/notes/arrangement.md, Wires;
      # maintainer 2026-11-01: "wire + arm for now, but with stream as
      # track source saved for later"): `wire :lead, midi.arp(:up)` arms
      # :lead on its own MIDI input (Session::Name.wire, :"lead/wire")
      # that the stream plays into from the track's launch point, so the
      # track's patch plays the stream exactly as it plays live input (its
      # monitor, :"lead/live"), and `rec`/`capture` record it.  The
      # track's clip plays on beside it (`stop :lead` stops the clip;
      # `unwire :lead` the stream).  Each command is one undo step;
      # takes replay the stream's events from their MIDI log.
      module Wires
        # Wires +stream+ (a MIDI::Stream or anything MIDI::Stream.for
        # takes: `midi.arp(:up)`, a clip's `riff.stream.echo(1.n8, 3)`, a
        # MIDI file's `midi_file('x.mid')`) into track +name+ at its launch
        # point (+on:+, +in:+, +at:+, else its +q:+ or the set's quant; now
        # when nothing plays), replacing a stream wired before (the
        # monitor plays on).  +monitor: false+ records it without playing
        # it.  Returns the :wire journal entry.
        def wire(name = nil, stream = nil, monitor: true, at: nil, on: nil, in: nil)
          point = LaunchPoint.of(binding) or return nil
          unless name.is_a?(Symbol)
            return MB::Sound.live_error(ArgumentError.new("wire takes a track name and a stream: wire :lead, midi.arp(:up) (got #{name.inspect[0, 60]})"))
          end
          if stream.nil?
            return MB::Sound.live_error(ArgumentError.new("wire #{name.inspect}, stream: give the stream (midi.arp(:up), riff.stream.echo(1.n8, 3)); unwire #{name.inspect} stops one"))
          end
          if stream.is_a?(Symbol) || stream.is_a?(String)
            return MB::Sound.live_error(ArgumentError.new("wire #{name.inspect} takes a stream; a named MIDI input is arm #{name.inspect}, input: #{stream.inspect}"))
          end
          if stream.is_a?(Sequence::Clip) || stream.is_a?(Sequence::Kit)
            what = stream.is_a?(Sequence::Kit) ? 'kit' : 'clip'
            return MB::Sound.live_error(ArgumentError.new(
              "wire takes a MIDI stream; a #{what} plays on #{name.inspect}'s instrument with swap #{name.inspect}, #{what} " \
              "(bg #{name.inspect}, #{what} starts a stopped track)#{what == 'clip' ? ", and wire #{name.inspect}, clip.stream plays it as a stream" : ''}"
            ))
          end
          tr = recording_track(name, wire: true) or return nil
          w = Wire.of(stream, "wire #{name.inspect},") or return nil

          wc = nil
          @session.command("wire #{name.inspect}") {
            before = undo_state
            time = resolve(tr.q || @quant, tr, point)
            _, wc = arm_now(tr, monitor: monitor, input: nil, wire: w, time: time)
            @session.note_undo_extra(self, before, undo_state)
          }
          @session.journal[wc.seq]
        end

        # Stops the streams wired into tracks +names+ (every wired track if
        # none are named) at each track's launch point (+on:+, +in:+,
        # +at:+), disarming them (their monitors stop; notes the stream
        # held end there).  Returns the :unwire journal entries (one, or an
        # Array).
        def unwire(*names, at: nil, on: nil, in: nil)
          point = LaunchPoint.of(binding) or return nil
          names = names.flatten
          wired = arms.select { |_, a| a.wired? }
          names = wired.keys if names.empty?
          return [] if names.empty?
          unless (missing = names.reject { |n| wired.key?(n) }).empty?
            list = wired.empty? ? 'nothing is wired' : "wired: #{wired.keys.map(&:inspect).join(', ')}"
            return MB::Sound.live_error(ArgumentError.new("No stream is wired into #{missing.map(&:inspect).join(', ')} (#{list})#{Form.suggest(missing.first, wired.keys)}"))
          end

          entries = nil
          @session.command("unwire #{names.map(&:inspect).join(', ')}") {
            before = undo_state
            entries = names.map { |n|
              tr = tracks[n]
              time = tr ? resolve(tr.q || @quant, tr, point) : @session.now
              disarm_now(n, time).last
            }
            @session.note_undo_extra(self, before, undo_state)
          }
          entries = entries.map { |c| @session.journal[c.seq] }
          entries.length == 1 ? entries.first : entries
        end

        # The wired tracks: a Hash from track name to its stream's text
        # (Ruby for streams that print, `live ...` for live ones).
        def wires
          arms.select { |_, a| a.wired? }.transform_values { |a| a.wire.text }
        end

        # The wired tracks' Wires (a Hash from track name to Wire), for
        # set documents (GraphIO::SetWriter).
        def wire_definitions
          arms.select { |_, a| a.wired? }.transform_values(&:wire)
        end
      end
    end
  end
end
