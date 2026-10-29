module MB
  module Sound
    class Arrangement
      # Preset params become knobs on tracks (library-instruments-1, item 2;
      # the maintainer, 2026-10-28: "Params become knobs + curated"): when a
      # track's patch loads a graph document (`track :bass, :dnb_reese`, or
      # `preset :dnb_reese, midi: clip` inside a patch block), each of the
      # document's params that the patch doesn't give becomes the Session
      # knob :"bass/cutoff", at the param's value with its range and curve
      # (its Param), and the graph reads it (as `preset ..., cutoff:
      # knob` would), so the samples are the same until it is turned.
      # Turn, learn, scenes (`"bass/cutoff": 3000`), snapshots, undo,
      # takes, and set documents work on it like any knob.
      #
      # Params the patch gives (`preset :x, cutoff: 800`, a knob name, a
      # node) and params `bind` made follow a knob are not knobs.  Each
      # track has its own (two tracks playing dnb_reese: :"bass/cutoff" and
      # :"bass2/cutoff").  `preset` outside a track's patch (bg, plain
      # graphs, scripts) makes none: the params stay numbers.
      #
      # The track's name and Session reach `preset` through the patch's
      # build (Arrangement.counted wraps every track patch in .building).
      module TrackKnobs
        # Library entry families whose params a track playing one gets as
        # knobs, with the params that can be (read as nodes): struck
        # instruments' decay (Struck::KNOB_PARAMS).  Other families'
        # params stay numbers (their voices take numbers in places a knob
        # can't follow, or would change their sound; graph documents' are
        # all knobs, above).
        ENTRY_PARAMS = { struck: %i[decay] }.freeze

        module_function

        # { param => GraphNode::Knob } for the +names+ params of library
        # Entry +entry+ in the building track (see .knob_for), or {}
        # outside a track's patch build.
        def entry_knobs(entry, names)
          track, session = current
          return {} unless track && session
          names.each_with_object({}) do |name, h|
            param = entry.params[name] or next
            k = knob_for(session, track, param)
            h[name] = k if k
          end
        end

        # Runs the block as track +name+'s patch build in +session+ (see
        # .current).
        def building(name, session)
          old = Thread.current[:mb_sound_patch_track]
          Thread.current[:mb_sound_patch_track] = [name, session]
          yield
        ensure
          Thread.current[:mb_sound_patch_track] = old
        end

        # [track name, Session] of the track patch building on this thread,
        # or nil.  The Session is the context's (a rehearsal sandbox's
        # copies), else the track's.
        def current
          name, session = Thread.current[:mb_sound_patch_track]
          return nil unless name
          [name, Session.context&.[](:session) || session]
        end

        # Notes that the building track's patch read knob +knob+ while
        # building (GraphNode.build_value; see Arrangement::BuildKnobs), so
        # turning it rebuilds the track.  Nothing outside a track's build.
        def note_build_read(knob)
          track, session = current
          return unless track && session && knob.name
          session.arrangement.note_build_knob(track, knob.name)
        end

        # The knob name for param +param+ of track +track+'s preset.
        def knob_name(track, param)
          :"#{track}/#{param}"
        end

        # { param => GraphNode::Knob } for the params of graph Document
        # +doc+ (parsed) that +given+ (the params the patch gave) leaves
        # out, made or found in the building track's Session (see .knob_for);
        # {} outside a track's patch build.
        def params_for(doc, given)
          track, session = current
          return {} unless track && session && !doc.params.empty?
          decl = doc.declarations rescue (return {})
          doc.params.keys.each_with_object({}) do |name, h|
            next if given.key?(name)
            param = decl[name]
            next unless param.is_a?(MB::Sound::Param) && param.numeric?
            k = knob_for(session, track, param)
            h[name] = k if k
          end
        end

        # The Session knob :"track/param" for +param+ (a document param's
        # Param): an existing knob of that name with the same range and
        # curve is used as it is (keeping its value: a scene's or a turn's,
        # or a set document's knob line); one with another range or curve
        # (the track's new instrument has a param of that name) is
        # respecified and set to the param's value; else a new knob at the
        # param's value.  Nil if the name is taken by something else.
        def knob_for(session, track, param)
          kname = knob_name(track, param.name)
          default = knob_default(param)
          opts = { curve: curve_of(param), description: param.description, clamp: param.clamp }
          spec = GraphNode::Knob::Spec.new(name: kname, default: default, **opts)
          existing = session.knobs[kname]
          if existing
            return existing if existing.spec.range == spec.range && existing.spec.curve == spec.curve
            k = session.knob(kname, default, **opts) or return nil
            k.set(spec.default, frame: k.next_frame)
            return k
          end
          session.knob(kname, default, **opts)
        end

        # The knob curve for +param+: its own, except that a plain-number
        # param whose name the Param names table types as a frequency or a
        # time (cutoff, attack, decay, release, ...; graph documents
        # saved from script options have plain numbers) turns on the
        # table's :exp curve when its range stays above 0, so a cutoff
        # moves evenly in pitch.
        def curve_of(param)
          c = param.curve
          return c unless c == :linear && param.type == :number && param.range && param.bounded?
          e = MB::Sound::Param.name_entry(param.name) or return c
          r = e[:range]
          exp = e[:curve] == :exp || (r && r.begin.is_a?(MB::Sound::Pitch))
          exp && MB::Sound::Param.magnitude(param.range.begin).to_f > 0 ? :exp : c
        end

        # A ranged default for +param+: its own range at its value (typed as
        # declared), else LiteralBinding's range for its name around the
        # value.
        def knob_default(param)
          if param.range && param.bounded?
            param.range.at(param.default)
          else
            LiteralBinding.knob_default(param.name, param.default)
          end
        end
      end
    end
  end
end
