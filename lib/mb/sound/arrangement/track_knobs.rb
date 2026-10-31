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
      # :"bass2/cutoff").  `preset` outside a track's patch (plain graphs,
      # scripts) makes none: the params stay numbers, until a named `bg`
      # player plays the graph (.follow_params: :"pad/cutoff").
      #
      # The track's name and Session reach `preset` through the patch's
      # build (Arrangement.counted wraps every track patch in .building).
      module TrackKnobs
        # Library entry families whose params a track playing one gets as
        # knobs, with the params that can be (read as nodes), by entry:
        # struck instruments' decay (Struck::KNOB_PARAMS), genre patches'
        # settings (Genre::PATCH_KNOBS; library-2, the maintainer
        # 2026-10-31: "Genre patches now").  Other families' params stay
        # numbers (SQ-80's later, once its ban lifts; graph documents' are
        # all knobs, above).
        ENTRY_PARAMS = {
          struck: ->(_entry) { MB::Sound::Struck::KNOB_PARAMS },
          genre_patch: ->(entry) { MB::Sound::Genre::PATCH_KNOBS.fetch(entry.name, {}).keys },
        }.freeze

        module_function

        # The params of library Entry +entry+ that a track playing it gets
        # as knobs (ENTRY_PARAMS), or nil for families without.
        def entry_params(entry)
          ENTRY_PARAMS[entry.family]&.call(entry)
        end

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
        def building(name, session, &block)
          Session.with_context_fields(patch_track: [name, session], &block)
        end

        # [track name, Session] of the track patch building on this thread,
        # or nil.  The Session is the context's (a rehearsal sandbox's
        # copies), else the track's.
        def current
          name, session = Session.context&.patch_track
          return nil unless name
          [name, Session.context.session || session]
        end

        # Notes that the building track's patch read knob +knob+ while
        # building (GraphNode.build_value; see Arrangement::BuildKnobs), so
        # turning it rebuilds the track.  Nothing outside a track's build.
        def note_build_read(knob)
          track, session = current
          return unless track && session && knob.name
          session.arrangement.note_build_knob(track, knob.name)
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

        # A named player's knobs for the graph documents in +nodes+ (bg
        # presets get param knobs like tracks; the maintainer, 2026-10-30:
        # "Yes"): `bg :pad, preset(:dnb_pad, midi: clip)` makes each
        # document param the load left to its value the Session knob
        # :"pad/cutoff" (see .knob_for), and the param's Constants follow it
        # (GraphNode::Constant#follow): the same samples until it is turned.
        # Params given to `preset` (numbers, nodes, knob names), knob lines,
        # params the graph read while building (a knob couldn't change
        # them; GraphNode.build_value), and params already following are
        # left alone.  A player given another document's graph starts its
        # reused knobs at the new params' values ("Always reset", as a
        # track's new instrument does); the same document again keeps
        # turned ones.  While +name+ plays, reused knobs' new values are
        # collected instead ({ knob => value }, returned) for the new
        # graph's landing (see .land); otherwise they are set now and {} is
        # returned.  Nothing for unnamed players, outside a Session, or for
        # names with a "/" (CUE's :"acid/cue").
        def follow_params(session, name, nodes)
          return {} unless session && name.is_a?(Symbol) && !name.to_s.include?('/')
          found = Array(nodes).flat_map { |n| n.respond_to?(:graph) ? [n, *n.graph] : [n] }
          docs = found.grep(GraphNode::Constant).filter_map(&:param_of).uniq(&:object_id) # (also inside other nodes: preset(...).at(-6.db))
          return {} if docs.empty?

          free = docs.flat_map { |doc|
            decl = (doc.declarations rescue nil) or next []
            doc.params.filter_map { |pname, spec|
              next if spec[:given] || spec[:bound] || spec[:knob]
              param = decl[pname]
              next unless param.is_a?(MB::Sound::Param) && param.numeric?
              consts = (doc.knob_nodes[pname] || []).grep(GraphNode::Constant)
              next if consts.empty? || consts.any? { |c| c.following || c.build_read? }
              [param, consts]
            }
          }
          return {} if free.empty?

          paths = docs.map { |d| (d.path || d.name).to_s }.sort
          seen = (player_documents[session] ||= {})
          same = seen[name] == paths
          seen[name] = paths
          landings = {}
          build = -> {
            free.each { |param, consts|
              k = knob_for(session, name, param) or next
              consts.each { |c| c.follow(k) }
            }
          }
          deferred = session.players.key?(name) ? -> { deferring(landings) { build.call } } : build
          same ? deferred.call : resetting { deferred.call }
          landings
        end

        # Turns the knobs in +landings+ (from .follow_params) to their
        # values at whole note +time+ (the new graph's landing), each
        # journaled in the command running now.
        def land(session, landings, time)
          landings.each { |k, v| session.turn(k.name, v, start_time: time, build: true) unless v == k.value }
        end

        # The documents each named player's knobs were made for ({ Session
        # => { name => [paths] } }, weak), so a player given another
        # document's graph resets its knobs.
        def player_documents
          @player_documents ||= ObjectSpace::WeakKeyMap.new
        end

        # The Session knob :"track/param" for +param+ (a document param's
        # Param), made at the param's value, or reused when the track had
        # one of that name (its instrument built again, or a new instrument
        # with a param of that name: the library picker's loads,
        # ui-scaffold-1).  A reused knob takes the new range and curve, and:
        # - left where its last instrument put it (untouched since
        #   TrackKnobs set it): the new param's value, so each instrument
        #   loaded sounds as designed (dnb_sub's 110 Hz cutoff doesn't
        #   carry into dnb_reese);
        # - turned (or set by a scene, a snapshot, a set document's knob
        #   line): keeps its value when the new range holds it, else the
        #   param's value.
        # While .deferring (a playing track given a new instrument), the
        # values are collected for its launch point instead of set now (the
        # old instrument plays on until then).  Nil if the name is taken by
        # something else.
        def knob_for(session, track, param)
          kname = Session::Name.param(track, param.name)
          default = knob_default(param)
          opts = { curve: curve_of(param), description: param.description, clamp: param.clamp }
          spec = GraphNode::Knob::Spec.new(name: kname, default: default, **opts)
          existing = session.knobs[kname]
          unless existing
            k = session.knob(kname, default, **opts)
            preset_values[k] = spec.default if k
            return k
          end

          pending = Thread.current[:mb_sound_knob_landings]
          carry = !Thread.current[:mb_sound_knob_reset] && !pending&.key?(existing) && !untouched?(existing) && existing.value.is_a?(Numeric) &&
                  spec.range.cover?(existing.value)
          same = existing.spec.range == spec.range && existing.spec.curve == spec.curve
          k = same ? existing : (session.knob(kname, default, range: nil, **opts) or return nil) # (range: nil: the default's range replaces the old one)
          if pending&.key?(k)
            # (the same build again: its value was decided)
          elsif carry
            place(k, k.value) if pending # (noted, so a second build of the patch keeps it)
          else
            place(k, spec.default)
            preset_values[k] = spec.default
          end
          k
        end

        # Runs the block with every reused knob .knob_for gives taking the
        # param's value, turned or not (a track given another instrument;
        # the maintainer, 2026-10-30: "Always reset"; before carry-1 a
        # turned knob kept its value when the new range held it).
        def resetting
          Internal.with_local(:mb_sound_knob_reset, true) { yield }
        end

        # Runs the block collecting the values .knob_for gives reused knobs
        # into +list+ ({ knob => value }, yielded) instead of setting them
        # (see Arrangement#change_instrument, which turns them at the
        # track's launch point).
        def deferring(list = {})
          Internal.with_local(:mb_sound_knob_landings, list) { yield list }
        end

        # The values TrackKnobs gave its knobs ({ knob => value }, weak), so
        # .knob_for can tell a knob left where an instrument put it from a
        # turned one.
        def preset_values
          @preset_values ||= ObjectSpace::WeakKeyMap.new
        end

        # True if knob +k+ is where TrackKnobs last put it.
        def untouched?(k)
          v = preset_values[k]
          return false if v.nil? || !k.value.is_a?(Numeric)
          (k.value.to_f - v.to_f).abs <= 1e-9 * [v.to_f.abs, 1.0].max
        end

        # Gives knob +k+ +value+: now (its next frame), or into the
        # .deferring list (which turns only values that differ).
        def place(k, value)
          pending = Thread.current[:mb_sound_knob_landings]
          if pending
            pending[k] = value
          elsif value != k.value
            k.set(value, frame: k.next_frame)
          end
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
