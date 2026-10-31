module MB
  module Sound
    # The library's console commands (bin/sound.rb): find, shelves,
    # collect, promote (save and save! are GraphIOMethods').  Entries are
    # also reached through the heads under MB::Sound::L (L.fx.reverb.hall).
    #
    # Example (bin/sound.rb):
    #     find 'dark bass'                      # ranked: head path, kind, shelf, why
    #     find :bright, kind: :effect
    #     L.fx.reverb.hall.(220.hz.saw)         # an entry, used
    #     shelves                               # where entries come from, in search order
    #     collect                               # copy the presets this song used into its presets/
    #     promote :dark_hall, to: :user         # a song's preset onto the user shelf
    module LibraryMethods
      # Searches the library (every shelf, in search order): +query+ is
      # words ("dark bass"), Symbols, or an Array of them, each matching an
      # entry's name, a tag, its family or kind, or its description; hits
      # that match every word come first.  +kind:+ (:instrument, :effect,
      # :kit, :clip, :master, :set, :envelope, ...) and +family:+
      # (:reverb, :preset, ...) narrow it.  Returns Library::Index::Results
      # (a table: head path, kind, shelf, why it matched, what it
      # shadows; `.first` is the best Entry).
      #
      #     find 'dark bass'
      #     find :bright, kind: :effect
      #     find('hall').first.(220.hz.saw)
      def find(query = nil, kind: nil, family: nil, limit: 20)
        Library.index.find(query, kind: kind, family: family, limit: limit)
      end

      # The shelves in search order (the first match of a name wins), with
      # how many entries each holds; returns the Shelf values.
      #
      #     shelves
      def shelves
        list = Library.shelves
        all = Library.index.all_entries
        list.each do |s|
          n = all.count { |e| e.shelf == s }
          puts format('  %-8s %4d  %s', s.name, n, s.label.delete_prefix("#{s.name} "))
        end
        conflicts = Library.index.conflicts
        puts "  #{conflicts.length} name#{'s' if conflicts.length != 1} shadow#{'s' if conflicts.length == 1} others (find shows them)" unless conflicts.empty?
        list
      end

      # Copies every preset this song used (looked up by name or loaded:
      # Library::Index#uses) from the user and gem shelves into the
      # song's presets/ (the project shelf; +to:+ another directory), so
      # the song keeps sounding the same when those shelves change: the
      # copies come first in search order (a pinned copy equal to the
      # entry it shadows doesn't warn).  The built-ins it used are pinned
      # (the maintainer, 2026-10-31: "Pin instead"): presets/pins.rb gets
      # the mb-sound version and a fingerprint of each one's settings
      # (Library::Pins), and loading the song's shelf warns when one has
      # changed since; collecting again pins it as it is now.  +builtin:
      # true+ copies them instead.  +only:+ names the entries to copy or
      # pin.  Never replaces a copied file that differs (it says so);
      # prints what it copied and pinned.  Returns [entry, path] pairs
      # (pins: the pins file).  (Provisional name, after Ableton's Collect
      # All and Save; maintainer, 2026-10-26.)
      #
      #     collect
      #     collect only: %i[dark_hall], builtin: true
      def collect(to: nil, builtin: false, only: nil)
        dir = to ? File.expand_path(to.to_s) : collect_dir
        list = Library.index.uses.reject { |e|
          e.shelf.name == :session || (e.shelf.dir && File.expand_path(e.shelf.dir) == dir) ||
            (only && !Array(only).map(&:to_sym).include?(e.name))
        }
        builtins, others = list.partition { |e| e.shelf.shipped? }
        others += builtins if builtin
        done = others.filter_map { |e| copy_entry(e, dir, replace: false, verb: 'Collected') }
        done += pin_entries(dir, builtins) unless builtin || builtins.empty?
        puts "Nothing to collect (#{Library.index.uses.empty? ? 'no presets used yet' : 'every preset used is on the project shelf'})" if done.empty?
        Library.reload!
        done
      end

      # Plays library entry +entry+ (an Entry, or its name) for a listen,
      # as player :audition: an instrument's demo phrase, a kit's beat, an
      # effect or mastering chain on a demo phrase, a resonator's strike
      # (Library::Audition).  On CUE when the output has it
      # (Session#cue_heard?: CUE channels, or cue_output :split/:phones),
      # else on MAIN at Audition::MAIN_GAIN (-6 dB), starting on the next
      # beat (the maintainer, 2026-10-30), so it plays in time with the set.  Another
      # audition replaces it; `audition off` stops it.  The library
      # picker's `a` key runs this line (ui :sound).  Returns an
      # Audition::Started (one line), or the stop's journal entries.
      #
      #     audition L.inst.dnb.dnb_reese
      #     audition L.fx.reverb.hall
      #     audition :tr909
      #     audition off
      def audition(entry = :off)
        s = Session.current
        playing = s.players.keys & %i[audition audition/cue]
        if entry.nil? || entry == :off || entry == false
          return 'audition: nothing playing' if playing.empty?
          out = []
          out.concat(Array(uncue(:audition))) if playing.include?(:"audition/cue")
          out.concat(Array(stop(:audition))) if playing.include?(:audition)
          return out
        end

        e = Library::Audition.entry_for(entry)
        g = Playable.graph(Library::Audition.playable(e))
        if s.cue_heard?
          stop(:audition) if playing.include?(:audition)
          change = cue(:audition, g, on: :beat)
          where = :cue
        else
          uncue(:audition) if playing.include?(:"audition/cue")
          gain = Library::Audition::MAIN_GAIN.to_f
          quiet = Playable::Graph.new(nodes: g.nodes.map { |n| n * gain }, description: g.description, ends: g.ends, note: g.note)
          change = bg(:audition, quiet, on: :beat)
          where = :main
        end
        Library::Audition::Started.new(path: e.head_path, what: g.description.delete_prefix("#{e.head_path} "), where: where, change: change)
      end

      # Copies preset +name+ (an Entry, or a name found first on the
      # project or $MB_SOUND_PRESETS shelf, else anywhere; +family:+ for
      # class presets like :reverb) onto shelf +to:+ (:user, :gem: the
      # first gem shelf, or a directory).  Never replaces one that differs
      # (#promote! does).  Saves to the user shelf commit there.  Returns
      # the path, or nil.  (Provisional name; maintainer, 2026-10-26.)
      #
      #     promote :dark_hall, to: :user
      #     promote :big_plate, family: :reverb, to: :gem
      def promote(name, to: :user, family: :preset)
        promote_entry(name, to, family, replace: false)
      end

      # Promotes like #promote, replacing what the target shelf has under
      # that name (the user shelf's git history keeps it).
      def promote!(name, to: :user, family: :preset)
        promote_entry(name, to, family, replace: true)
      end

      private

      def collect_dir
        shelf = Library.shelves.find { |s| %i[env project].include?(s.name) }
        return shelf.dir if shelf
        raise ArgumentError, 'collect copies into a song\'s presets/ (a project: a directory whose Gemfile names mb-sound); give to: a directory'
      end

      def promote_entry(name, to, family, replace:)
        entry = name.is_a?(Library::Entry) ? name : promote_source(name.to_sym, family)
        dir = case to
              when :user then Library.user_dir
              when :gem
                Library.shelf(:gem)&.dir or raise ArgumentError, 'no gem shelf (a gem in the bundle whose gemspec metadata names mb_sound_shelf)'
              when String, Pathname then File.expand_path(to.to_s)
              else raise ArgumentError, "to: is :user, :gem, or a directory (got #{to.inspect})"
              end
        if entry.shelf.dir && File.expand_path(entry.shelf.dir) == File.expand_path(dir)
          raise ArgumentError, "#{entry.label} is already on that shelf (#{dir})"
        end
        r = copy_entry(entry, dir, replace: replace, verb: 'Promoted')
        Library.reload!
        r&.last
      end

      def promote_source(name, family)
        list = Library.index.entries(family: family, shadowed: true, documents: family == :preset).select { |e| e.name == name }
        raise ArgumentError, "no #{family} #{name.inspect} in the library#{GraphIO.suggest(name, Library.index.names(family))}" if list.empty?
        list.find { |e| %i[env project].include?(e.shelf.name) } || list.first
      end

      # Pins built-in entries +list+ in +dir+'s pins file (Library::Pins),
      # printing each; returns [entry, pins file] pairs.
      def pin_entries(dir, list)
        path = File.join(dir, Library::Pins::FILE)
        shown = path.delete_prefix("#{Dir.pwd}/")
        Library::Pins.write(dir, list).map { |e, status, old|
          case status
          when :pinned then puts "Pinned built-in #{e.label} (mb-sound #{GraphIO.library_version}) in #{shown}"
          when :same then puts "Built-in #{e.label} is already pinned in #{shown}"
          else puts "Pinned built-in #{e.label} again in #{shown} (it was pinned with mb-sound #{old.mb_sound}#{', and has changed since' if old.fingerprint != Library::Pins.fingerprint(e)})"
          end
          [e, path]
        }
      end

      def copy_entry(e, dir, replace:, verb:)
        status, path = Library::Copy.entry(e, dir, replace: replace)
        shown = path.delete_prefix("#{Dir.pwd}/")
        case status
        when :exists
          warn "Not copied: #{e.label} differs from the one in #{shown}; #{verb == 'Promoted' ? 'promote!' : 'promote!/save!'} replaces it"
          return nil
        when :same
          puts "#{e.label} is already in #{shown}"
        else
          committed = File.expand_path(path).start_with?("#{File.expand_path(Library.user_dir)}/") && Library::Git.commit(Library.user_dir, "#{verb.downcase} #{e.label}")
          puts "#{verb} #{e.label} from the #{e.shelf.name} shelf to #{shown}#{' (replaced)' if status == :replaced}#{' (committed)' if committed}"
        end
        [e, path]
      end
    end
    extend LibraryMethods
  end
end
