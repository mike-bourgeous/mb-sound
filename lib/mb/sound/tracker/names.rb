module MB
  module Sound
    module Tracker
      # Names for a module's samples (tuner-fixes-2; the maintainer,
      # 2026-11-09: "The samples need names other than s3m and a number.
      # Use the instrument name from the file if it's not actually just
      # message text").  Trackers had no song message field in the older
      # formats, so composers wrote their credits, greetings, and notes
      # into the instrument and sample names, a line per slot ("By ... of",
      # "Greetings:", a phone number, a row of underscores).  Names.of
      # keeps the names that name a sound and falls back to the module's
      # file name and the slot number (`tune 09`) for the rest:
      #
      # - per name: empty, decoration (no letters or digits), placeholders
      #   (`blank`, `untitled`), and lines that read as text (MESSAGE:
      #   credits and greeting words, sentences of three or more words with
      #   a function word, URLs and addresses, years and versions, phone
      #   numbers, IRC channels, comma lists, a line ending like a sentence
      #   or a label, smileys, centered text) are message text;
      # - per list: a header line ("Greetings:") makes the names after it,
      #   up to an empty slot, message text; when half or more of a list's names are message text,
      #   the rest of it is too unless it names an instrument (INSTRUMENT:
      #   bass, snare, string, 303, ...: a greeted handle reads like a
      #   name), and a name between two message lines is message text;
      # - XM and IT instruments name their samples first (the instrument
      #   list is what the tracker shows; the first instrument whose keymap
      #   plays a sample names it), then the samples' own names;
      # - names stay unique: a name given to several slots gets each slot's
      #   number (`snare 17`, `snare 19`).
      #
      #     Tracker::Names.of(Tracker.read('tune.xm'), file: 'tune.xm')
      #     # => ["303-1", "303-2", ..., "tune 13", ...]
      module Names
        # Words that make a name message text on their own.
        MESSAGE = %w[
          by thanks thank thanx thx greets greet greetings greeting hello hi hope please sorry email mail irc bbs download downloaded
          release copyright reserved rights composed written enjoy member members crew team visit contact aka vs info
        ].freeze

        # Function words: three or more words with one of them read as a
        # sentence.
        FUNCTION = %w[
          the a an is are was were be been of to my me you your i im it its this that for from with at on in and or but if so as we our
          us not no can will all any some more just like here there what who when have has had do did
        ].freeze

        # A line announcing a list (it ends with a colon or an arrow).
        HEADER = /(:|-+>)\s*\z/

        # Placeholder names trackers fill empty slots with.
        PLACEHOLDERS = %w[blank empty untitled noname none sample instrument].freeze

        # Instrument words (in a list that is mostly message text, a name
        # with one of these still names its sound).
        INSTRUMENT = /
          bass|kick|snare|hihat|hi-hat|cymbal|crash|ride|clap|drum|perc|string|piano|organ|choir|vocal|voice|guitar|brass|horn|flute|
          violin|cello|bell|synth|lead|pad\b|303|808|909|\bbd\b|\bsd\b|\bhh\b|\bhat\b|\btom\b|\bsub\b|\bstab|\bfx\b|\barp\b|\bsaw\b|
          \bsqr\b|square|sine|\bnoise|sweep|pluck|chord|\bhit\b|shaker|conga|bongo|cowbell|clav|\bsax|trumpet|marimba|xylo|harp|acid|
          reese|\bloop|\bbeat|\bvox\b|orch|timpani|tabla|zap|laser|lazer
        /xi

        module_function

        # The display names of +song+'s samples (an Array by sample index;
        # see Names): from the file where they name a sound, else
        # "<file> <slot>" (+file+: the module's path or base name; else the
        # song's title, else its format).
        def of(song, file: nil)
          base = file ? File.basename(file.to_s, '.*') : song.title.to_s.strip
          base = song.format.to_s if base.empty?
          samples = keep(song.samples.map { |s| s&.name })
          instruments = song.instruments ? keep(song.instruments.map { |x| x&.name }) : []
          owners = owners_of(song)
          names = song.samples.each_index.map { |i|
            o = owners[i]
            (o && instruments[o]) || samples[i] || format('%s %02d', base, i + 1)
          }
          counts = names.map(&:downcase).tally
          names.each_with_index.map { |n, i| counts[n.downcase] > 1 && !n.end_with?(format(' %02d', i + 1)) ? format('%s %02d', n, i + 1) : n }
        end

        # The names of +list+ (raw names, one per slot) that name a sound,
        # cleaned (spaces squeezed), nil for the rest (see Names).
        def keep(list)
          cleaned = list.map { |n| clean(n) }
          flags = list.map { |n| message?(n) }
          # (a header line, "Greetings:" or "Greeting : --->", announces a
          # list: the names right after it, up to an empty slot, are its)
          list.each_with_index do |n, i|
            next unless flags[i] && n.to_s.strip.match?(HEADER)
            j = i + 1
            while j < list.length && cleaned[j]
              flags[j] ||= !cleaned[j].match?(INSTRUMENT)
              j += 1
            end
          end
          used = cleaned.each_index.reject { |i| cleaned[i].nil? }
          return cleaned if used.empty?
          share = used.count { |i| flags[i] }.fdiv(used.length)
          used.each_with_index.each_with_object(Array.new(list.length)) do |(i, k), out|
            next if flags[i]
            n = cleaned[i]
            if share >= 0.5
              next unless n.match?(INSTRUMENT)
            else
              prev = k > 0 ? used[k - 1] : nil
              nxt = used[k + 1]
              next if prev && nxt && flags[prev] && flags[nxt] && !n.match?(INSTRUMENT)
            end
            out[i] = n
          end
        end

        # +name+ stripped and squeezed, or nil when empty, decoration only,
        # or a placeholder.
        def clean(name)
          n = name.to_s.gsub(/[^[:print:]]/, ' ').strip.squeeze(' ')
          return nil if n.empty? || !n.match?(/[[:alnum:]]/)
          return nil if PLACEHOLDERS.include?(n.downcase.delete('^a-z'))
          n
        end

        # True if +name+ (raw, as the file holds it) reads as message text
        # (see Names).
        def message?(name)
          raw = name.to_s
          t = raw.strip
          return false if t.empty? || !t.match?(/[[:alnum:]]/)
          return true if raw.match?(/\A {2,}\S/) # (centered or indented: a line of a text)
          return true if t.match?(%r{@|https?:|www\.|\.(com|net|org|edu|txt|nfo|diz)\b|\w/\w+\.\w}i)
          return true if t.match?(/\b(19|20)\d\d\b|'\d\d\b|\(c\)|©|\bv?\d+\.\d+\b/i)
          return true if t.match?(/\(?\d{3}\)?[ -]?\d{3}-\d{4}/) # (a phone number)
          return true if t.match?(/#[a-z]/i) || t.count(',') >= 2
          return true if t.match?(%r{[[:alpha:]]/[[:alpha:]]}) && !t.match?(INSTRUMENT) # (a handle and its group: name/GROUP)
          return true if t.match?(/[!?]\s*\z|[[:alpha:]]\.\s*\z|:\s*\z|\.\.\.|[:;]-?[)(D]|\(:|-+>|<-+/)
          return true if t.match?(/\A[[:alpha:]]+\s*:\s*\S/) && !t.match?(INSTRUMENT) # (a label: "Name: ...")
          words = t.downcase.scan(/[a-z']+/)
          return true if words.intersect?(MESSAGE)
          words.length >= 3 && words.intersect?(FUNCTION)
        end

        # { sample index => the index of the first instrument whose keymap
        # plays it } for XM and IT instrument songs ({} otherwise).
        def owners_of(song)
          return {} unless song.instruments
          out = {}
          song.instruments.each_with_index do |ins, k|
            next unless ins
            ins.keymap.each { |smp, _note| out[smp] ||= k if smp }
          end
          out
        end
      end
    end
  end
end
