module MB
  module Sound
    module HandTune
      # What retune did to a track's fit patch: +track+, +name+ (the fit's),
      # +path+ (its document, where it is edited), +version+ (the copy the
      # track plays now), +added+, +removed+, +kept+ (param names),
      # +changed+ (kept params whose range, curve, or value changed),
      # +reset+ ({ param => [turned value, new value] }: turned knobs whose
      # new range leaves their value out, back at the param's value),
      # +pair+ (the A/B pair, matched again, or nil), +unchanged+ (true when
      # the file was the document playing: nothing done).
      Retuned = Data.define(:track, :name, :path, :version, :added, :removed, :kept, :changed, :reset, :pair, :unchanged, :body) do
        def to_s
          if unchanged
            return "retune #{track.inspect}: #{path} is the document playing (edit it and retune #{track.inspect} again, or give the code: " \
                   "retune #{track.inspect}, #{body.inspect}, new_param: (lo..hi).at(value))"
          end
          list = ->(names) { names.map(&:to_s).join(', ') }
          parts = []
          parts << "added #{list.(added)}" unless added.empty?
          parts << "removed #{list.(removed)} (their knobs stay, unread)" unless removed.empty?
          parts << "kept #{kept.length} (turned values carry)" unless kept.empty?
          parts << "changed #{list.(changed)}" unless changed.empty?
          reset.each { |p, (from, to)| parts << "#{p} back to #{Take::Reader.number(to)} (its new range leaves out #{Take::Reader.number(from)})" }
          match = pair ? "; #{pair}" : ''
          "retune #{track.inspect}: #{name} now has #{kept.length + added.length} knobs: #{parts.join('; ')}#{match}"
        end

        def inspect = "#<HandTune::Retuned #{track.inspect}: +#{added.length} -#{removed.length} =#{kept.length}>"
      end

      module_function

      # The fit patch +track+ plays in +session+: [the document's path (the
      # version playing), the parsed Document, the path it is edited at
      # (its lineage: FitPatch.write)].  Raises ArgumentError when the
      # track plays no fit patch.
      def fit_of(session, track)
        tr = session.arrangement.tracks[track] or raise ArgumentError, "retune: no track #{track.inspect} (tune #{track.inspect}, code, ... first)"
        path = Reference.document_path(session, track)
        doc = path && GraphIO.parse(path)
        unless doc && doc.meta[:from] == 'fit_patch'
          raise ArgumentError, "retune: #{track.inspect} plays no fit patch (tune #{track.inspect}, code, ...; or design #{track.inspect}, fit_patch(...))"
        end
        e = Arrangement::InstrumentPatch.entry_of(tr.patch)
        lineage = (e.settings[:lineage] if e&.settings.is_a?(Hash)) || path
        [path, doc, lineage]
      end

      # The retunes of each track in +session+ ({ track => [[take line id,
      # old version path, new version path], ...] }), so the live take's
      # reader (Take#turns) starts from the version playing when the take
      # began.
      def history(session)
        (@history ||= ObjectSpace::WeakKeyMap.new)[session] ||= {}
      end

      # Redefines the fit patch +track+ plays (see HandTuneMethods#retune):
      # from +code+ (new params in +params+, found among the code's numbers;
      # kept params by name), from +document+ (a whole document's text), or
      # from the document's file (edited since it was loaded; the take
      # records what was read, as `retune :kick, document: "..."`).  Returns
      # a Retuned.
      def retune(track, code = nil, document: nil, **params)
        raise ArgumentError, "retune names a track: retune :kick, code, noise: (0.0..1.0).at(0.1) (or edit the fit's file and retune :kick)" unless track.is_a?(Symbol)
        raise ArgumentError, 'retune: give the code or a document:, not both' if code && document
        session = Session.current
        old_path, old, lineage = fit_of(session, track)
        old_text = File.read(old_path)
        name = (old.name || File.basename(lineage, GraphIO::EXTENSION)).to_sym
        given = FitPatch.declare(params)
        if code
          decls = old.declarations.select { |_, p| p.is_a?(Param) }.merge(given)
          text, _sites, missing, skipped = FitPatch.document(code, decls, name: name, description: old.description, match: given.keys)
          lost = given.keys & missing
          unless lost.empty?
            why = lost.map { |k| skipped[k] ? "#{k} (#{skipped[k]})" : "#{k} (#{RubyValue.to_ruby(given[k].default)} is none of the code's numbers)" }
            raise FitPatch::Error, "retune #{track.inspect}: #{why.join('; ')}: give each new param's number as it is written in the code"
          end
          # (edits to the file not loaded yet stay beside it)
          File.rename(lineage, "#{lineage}.unloaded") if File.file?(lineage) && File.read(lineage) != old_text
        elsif document
          raise ArgumentError, "retune #{track.inspect}, document: takes the whole document (its param lines); give no params beside it" unless params.empty?
          text = document.to_s
        else
          raise ArgumentError, "retune #{track.inspect}: new params go with the code (retune #{track.inspect}, code, #{params.keys.first}: ...)" unless params.empty?
          text = File.read(lineage)
          if text == old_text
            return Retuned.new(track: track, name: name, path: lineage, version: old_path, added: [], removed: [], kept: old.params.keys, changed: [],
                               reset: {}, pair: Reference.pair(session, track), unchanged: true, body: FitPatch.body_of(old_text))
          end
          Take.record_call_as(:retune, "retune #{track.inspect}, document: #{text.inspect}") { |n| (n.arguments&.arguments || []).length == 1 }
        end
        FitPatch.check(name, text)
        new_doc = GraphIO.parse(text)
        before = old.declarations
        after = new_doc.declarations
        kept = before.keys & after.keys
        changed = kept.reject { |p| same_param?(before[p], after[p]) }
        reset = kept.each_with_object({}) { |p, h|
          k = session.knobs[Session::Name.param(track, p)] or next
          next if Arrangement::TrackKnobs.untouched?(k) || !k.value.is_a?(Numeric) || after[p].range.nil? || after[p].range.cover?(k.value)
          h[p] = [k.value, after[p].default]
        }
        path, version, entry = FitPatch.write(name, text, path: lineage)
        pair = Reference.pair(session, track)
        # (the rebuild and the reference's new level: one undo step)
        Session.with_context(session: session) {
          session.command("retune #{track.inspect}") {
            MB::Sound.track(track, entry)
            Reference.match(session, pair) if pair
          }
        }
        (history(session)[track] ||= []) << [Take.current_line_id, old_path, version]
        Retuned.new(track: track, name: name, path: path, version: version, added: after.keys - before.keys, removed: before.keys - after.keys,
                    kept: kept, changed: changed, reset: reset, pair: pair, unchanged: false, body: FitPatch.body_of(text))
      end

      # True if Params +a+ and +b+ declare the same knob (range, curve,
      # value).
      def same_param?(a, b)
        a.range == b.range && a.default == b.default && a.curve == b.curve
      end
    end

    # The console's retune (MB::Sound extends it; hand-tune-2).
    module RetuneMethods
      # Redefines a tuned fit patch's graph while you tune it (add an
      # oscillator, a noise layer, a filter): turned knobs keep their
      # values, the new block's numbers become knobs, removed ones are
      # listed, the reference is loudness-matched again, and the take
      # records it as one line.  Give the new code (the document's body,
      # its params by name, `retune :kick` alone prints it) with each new
      # number as a param, `(lo..hi).at(value)` as in tune:
      #
      #     retune :kick, "kit(midi, seed: 1) { voice(:kick) { |h| h.mix(h.body(tune, decay: decay), h.noise(decay: 0.08) * 0.2) } }",
      #       noise: (0.0..1.0).at(0.2), noise_decay: (0.005..0.5).at(0.08)
      #
      # or edit the fit's file (tmp/fits/kick_fit.mbg.rb: new param lines,
      # the code) and `retune :kick`.  The track rebuilds as a new version
      # of the same instrument (its state carried where it maps; one undo
      # step).  Returns a HandTune::Retuned (it prints what changed).
      def retune(track, code = nil, document: nil, **params)
        r = HandTune.retune(track, code, document: document, **params)
        puts r.to_s
        r
      end
    end

    extend RetuneMethods
  end
end
