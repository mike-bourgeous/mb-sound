module MB
  module Sound
    class Session
      # Tempo ramps and followed tempo (tempo-maps-1; design/notes/
      # tempo_sync.md, "Tempo maps"): journaled :tempo changes (subject
      # :tempo) that change the transport's tempo map (Sequence::TempoMap)
      # where they land, and the tempo cells that render a moving tempo.
      #
      # A :tempo change is a timeline change, like a seek: it lands at the
      # start of a span on its exact frame (see Seeks#timeline_change?).
      # While the map's tempo moves (a ramp in progress, a followed knob or
      # param), #process_buffer ends spans at every TempoMap::CELL run
      # frames and at the map's breakpoints, and each span plays at the
      # map's tempo at its first position, so every buffer size renders the
      # same frames at the same tempos.
      module TempoChanges
        # The tempo map before a change, for undo.
        TempoState = Data.define(:map, :bpm)

        # Changes the tempo at the launch point (+at+, a LaunchPoint; now by
        # default) or +start_time+ (whole notes): to +bpm+ (a number or a
        # Tempo) right there, or ramping to it over +over+ (bars through the
        # meter map, a Duration, or seconds) shaped by +curve+ (a Curve or
        # its name; linear in BPM by default) from the tempo in effect
        # where it lands; or following +follow+ (a knob name, a Knob or
        # reader, or a MIDI::Param such as `4.bars.lfo.at(150..180)`) read
        # once per tempo cell.  Returns the Change.
        def change_tempo_map(bpm = nil, over: nil, curve: nil, follow: nil, at: nil, start_time: nil)
          raise ArgumentError, 'Give a tempo or a source to follow, not both' if bpm && follow
          raise ArgumentError, 'over: ramps to a tempo; it needs one (bpm 140, over: 4.bars)' if over && bpm.nil?
          follow = check_tempo_source(follow) if follow
          target = Sequence::TempoMap.check_bpm(bpm) if bpm
          curve = curve.nil? ? nil : Curve[curve]
          check_ramp_length(over) if over

          point = at || LaunchPoint::NONE
          time = start_time && !point.given? ? start_time.to_r : launch_time(point, [], default: :now)
          data = { bpm: bpm, over: over, curve: curve&.to_ruby, follow: follow && Sequence::TempoMap.source_ruby(follow) }.compact
          change(:tempo, :tempo, time, data: data) { |t|
            @transport.tempo_change(at: [t, @transport.position].max) { |map, pos|
              if follow
                map.follow(follow, at: pos, last: @transport.bpm.to_r)
              elsif over
                from = map.varying_at?(pos) ? @transport.bpm.to_r : map.bpm_at(pos)
                length = ramp_length(over, pos, from, target, curve)
                map.with(Sequence::TempoMap::Ramp.new(pos: pos, from: from, to: target, length: length, curve: curve))
              else
                map.step(target, at: pos)
              end
            }
          }
        end

        # The source of a followed tempo checked and ready to read: knob
        # names (checked now), Knobs and readers as they are, and anything
        # MIDI::Param reads (tempo LFOs like `4.bars.lfo.at(150..180)`, cc
        # params, clips, sums of those).  Audio-rate nodes raise, pointing
        # at a knob that follows them.
        def check_tempo_source(source)
          case source
          when Symbol
            knob!(source)
            source
          when GraphNode::Knob, GraphNode::Knob::Reader
            source
          when MIDI::Param::Base
            source
          when GraphNode, Sequence::Clip
            MIDI::Param.wrap(source, 'bpm')
          else
            raise ArgumentError, "bpm follows a knob name (bpm :tempo), knob(:tempo), or a param like 4.bars.lfo.at(150..180) (got #{ArgTypes.describe_value(source) rescue source.inspect})"
          end
        rescue MIDI::Param::NotAParam => e
          raise ArgumentError, "#{e.message}; for a tempo, make a knob follow it and follow the knob: knob :tempo, 120, range: 60..200; turn :tempo, follow: node; bpm :tempo"
        end

        private

        # Reads a followed tempo source at timeline position +pos+ (the
        # first frame of the span about to render).
        def read_tempo_source(source, pos)
          case source
          when Symbol then knob!(source).value_at(pos, frame: @frame)
          when GraphNode::Knob then source.value_at(pos, frame: @frame)
          when GraphNode::Knob::Reader then source.knob.value_at(pos, frame: @frame)
          else source.value_at(pos, transport: @transport, stream: nil)
          end
        end

        def check_ramp_length(over)
          ok = case over
               when Numeric then over.real? && over.finite? && over > 0
               when Sequence::Duration then over.whole_notes > 0
               when MB::Sound::Length::Seconds then over.to_f > 0
               else false
               end
          raise ArgumentError, "over: is how long the ramp lasts: bars (4), a Duration (4.bars, 3.beats), or seconds (10.seconds) (got #{over.inspect})" unless ok
        end

        # The ramp's length in whole notes from position +pos+ (see
        # #change_tempo_map).
        def ramp_length(over, pos, from, to, curve)
          case over
          when Numeric then @transport.bars_length(pos, Sequence::Duration.rational(over))
          when Sequence::Duration then over.whole_notes
          when MB::Sound::Length::Seconds then Sequence::TempoMap.ramp_length_for_seconds(from, to, over.to_f, curve)
          end
        end

        # Before a span of up to +count+ frames: sets the transport's tempo
        # for the span from the tempo map and returns how many frames the
        # span may cover (to the next tempo cell or map breakpoint), or nil
        # for no limit (a constant tempo: the old path).
        def tempo_cell(count)
          return nil unless @transport.tempo_moves?
          map = @transport.tempo_map
          unless map.fixed? || map.varying_at?(@transport.position) || map.next_break(@transport.position)
            @transport.set_cell_bpm(map.bpm_at(@transport.position))
            @transport.settle_tempo
            return nil
          end
          pos = @transport.position
          limit = nil
          if map.varying_at?(pos)
            # The tempo is read at the cell's start, or where the map, its
            # segment, or the timeline (a seek) changed inside it: frames
            # every buffer size shares
            seg = map.segment_at(pos)
            cell = @run_frame / Sequence::TempoMap::CELL
            key = @tempo_cell_key
            unless key && key[0] == cell && key[1].equal?(map) && key[2].equal?(seg) && key[3] == @transport.generation
              @tempo_reader ||= method(:read_tempo_source)
              @transport.set_cell_bpm(map.bpm_at(pos, @tempo_reader))
              @tempo_cell_key = [cell, map, seg, @transport.generation]
            end
            limit = Sequence::TempoMap::CELL - (@run_frame % Sequence::TempoMap::CELL)
          else
            @transport.set_cell_bpm(map.bpm_at(pos))
          end
          if (nb = map.next_break(pos))
            per_sample = span_per_sample
            k = ((nb - pos) / per_sample).ceil
            k = 1 if k < 1
            limit = k if limit.nil? || k < limit
          end
          limit && limit < count ? limit : nil
        end

        def tempo_snapshot
          TempoState.new(map: @transport.tempo_map, bpm: @transport.bpm)
        end

        def restore_tempo(state)
          raise 'Nothing to restore for the tempo' unless state.is_a?(TempoState)
          if state.map.static?
            @transport.bpm = state.bpm
          else
            @transport.tempo_change { |_map, _pos| state.map }
          end
        end
      end
    end
  end
end
