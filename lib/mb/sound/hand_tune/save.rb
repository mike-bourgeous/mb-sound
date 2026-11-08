module MB
  module Sound
    module HandTune
      # What save_fit wrote (tuner-fixes-1): +track+, +name+ (the fit's),
      # +path+ (its file), +version+ (the copy the track plays now),
      # +changed+ ({ param => [from, to] }), +promoted+ (bound knobs that
      # became params), +refused+ ({ knob name => why it stays a number in
      # the code }), +unloaded+ (the path an edited, never loaded file was
      # moved to, or nil), +nothing+ (true when the file held the knobs'
      # values already: nothing written), +replay+ (true in a take's
      # replay: only the version written).
      Saved = Data.define(:track, :name, :path, :version, :changed, :promoted, :refused, :unloaded, :nothing, :replay, :entry) do
        def initialize(track:, name:, path:, version:, changed:, promoted:, refused:, unloaded:, nothing:, replay:, entry: nil) = super

        def to_s
          if nothing
            msg = "save_fit #{track.inspect}: nothing to save: #{File.basename(path)} holds #{track}'s knobs as they are"
            return refused.empty? ? msg : "#{msg}; not in the file: #{refused_text}"
          end
          list = changed.first(6).map { |p, (a, b)| "#{p} #{Take::Reader.number(a)} -> #{Take::Reader.number(b)}" }.join(', ')
          list += ", ... (#{changed.length} in all)" if changed.length > 6
          parts = ["saved #{track}: #{changed.length} knob#{'s' unless changed.length == 1} into #{replay ? "#{File.basename(path)} (replay: its version only)" : path} (#{list})"]
          parts << "new params from bound numbers: #{promoted.join(', ')}" unless promoted.empty?
          parts << "not saved: #{refused_text}" unless refused.empty?
          parts << "your earlier edits of the file, never loaded, are in #{unloaded}" if unloaded
          parts << "save #{entry.number} of #{name} (fit_saves #{track.inspect} lists them; restore_fit #{track.inspect}, n puts one back)" if entry
          parts << "tune #{track.inspect} or the tuner start from it now" unless replay
          parts.join("\n")
        end

        def inspect = "#<HandTune::Saved #{track.inspect}: #{changed.length} changed#{nothing ? ', nothing written' : ''}>"

        private

        def refused_text = refused.map { |k, why| "#{k} (#{why})" }.join('; ')
      end

      module_function

      # The knobs of +track+ (in +session+) whose values its fit's file
      # doesn't hold: { param => [the file's value, the knob's] }, for the
      # document's params and for knobs bound to numbers of its code
      # (`bind`; their file value is the number).  {} for a track playing
      # no fit patch.  Leaving the tuner or tuning again warns about them.
      def unsaved(session, track)
        tr = session.arrangement.tracks[track] or return {}
        path = Reference.document_path(session, track) or return {}
        e = Arrangement::InstrumentPatch.entry_of(tr.patch)
        lineage = (e.settings[:lineage] if e&.settings.is_a?(Hash)) || path
        base = parsed(File.file?(lineage) ? lineage : path) || parsed(path) or return {}
        return {} unless base.meta[:from] == 'fit_patch'
        decls = base.declarations
        out = {}
        decls.each do |p, decl|
          next unless decl.is_a?(Param)
          k = session.knobs[Session::Name.param(track, p)] or next
          next unless k.value.is_a?(Numeric)
          was = Param.magnitude(decl.default).to_f rescue next
          out[p] = [was, k.value.to_f] unless same_number?(was, k.value)
        end
        own = decls.keys.map { |p| Session::Name.param(track, p) }
        bound(session, track).each do |pname, (t, kname, k)|
          next if own.include?(kname) || out.key?(pname)
          lit = Param.magnitude(t.value).to_f
          out[pname] = [lit, k.value.to_f] unless same_number?(lit, k.value)
        end
        out
      rescue StandardError
        {}
      end

      # .unsaved for +track+ in the first of the screen's session,
      # Session.existing, and +sessions+ that has the track (the UI's panes
      # ask from their own threads).
      def unsaved_somewhere(track, *sessions)
        s = [UI.tiles&.session, Session.existing, *sessions].compact.find { |x| x.arrangement.tracks.key?(track) } or return {}
        unsaved(s, track)
      end

      # The parsed document at +path+ (cached by its time and size: the
      # tune strip asks .unsaved a few times a second), or nil.
      def parsed(path)
        st = File.stat(path)
        key = [st.mtime.to_r, st.size]
        @parsed ||= {}
        hit = @parsed[path]
        return hit[1] if hit && hit[0] == key
        @parsed.clear if @parsed.size > 64
        doc = GraphIO.parse(File.read(path))
        @parsed[path] = [key, doc]
        doc
      rescue SystemCallError, GraphIO::LoadError
        nil
      end

      # The `turn` line putting +track+'s unsaved knobs (see .unsaved)
      # back, or nil.
      def unsaved_line(session, track, list = unsaved(session, track))
        return nil if list.empty?
        "turn #{track.inspect}, #{list.map { |p, (_, v)| "#{p}: #{Take::Reader.number(v)}" }.join(', ')}"
      end

      # True if numbers +a+ and +b+ are the same as a document prints
      # them.
      def same_number?(a, b)
        (a.to_f - b.to_f).abs <= 1e-12 * [1.0, a.to_f.abs].max
      end

      # The knobs bound to numbers of +track+'s code (`bind :vocal, env:
      # :decay, nth: 1`): { param name (the knob's leaf) => [LiteralBinding::Target,
      # knob name, knob] }.
      def bound(session, track)
        tr = session.arrangement.tracks[track] or return {}
        list = tr.patch.respond_to?(:literal_bindings) ? tr.patch.literal_bindings : []
        list.each_with_object({}) do |(t, kname), h|
          next unless t.kind == :call
          k = session.knobs[kname] or next
          next unless k.value.is_a?(Numeric)
          h[Session::Name[kname].leaf.to_sym] = [t, kname, k]
        end
      end

      # Writes +track+'s knobs into its fit's file (see
      # SaveFitMethods#save_fit), or +document+ (the whole text, as a take
      # keeps the save) and plays that version (one undo step: the same
      # sound, the knobs now the file's values).  Returns a Saved.
      def save_fit(track, document: nil, note: nil, reset: false)
        raise ArgumentError, 'save_fit names a track: save_fit :kick' unless track.is_a?(Symbol)
        session = Session.current
        old_path, old, lineage = fit_of(session, track)
        name = (old.name || File.basename(lineage, GraphIO::EXTENSION)).to_sym
        replay = !!Session.context&.replaying?
        refused = {}
        if document
          text = document.to_s
          new_doc = GraphIO.parse(text)
          changed = new_doc.declarations.filter_map { |p, d|
            o = old.declarations[p]
            next if o && same_number?(Param.magnitude(o.default), Param.magnitude(d.default))
            [p, [o&.default, d.default]]
          }.to_h
          promoted = new_doc.declarations.keys - old.declarations.keys
        else
          old_text = File.read(old_path)
          values = old.declarations.filter_map { |p, _|
            k = session.knobs[Session::Name.param(track, p)]
            k && k.value.is_a?(Numeric) ? [p, k.value] : nil
          }.to_h
          promote = {}
          own = old.declarations.keys.map { |p| Session::Name.param(track, p) }
          bound(session, track).each do |pname, (t, kname, k)|
            next if own.include?(kname)
            lit = Param.magnitude(t.value).to_f
            next if same_number?(lit, k.value)
            r = k.spec.range
            ranged = r.is_a?(Range) ? (Param.magnitude(r.begin).to_f..Param.magnitude(r.end).to_f).at(lit) : Arrangement::LiteralBinding.knob_default(t.param, t.value)
            slot = t.slot.is_a?(Array) && t.slot.length == 2 ? t.slot : nil
            promote[pname] = { at: ranged, call: slot && t.call_name, nth: t.nth, slot: slot }
            values[pname] = k.value
          end
          text, changed, promoted, refused = FitPatch.retext(old_text, values, promote: promote)
          if changed.empty? && promoted.empty?
            return Saved.new(track: track, name: name, path: lineage, version: old_path, changed: {}, promoted: [], refused: refused,
                             unloaded: nil, nothing: true, replay: replay)
          end
        end
        FitPatch.check(name, text)
        unloaded = nil
        if !replay && !document && File.file?(lineage)
          now = File.read(lineage)
          # (edits to the file not loaded yet stay beside it, as retune keeps them)
          if now != old_text && now != text && !FitPatch.tuned_at(now)
            unloaded = "#{lineage}.unloaded"
            File.rename(lineage, unloaded)
          end
        end
        path, version, entry = FitPatch.write(name, text, path: lineage, file: !replay)
        Take.record_call_as(:save_fit, "save_fit #{track.inspect}, document: #{text.inspect}#{", note: #{note.to_s.inspect}" if note}") unless document
        Session.with_context(session: session) {
          session.command("save_fit #{track.inspect}") {
            # (restore_fit: the knobs take the restored values)
            reset ? Arrangement::TrackKnobs.resetting { MB::Sound.track(track, entry) } : MB::Sound.track(track, entry)
          }
        }
        (history(session)[track] ||= []) << [Take.current_line_id, old_path, version]
        logged = replay ? nil : record_save(name, version, note: note, changed: changed.length)
        Saved.new(track: track, name: name, path: path, version: version, changed: changed.freeze, promoted: promoted.freeze, refused: refused,
                  unloaded: unloaded, nothing: false, replay: replay, entry: logged)
      end
      # One save of a fit (its history: .saves): +number+ (1 the first,
      # kept as later saves come), +at+ (the time, UTC, as written), +version+
      # (the immutable copy's path), +knobs+ (how many changed), +note+ (or
      # nil), +take+ (where in which take, or nil).
      SaveEntry = Data.define(:number, :at, :version, :knobs, :note, :take) do
        def to_s
          when_ = at.to_s.sub('T', ' ').sub(/Z\z/, ' UTC')
          "#{number.to_s.rjust(3)}  #{when_}  #{knobs} knob#{'s' unless knobs == 1}#{note ? "  #{note}" : ''}#{take ? "  (#{take})" : ''}" \
            "#{File.file?(version) ? '' : '  (its version is gone)'}"
        end
      end

      # The history file of fit +name+'s saves: FitPatch.dir/history/NAME.rb,
      # one `save` line a save, oldest first (readable Ruby, read with
      # Prism, never run; appended a line at a time, so a crash leaves
      # every line written before it).
      def history_path(name) = File.join(FitPatch.dir, 'history', "#{name}.rb")

      # Appends a save of fit +name+ (its +version+ path) to its history;
      # returns the SaveEntry.
      def record_save(name, version, note: nil, changed: 0, at: Time.now)
        path = history_path(name)
        FileUtils.mkdir_p(File.dirname(path))
        number = saves(name).map(&:number).max.to_i + 1
        t, line = Session.context&.take_line
        take = t && "#{t.autosave_path ? File.basename(t.autosave_path) : "the take started #{t.start[:time]}"}, line #{t.lines.index(line).to_i + 1}"
        stamp = at.utc.strftime('%Y-%m-%dT%H:%M:%SZ')
        rel = version.delete_prefix("#{FitPatch.dir}/")
        fields = ["save #{number}", "at: #{stamp.inspect}", "version: #{rel.inspect}", "knobs: #{changed.to_i}"]
        fields << "note: #{note.to_s.inspect}" if note
        fields << "take: #{take.inspect}" if take
        File.open(path, 'a') do |f|
          f.write("# mb-sound: the saves of fit #{name} (save_fit), oldest first; fit_saves lists them, restore_fit puts one back.\n") if f.size == 0
          f.write("#{fields.join(', ')}\n")
          f.flush
        end
        SaveEntry.new(number: number, at: stamp, version: File.join(FitPatch.dir, rel), knobs: changed.to_i, note: note&.to_s, take: take)
      end

      # Fit +name+'s saves (SaveEntries, oldest first), from its history
      # file (walked with Prism: lines it can't read are left out).
      def saves(name)
        path = history_path(name)
        return [] unless File.file?(path)
        Prism.parse(File.read(path)).value.statements.body.filter_map { |st|
          next unless st.is_a?(Prism::CallNode) && st.name == :save && st.receiver.nil?
          args = st.arguments&.arguments || []
          n = args.first
          kw = args.find { |a| a.is_a?(Prism::KeywordHashNode) }
          next unless n.is_a?(Prism::IntegerNode) && kw
          h = kw.elements.to_h { |e| [e.key.unescaped.to_sym, e.value.is_a?(Prism::IntegerNode) ? e.value.value : (e.value.unescaped rescue nil)] }
          next unless h[:version] && h[:at]
          SaveEntry.new(number: n.value, at: h[:at], version: File.expand_path(h[:version], FitPatch.dir), knobs: h[:knobs].to_i, note: h[:note], take: h[:take])
        }
      end

      # The fit name +track+ plays (its document's), or nil.
      def fit_name(session, track)
        _p, doc, lineage = fit_of(session, track)
        (doc.name || File.basename(lineage, GraphIO::EXTENSION)).to_sym
      end

      # Plays save +number+ of the fit +track+ plays (see .saves) again: its
      # version becomes the fit's file and the track's patch, its knobs at
      # the saved values (one undo step; recorded as a save of its own).
      def restore_fit(track, number)
        session = Session.current
        name = fit_name(session, track)
        e = saves(name).find { |x| x.number == number } or raise ArgumentError, "restore_fit #{track.inspect}, #{number.inspect}: #{name} has no save #{number.inspect} (fit_saves #{track.inspect} lists them)"
        raise ArgumentError, "restore_fit #{track.inspect}, #{number}: its version #{e.version} is gone" unless File.file?(e.version)
        text = File.read(e.version)
        Take.record_call_as(:restore_fit, "save_fit #{track.inspect}, document: #{text.inspect}, note: #{"restored save #{number}".inspect}")
        save_fit(track, document: text, note: "restored save #{number} (#{e.at})", reset: true)
      end
    end

    # The console's fit_saves and restore_fit (MB::Sound extends them;
    # tuner-fixes-1).
    module FitSavesMethods
      # Lists the saves of the fit track +track+ plays (save_fit), newest
      # first: number, time, how many knobs changed, the note, and the take.
      # Returns the SaveEntries.
      #
      #     fit_saves :kick
      def fit_saves(track)
        session = Session.current
        name = HandTune.fit_name(session, track)
        list = HandTune.saves(name).reverse
        if list.empty?
          puts "#{name}: no saves yet (S in the inspector, or save_fit #{track.inspect}, note: 'why')"
        else
          puts "#{name}: #{list.length} save#{'s' unless list.length == 1}, newest first (restore_fit #{track.inspect}, n plays one again):", *list.map(&:to_s)
        end
        list
      end

      # Plays save +number+ (from fit_saves) of the fit track +track+ plays
      # again: the fit's file, the track's patch, and its knobs (one undo
      # step: undo goes back).  Returns a HandTune::Saved.
      #
      #     restore_fit :kick, 2
      def restore_fit(track, number)
        s = HandTune.restore_fit(track, number)
        puts s.to_s
        s
      end
    end

    extend FitSavesMethods


    # The console's save_fit (MB::Sound extends it; tuner-fixes-1).
    module SaveFitMethods
      # Saves a tuned fit patch: the track's knobs as they are now become
      # the values of its fit file's params (tmp/fits/kick_fit.mbg.rb), and
      # knobs you bound to numbers of its code (`bind`, Enter on a param
      # in the inspector) become new params where the code writes them.
      # The track then plays the saved file (one undo step, the same
      # sound), the file's header says when it was tuned, and `tune` (the
      # tuner too) starts from your saved values from then on instead of
      # writing the fit's numbers over them (`fresh: true` does).  S in the
      # tuning screen's inspector.  Returns a HandTune::Saved (it prints
      # what was written where).
      #
      #     save_fit :kick
      #     # saved kick: 3 knobs into tmp/fits/kick_fit.mbg.rb (tune 51.02 -> 51.82, ...)
      #
      # +note:+ says why, in the fit's save history (fit_saves lists it,
      # restore_fit puts a save back).
      def save_fit(track, document: nil, note: nil)
        s = HandTune.save_fit(track, document: document, note: note)
        puts s.to_s
        s
      end
    end

    extend SaveFitMethods
  end
end
