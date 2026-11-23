require 'fileutils'

module MB
  module Sound
    module Library
      # What the console's save, save!, collect, and promote do (see
      # LibraryMethods and GraphIOMethods#save).  No prompts (maintainer,
      # 2026-10-24): save never replaces, save! does, bump: true saves the
      # next version; git keeps the user shelf's history.
      module Saving
        module_function

        # Saves +graph+ as preset +name+ (see GraphIOMethods#save):
        # +replace+ allows replacing an existing preset, +bump+ picks the
        # next free version name, +tags+/+about+ go into the header (tags:,
        # description:; the library's index words), and +meta:+ keys other
        # than those into the header's descriptive `meta: { ... }`.  Prints what happened; returns the path or nil.
        def save(name, graph, replace:, bump:, tags: nil, about: nil, **opts)
          return nil unless graph_given?(name, graph, replace)
          given = name
          if (saves = replaying)
            saves.tell("save #{label(name)}")
            return nil if generator?(graph) # (library file statements: L.gen reads the shelves)
            return replay_keep(saves, name, graph, replace: replace, bump: bump, tags: tags, about: about, **opts)
          end
          return save_generator(name, graph, replace: replace, bump: bump, tags: tags, about: about, **opts) if generator?(graph)
          meta = (opts.delete(:meta) || {}).dup
          meta[:tags] = check_tags(tags) if tags
          meta[:description] = about.to_s if about
          opts[:meta] = meta unless meta.empty?

          target = GraphIO.target_path(name)
          if bump && exists?(target)
            name = next_version(name)
            target = GraphIO.target_path(name)
          end
          existed = exists?(target)
          if existed && replace && (tags.nil? || about.nil?)
            # (replacing keeps the old document's tags and description
            # unless new ones are given)
            old = GraphIO.parse(File.file?(target) ? target : GraphIO.bundle_document(GraphIO.bundle_dir(target))) rescue nil
            meta = (opts[:meta] || {}).dup
            meta[:tags] = old.header[:tags] if tags.nil? && old&.header&.[](:tags)
            meta[:description] = old.description if about.nil? && old&.description && !meta.key?(:description)
            # (and its descriptive metadata: notes, author, ...)
            kept = old ? old.meta.without(*GraphIO::Document::STAMP_KEYS) : MB::Sound::Meta::EMPTY
            meta[:meta] = kept.merge(meta[:meta] || {}).to_h unless kept.empty?
            opts[:meta] = meta unless meta.empty?
          end
          if existed && !replace
            Take.note_choice(:save, given, false)
            warn "Not saved: #{name} exists (#{shown(target)}); save! #{label(name)}, ... replaces it, bump: true saves #{label(next_version(name))}"
            return nil
          end
          path = GraphIO.save(name, graph, **opts)
          # (the name it saved as, for a replay's Saves: see #replay_keep)
          Take.note_choice(:save, given, name)
          Library.reload!
          committed = Git.commit_save(path, "save #{label(name)}#{' (replaced)' if existed}")
          puts "Saved #{name} to #{shown(path)}#{' (replaced)' if existed}#{' (committed)' if committed}"
          path
        rescue GraphIO::DumpError => e
          Take.note_choice(:save, given, false)
          warn "Not saved: #{e.message}"
          nil
        end

        # The Saves of the take replaying on this thread's Session, or nil
        # (see Take::Replay::Saves): a replay never writes to the library.
        def replaying
          Take::Replay.saves_for(Session.existing)
        end

        # True (after saying so once per take line) when a take replays,
        # so +what+ (a library write: collect, promote) is skipped.
        def replay_skip?(what)
          saves = replaying or return false
          saves.tell(what)
          true
        end

        # What #save does while a take replays: writes nothing, keeping
        # +graph+'s document text in the replay's +saves+ under the name the
        # live save used (recorded in the take line's choices), so a later
        # `preset(name)` builds what it built live.  Takes saved before
        # replays skipped saves decide as the save would now (against the
        # shelves and what the replay kept).  Returns nil.
        def replay_keep(saves, name, graph, replace:, bump:, tags: nil, about: nil, **opts)
          as = Take.replay_choice(:save, name)
          if as.nil?
            there = saves.document(name) || exists?(GraphIO.target_path(name))
            as = !there || replace ? name : (bump && next_version(name))
          end
          return nil unless as
          opts.delete(:bundle) # (a file layout: the text is the same)
          meta = (opts.delete(:meta) || {}).dup
          meta[:tags] = check_tags(tags) if tags
          meta[:description] = about.to_s if about
          opts[:meta] = meta unless meta.empty?
          saves.keep(as, GraphIO.dump(graph, name: File.basename(GraphIO.target_path(as)).delete_suffix(GraphIO::EXTENSION), **opts))
          nil
        rescue GraphIO::DumpError
          nil
        end

        # True if +graph+ is something save writes (a graph, a rack, a set,
        # a clip); else MB::Sound.live_error with what save takes and how to
        # keep a track's sound today (sd-ux-fixes-1, the review's #3:
        # `save :ghost_lead, :lead` printed "Saved" and wrote a document
        # whose body was `:lead`; `save :x, track(:lead)` raised).
        def graph_given?(name, graph, replace)
          what =
            case graph
            when Symbol then "#{graph.inspect} is a name"
            when Arrangement::Track then "track #{graph.name.inspect} is a track (its patch, clip, and routing), not a graph"
            when nil, true, false, String, Numeric then "#{graph.inspect} isn't a graph"
            end
          return true unless what
          cmd = replace ? 'save!' : 'save'
          track = graph.is_a?(Symbol) ? graph : graph.is_a?(Arrangement::Track) ? graph.name : :lead
          MB::Sound.live_error(ArgumentError.new(
            "#{cmd} #{name.inspect}, ...: #{what}; #{cmd} takes a graph (a node chain, a rack, a clip) or the set " \
            "(#{cmd} #{name.inspect}, set).  To keep a track's sound today: `save :my_set, set` saves every track with its knobs, " \
            "`ruby set` prints its track #{track.inspect} line to paste, and a fitted sound saves with save_fit #{track.inspect}; nothing was saved"
          ))
          false
        end

        # True if +value+ saves as a library generator statement (see
        # #save_generator): a clip a generator made, or a section chain.
        def generator?(value)
          (value.is_a?(Sequence::Clip) && (Generators.origin(value) || value.variations.any? { |v| v.block.is_a?(Generative::Producer) })) ||
            (value.respond_to?(:form_next) && value.respond_to?(:reseed))
        end

        # Saves a generator clip or a section chain as a library file
        # statement, `gen/<name>.rb` or `flow/<name>.rb` on the save shelf
        # (library-file syntax: `generator :x, instrument: ... do ... end`,
        # `flow :x, bars: { ... } do ... end`), the clip's recipe as the
        # block; knobs it reads become `param` lines at their current values
        # (named as the recipe names them), so `L.gen.x(energy:
        # knob(:energy))` steers it again.  +bars+ (a chain's lengths; the
        # entry's that built it by default) and +instrument+ (the
        # generator entry's by default) go on the line.  Never replaces
        # unless +replace+; +bump+ picks the next free version.
        def save_generator(name, value, replace:, bump:, tags: nil, about: nil, bars: nil, instrument: nil, sections: nil, genre: nil)
          kind = value.is_a?(Sequence::Clip) ? :generator : :flow
          dir = Library.save_shelf&.dir or raise ArgumentError, 'no shelf to save to'
          path = ->(n) { File.join(dir, kind == :flow ? 'flow' : 'gen', "#{n}.rb") }
          name = name.to_sym
          if bump && File.file?(path.(name))
            v = 2
            v += 1 while File.file?(path.("#{name.to_s.sub(/_v\d+\z/, '')}_v#{v}"))
            name = :"#{name.to_s.sub(/_v\d+\z/, '')}_v#{v}"
          end
          target = path.(name)
          existed = File.file?(target)
          if existed && !replace
            Take.note_choice(:save, name, false)
            warn "Not saved: #{name} exists (#{shown(target)}); save! #{label(name)}, ... replaces it, bump: true saves #{label(:"#{name}_v2")}"
            return nil
          end
          from = Generators.origin(value)&.entry
          settings = {}
          if kind == :generator
            inst = instrument || (from&.kind == :generator ? from.settings[:instrument] : nil)
            settings[:instrument] = inst if inst
            body, params = generator_body(value)
          else
            bars ||= Generators.bars(from)
            unless bars
              warn "Not saved: #{name}: a section chain saves with its sections' lengths (save :#{name}, chain, bars: { intro: 8, ... })"
              return nil
            end
            settings[:bars] = bars
            sections ||= from&.settings&.[](:sections)
            genre ||= from&.settings&.[](:genre)
            settings[:sections] = sections if sections
            settings[:genre] = genre if genre
            body = value.to_ruby
            params = []
          end
          settings[:tags] = check_tags(tags) if tags
          settings[:about] = about.to_s if about
          head = "#{kind} #{name.inspect}#{settings.map { |k, v| ", #{k}: #{k == :tags ? "%i[#{v.join(' ')}]" : RubyValue.to_ruby(v)}" }.join}"
          text = "library #{Library::FORMAT}\n#{head} do\n#{(params + body.lines.map(&:chomp)).map { |l| "  #{l}" }.join("\n")}\nend\n"
          FileUtils.mkdir_p(File.dirname(target))
          File.write(target, text)
          Take.note_choice(:save, name, name)
          Library.reload!
          committed = Git.commit_save(target, "save #{label(name)}#{' (replaced)' if existed}")
          puts "Saved #{name} to #{shown(target)}#{' (replaced)' if existed}#{' (committed)' if committed}"
          target
        end

        # [the recipe of generator +clip+ as Ruby (GraphIO.dump's graph
        # lines), its knobs (Clip#param_nodes) as `param` lines at their
        # values, read in the recipe by name].
        def generator_body(clip)
          built = Generators.origin(clip)
          return entry_call_body(clip, built) if built && !Generators.knob_params(built.entry).empty?
          doc = GraphIO.dump(clip, name: 'generator')
          tree = Prism.parse(doc).value.statements.body
          body = tree.reject { |st| st.is_a?(Prism::CallNode) && st.receiver.nil? && GraphIO::Document::HEADER.include?(st.name) }.map(&:slice).join("\n")
          params = clip.param_nodes.select { |k| k.is_a?(GraphNode::Knob) && k.name.to_s.match?(/\A[a-z_][a-z0-9_]*\z/) }.map { |k|
            body = body.gsub("knob(#{k.name.inspect})", k.name.to_s)
            "param #{k.name.inspect}, #{Param.literal(k.value)}"
          }
          [body, params]
        end

        # [body, params] (see #generator_body) for +clip+, which +built+'s
        # generator call built: the call, its steering params the call
        # left out (Generators.knob_params) kept as params of the new
        # entry at their current values (the track's knobs' when a track
        # steers the clip, else the defaults; gen-knobs-1), so the saved
        # generator is steered on a track as the call was; knobs given in
        # the call (`energy: knob(:energy)`) become params as above.
        def entry_call_body(clip, built)
          entry = built.entry
          turned = Generators.knobs_of(clip) || {}
          free = Generators.knob_params(entry) - built.kwargs.keys
          params = free.map { |p| entry.params[p].to_ruby('param', value: turned[p]&.value || entry.params[p].default) }
          kwargs = built.kwargs.merge(free.to_h { |p| [p, Generators::Path.new(p.to_s)] })
          body = Generators.call_text(Generators::Built.new(entry, kwargs))
          built.kwargs.each_value do |v|
            next unless v.is_a?(GraphNode::Knob) && v.name.to_s.match?(/\A[a-z_][a-z0-9_]*\z/)
            body = body.gsub("knob(#{v.name.inspect})", v.name.to_s)
            params << "param #{v.name.inspect}, #{Param.literal(v.value)}"
          end
          [body, params]
        end

        # True if a document or bundle exists at +target+ (a document path).
        def exists?(target)
          File.file?(target) || File.directory?(GraphIO.bundle_dir(target))
        end

        # The next free version name for +name+: :x -> :x_v2 (or :x_v3 when
        # :x_v2 exists), :x_v2 -> :x_v3.
        def next_version(name)
          text = name.to_s
          if (m = text.match(/\A(.*)_v(\d+)\z/))
            base = m[1]
            n = m[2].to_i + 1
          else
            base = text
            n = 2
          end
          n += 1 while exists?(GraphIO.target_path(versioned(base, n, name)))
          versioned(base, n, name)
        end

        def versioned(base, n, like)
          v = "#{base}_v#{n}"
          like.is_a?(Symbol) ? v.to_sym : v
        end

        def label(name)
          name.is_a?(Symbol) ? name.inspect : name.to_s
        end

        def shown(path)
          path.to_s.delete_prefix("#{Dir.pwd}/")
        end

        def check_tags(tags)
          list = Array(tags)
          bad = list.reject { |t| t.is_a?(Symbol) || t.is_a?(String) }
          raise ArgumentError, "tags: are words (%i[dark wide]), not #{bad.map(&:inspect).join(', ')}" unless bad.empty?
          list.map { |t| t.to_s.downcase.tr(' -', '__').to_sym }.uniq
        end
      end

      # The user shelf's git history: every save, collect, and promote
      # into the user shelf commits there ("the personal shelf is a git
      # repo that gets an auto-commit on every save", maintainer
      # 2026-10-24).  The shelf becomes a repository on first use unless it
      # sits inside another repository (then nothing is committed).
      module Git
        module_function

        # Commits +path+ (a file or bundle written on a shelf) with
        # +message+ when it is on the user shelf.  Returns true if a commit
        # was made.
        def commit_save(path, message)
          dir = Library.user_dir
          full = File.expand_path(path)
          return false unless full.start_with?("#{File.expand_path(dir)}/")
          commit(dir, message)
        end

        # Commits everything in +dir+ (a shelf) with +message+, making it a
        # repository first if it isn't inside one.  Returns true if a
        # commit was made; false when git is missing or fails (with a
        # warning once).
        def commit(dir, message)
          return false if Saving.replaying # (a take replay never commits, whatever wrote: Take::Replay::Saves)
          return false unless git?
          dir = File.expand_path(dir)
          FileUtils.mkdir_p(dir)
          top, ok = run('rev-parse', '--show-toplevel', dir: dir)
          if ok
            return false unless File.expand_path(top.strip) == dir # (inside another repository)
          else
            _, ok = run('init', '-q', dir: dir)
            return failed('git init') unless ok
          end
          _, ok = run('add', '-A', '.', dir: dir)
          return failed('git add') unless ok
          status, = run('status', '--porcelain', dir: dir)
          return false if status.to_s.strip.empty?
          _, ok = run(*identity(dir), 'commit', '-q', '-m', "mb-sound: #{message}", dir: dir)
          ok || failed('git commit')
        end

        def git?
          return @git unless @git.nil?
          _, ok = run('--version', dir: Dir.pwd)
          @git = ok
        end

        def run(*args, dir:)
          out, _, status = Starter.capture('git', '-C', dir, *args, err: :out)
          [out, status.success?]
        rescue SystemCallError
          [nil, false]
        end

        # -c options naming mb-sound as the committer when git has no
        # identity configured.
        def identity(dir)
          name, ok = run('config', 'user.name', dir: dir)
          email, ok2 = run('config', 'user.email', dir: dir)
          return [] if ok && ok2 && !name.strip.empty? && !email.strip.empty?
          ['-c', 'user.name=mb-sound', '-c', 'user.email=mb-sound@localhost']
        end

        def failed(what)
          unless @warned
            @warned = true
            warn "Library: #{what} failed in the user shelf; saves there aren't committed"
          end
          false
        end
      end

      # Copies entries between shelves (collect and promote): graph
      # documents and bundles as files, library-file entries as their
      # statements (with the local variables they read) into the file of
      # the same relative path, and class presets as a library-file line.
      module Copy
        module_function

        # Copies +entry+ into shelf directory +dir+.  Returns [:copied,
        # path], [:same, path] (already there, the same), or [:exists,
        # path] (there and different; replaced only with +replace+:
        # [:replaced, path]).
        def entry(entry, dir, replace: false)
          if entry.settings.is_a?(Hash) && entry.settings[:document]
            document(entry.location, dir, replace: replace)
          else
            statement(entry, dir, replace: replace)
          end
        end

        # Copies the document at +path+ (or its bundle) into +dir+.
        def document(path, dir, replace: false)
          src_dir = File.dirname(path)
          bundle = src_dir.end_with?('.mbg') && File.basename(path).start_with?(File.basename(src_dir).delete_suffix('.mbg'))
          src = bundle ? src_dir : path
          dest = File.join(dir, File.basename(src))
          FileUtils.mkdir_p(dir)
          if File.exist?(dest)
            return [:same, dest] if same_tree?(src, dest)
            return [:exists, dest] unless replace
            FileUtils.rm_rf(dest)
            FileUtils.cp_r(src, dest)
            return [:replaced, dest]
          end
          FileUtils.cp_r(src, dest)
          [:copied, dest]
        end

        # Writes +entry+'s statement into +dir+ (the file of the same
        # relative path as its source, or <family>.rb for class presets).
        def statement(entry, dir, replace: false)
          text, rel = statement_text(entry)
          dest = File.join(dir, rel)
          FileUtils.mkdir_p(File.dirname(dest))
          existing = File.file?(dest) ? File.read(dest) : nil
          found = existing && find_statement(existing, entry)
          if found
            return [:same, dest] if found[:text].strip == text.lines.last(entry_lines(text)).join.strip || found[:text].strip == text.strip
            return [:exists, dest] unless replace
            File.write(dest, existing[0...found[:start]] + text.strip + existing[found[:end]..])
            return [:replaced, dest]
          end
          body = existing ? existing.chomp + "\n\n" + text.strip + "\n" : "library #{Library::FORMAT}\n\n#{text.strip}\n"
          File.write(dest, body)
          [:copied, dest]
        end

        # [text, relative path] for +entry+'s statement.
        def statement_text(entry)
          if entry.source
            path = entry.location.to_s.sub(/:\d+\z/, '')
            rel = entry.shelf.dir && path.start_with?("#{entry.shelf.dir}/") ? path.delete_prefix("#{entry.shelf.dir}/") : File.basename(path)
            [entry.source, rel]
          else
            [preset_line(entry), "#{entry.family}.rb"]
          end
        end

        # The library-file line for a class preset (a Presettable entry).
        def preset_line(entry)
          raise ArgumentError, "#{entry.label} has no settings to copy" unless entry.settings.is_a?(Hash)
          lit = MB::Sound::Param.method(:literal)
          parts = [entry.name.inspect]
          parts << "tags: %i[#{entry.tags.join(' ')}]" unless entry.tags.empty?
          parts << "about: #{entry.about.inspect}" if entry.about
          aliases = Library.index.aliases(entry.family).select { |_, n| n == entry.name }.keys
          parts << "aliases: %i[#{aliases.join(' ')}]" unless aliases.empty?
          entry.settings.each { |k, v| parts << "#{k}: #{lit.(v)}" }
          "#{entry.family} #{parts.join(",\n  ")}"
        end

        # How many lines at the end of +text+ are the entry statement (the
        # rest are the local variables it reads).
        def entry_lines(text)
          tree = Prism.parse(text).value
          last = tree.statements.body.last
          last ? last.location.end_line - last.location.start_line + 1 : text.lines.length
        end

        # The statement of +entry+'s verb and name in library file text
        # +source+ ({ start:, end:, text: } byte offsets), or nil.
        def find_statement(source, entry)
          verb = statement_verb(entry)
          Prism.parse(source).value.statements.body.each do |st|
            next unless st.is_a?(Prism::CallNode) && st.receiver.nil? && st.name == verb
            first = st.arguments&.arguments&.first
            next unless first.is_a?(Prism::SymbolNode) && first.unescaped.to_sym == entry.name
            return { start: st.location.start_offset, end: st.location.end_offset, text: st.slice }
          end
          nil
        end

        def statement_verb(entry)
          return entry.family unless entry.family == :preset
          entry.settings && FileLoader::RACKS.find { |_, (ctor, *)| ctor == entry.settings[:rack] }&.first || :instrument
        end

        def same_tree?(a, b)
          return File.file?(b) && File.binread(a) == File.binread(b) if File.file?(a)
          return false unless File.directory?(b)
          files = ->(d) { Dir.glob('**/*', base: d).select { |f| File.file?(File.join(d, f)) }.sort }
          files.(a) == files.(b) && files.(a).all? { |f| File.binread(File.join(a, f)) == File.binread(File.join(b, f)) }
        end
      end
    end
  end
end
