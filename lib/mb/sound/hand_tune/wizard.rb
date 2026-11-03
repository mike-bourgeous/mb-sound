require 'json'
require 'prism'

module MB
  module Sound
    module HandTune
      # The tuner (hand-tune-3; the maintainer, 2026-11-03: "I'd like a
      # wizard-ish UI for hand tuning where I can select a reference and
      # paired synth from a list"): a front end over `tune` in three steps.
      #
      # 1. **A reference** from a list: the hand-tune queue's items
      #    (.queue_dir), the sound files of a folder (.folder; the last one
      #    is remembered), and the Samples already read or played by a
      #    track's sampler.  Each shows its length (from the file's header,
      #    Sample::LoopInfo) and a summary (Summary: pitch, envelope shape,
      #    decay), worked out in the background (Background) for the
      #    entries looked at.
      # 2. **A synth** for it (#synths): the queue item's fit, the fit
      #    documents of the track (FitPatch.dir and their versions), the
      #    init voice, a blank voice (a sine with an ADSR set from the
      #    reference's envelope), and the library's instruments and kits
      #    (word relevance to the reference first).  The entry looked at gets
      #    a comparison score (L3 against the reference, HandTune.compare)
      #    in the background; ranking the whole library that way would take
      #    about 12 s of this process's time (measured, 63 entries), so the
      #    list is ordered by words, not scores.
      # 3. **Tune**: the choices as one `tune` line (#tune_line), run as a
      #    console line (journaled, in the take: a replay sets up the same
      #    thing), which opens `design` with the reference for A/B.
      #
      # The steps are states with a transition table (TRANSITIONS; #event),
      # the screen (UI::Panes::Tuner) draws #state and the lists, and every
      # action that plays or changes the set is a console line the screen
      # runs (`audition ...`, `tune ...`); picking and going back change
      # nothing but the tuner.  One tuner per process (.current).
      class Wizard
        # The steps.
        STATES = %i[reference synth tuning].freeze

        # Events: +pick+ (the entry under the cursor), +back+ (a step back),
        # +restart+ (to step 1).
        EVENTS = %i[pick back restart].freeze

        # [state, event] => [next state, what happens].
        TRANSITIONS = {
          [:reference, :pick] => [:synth, 'the reference is picked: the synths for it are listed'],
          [:reference, :back] => [:reference, 'nothing before step 1 (the screen takes Esc to NAV)'],
          [:reference, :restart] => [:reference, 'the references listed again'],
          [:synth, :pick] => [:tuning, 'the synth is picked: its tune line runs (tune opens design with the reference)'],
          [:synth, :back] => [:reference, 'back to the references (the pick kept under the cursor)'],
          [:synth, :restart] => [:reference, 'back to the references'],
          [:tuning, :pick] => [:tuning, 'nothing to pick while tuning (the inspector turns the knobs)'],
          [:tuning, :back] => [:synth, 'back to the synths for the reference (the tune plays on until another runs)'],
          [:tuning, :restart] => [:reference, 'back to the references (the tune plays on)'],
        }.freeze

        # A reference to pick: +kind+ (:queue, :file, :sample: a Sample
        # read or played by a track), +name+, +path+ (the sound file),
        # +seconds+ (nil when the header doesn't say), +item+ (the
        # QueueItem for :queue), +about+ (one line: the queue item's title,
        # the track that plays it).
        Ref = Data.define(:kind, :name, :path, :seconds, :item, :about) do
          # The key its summary is kept under (the file, its size and time).
          def key
            st = File.stat(path)
            [path, st.size, st.mtime.to_r]
          rescue SystemCallError
            [path]
          end

          def inspect = "#<HandTune::Wizard::Ref #{kind} #{name}>"
        end

        # A queue item (a file of .queue_dir, "paste into bin/sound.rb"):
        # +path+, +number+, +title+, +status+ (:ok or :fails), +problem+
        # (the failure line), +track+, +ref+ (the reference's path as
        # written), +ref_path+ (found on disk, or nil), +play+ (the play:
        # clip's code), +note+ (its first note's number, or nil), +lines+
        # (the item's code: the tune line and the lines after it).
        QueueItem = Data.define(:path, :number, :title, :status, :problem, :track, :ref, :ref_path, :play, :note, :lines) do
          def inspect = "#<HandTune::Wizard::QueueItem #{number} #{title}>"
        end

        # A synth to pair with the reference: +kind+ (:queue, :fit, :init,
        # :blank, :library), +name+, +about+ (one line), +entry+ (a
        # Library::Entry, or nil), +path+ (a document, or nil), +ears+ (true
        # when it can only be tuned by ear: not a graph document, so no
        # retune or refine), +problem+ (why it can't be loaded, or nil).
        Synth = Data.define(:kind, :name, :about, :entry, :path, :ears, :problem) do
          def initialize(kind:, name:, about: nil, entry: nil, path: nil, ears: false, problem: nil) = super

          def inspect = "#<HandTune::Wizard::Synth #{kind} #{name}>"
        end

        # What the summary line says about a reference: +seconds+ (read),
        # +hz+ (the median pitch, nil when unpitched), +note+ (its nearest
        # MIDI note), +label+ ("C2 +32 cents" or "unpitched"), +shape+
        # (:percussive, :sustained, :swell, :hump), +attack+ and +decay+
        # (seconds to the peak, to -20 dB after it; nil when it doesn't
        # fall that far), +error+ (why it couldn't be read).
        Summary = Data.define(:seconds, :hz, :note, :label, :shape, :attack, :decay, :error) do
          def to_s
            return "can't read: #{error}" if error
            d = decay ? ", -20 dB at #{Analysis.seconds_label(decay)}" : ''
            "#{label}, #{shape}#{d}"
          end
        end

        # A synth's comparison with the reference: +total+ (L3, lower is
        # closer), +lufs+ (one note's loudness), +ms+ (what it took), +error+.
        Score = Data.define(:total, :lufs, :ms, :error)

        # Seconds of a reference the summary reads (pitch over the first
        # PITCH_SECONDS: YIN costs about 60 ms a second of sound).
        SUMMARY_SECONDS = 4.0
        PITCH_SECONDS = 1.0

        # The longest stretch a score renders and compares.
        SCORE_SECONDS = 2.0

        # Seconds the cursor stays on a synth before its score is worked
        # out (moving through the list doesn't start a render per row).
        SCORE_DWELL = 0.4

        # The most files a folder lists (the first, by path).
        MAX_FILES = 500

        # General MIDI drum notes by reference words (a kit plays a voice
        # only on its note).
        DRUM_NOTES = { kick: 36, bd: 36, rim: 37, snare: 38, sd: 38, clap: 39, hat: 42, hh: 42, closed: 42, open: 46, tom: 45, crash: 49,
                       ride: 51, cowbell: 56, perc: 39 }.freeze

        # Library words that fit a reference's role (Wizard#role).
        ROLE_WORDS = {
          kick: %i[kick drums kit boom perc sub tr909 tr808 dnb_boom membrane],
          drum: %i[drums kit perc membrane breaks tr909 tr808],
          bass: %i[bass sub reese acid roller house_bass funk_bass],
          pluck: %i[pluck keys piano bell marimba tine bar chime],
          lead: %i[lead vox flute brass sync digibrass],
          pad: %i[pad choir drone ambient strings organ],
        }.freeze

        class << self
          # The tuner open in this process, or nil.
          attr_reader :current

          # Opens the tuner (a new one, or the one open, its lists read
          # again) for +session+, listing +folder+ (default: the last one,
          # else .default_folder).  Returns it.
          def open(session: Session.current, folder: nil)
            w = @current if @current&.session.equal?(session)
            w ||= new(session: session)
            w.folder = folder if folder
            w.refresh
            @current&.close unless @current.equal?(w)
            @current = w
          end

          # Closes the tuner (its background thread ends).
          def close
            @current&.close
            @current = nil
          end

          # Where the tuner's files live: beside FitPatch.dir (the main
          # checkout's tmp/ when mb-sound runs from a checkout; specs give a
          # temporary directory through $MB_SOUND_FITS).
          def home = File.dirname(FitPatch.dir)

          # The hand-tune queue ($MB_SOUND_TUNE_QUEUE, else
          # .home/hand-tune-queue).
          def queue_dir
            env = ENV['MB_SOUND_TUNE_QUEUE']
            env.to_s.empty? ? File.join(home, 'hand-tune-queue') : File.expand_path(env)
          end

          # The folder listed when none was given or remembered
          # ($MB_SOUND_REFS, else .home/refs).
          def default_folder
            env = ENV['MB_SOUND_REFS']
            env.to_s.empty? ? File.join(home, 'refs') : File.expand_path(env)
          end

          # The file remembering the last folder.
          def state_path = File.join(home, 'tuner.json')

          # The folder listed last (or nil).
          def remembered_folder
            f = JSON.parse(File.read(state_path))['folder']
            f.is_a?(String) && !f.empty? ? f : nil
          rescue SystemCallError, JSON::ParserError
            nil
          end

          # Remembers +folder+ for the next tuner.
          def remember_folder(folder)
            FileUtils.mkdir_p(File.dirname(state_path))
            File.write(state_path, JSON.generate({ folder: folder }) + "\n")
          rescue SystemCallError
            nil
          end

          # The queue items of +dir+ (its *.rb files, by name).
          def queue_items(dir = queue_dir)
            return [] unless File.directory?(dir)
            Dir.glob(File.join(dir, '*.rb')).sort.filter_map { |p| queue_item(p) }
          end

          # The QueueItem of file +path+ (its `tune` call, walked with
          # Prism, never run), or nil when it has none.
          def queue_item(path)
            text = File.read(path)
            tree = Prism.parse(text)
            return nil unless tree.success?
            stmts = tree.value.statements.body
            i = stmts.index { |st| st.is_a?(Prism::CallNode) && st.receiver.nil? && st.name == :tune }
            return nil unless i
            call = stmts[i]
            args = call.arguments&.arguments || []
            track = args[0].is_a?(Prism::SymbolNode) ? args[0].unescaped.to_sym : nil
            return nil unless track
            kw = args.find { |a| a.is_a?(Prism::KeywordHashNode) }
            opts = (kw&.elements || []).select { |e| e.is_a?(Prism::AssocNode) && e.key.is_a?(Prism::SymbolNode) }.to_h { |e| [e.key.unescaped.to_sym, e.value] }
            ref = opts[:ref].is_a?(Prism::StringNode) ? opts[:ref].unescaped : nil
            ref_path = ref && find_near(ref, path)
            comments = tree.comments.map { |c| c.slice.sub(/\A#\s?/, '') }
            head = comments[0].to_s
            number = head[/queue (\d+)/, 1]&.to_i || File.basename(path)[/\A\d+/]&.to_i
            title = head.sub(/\A.*?queue \d+:\s*/, '').sub(/:\s*paste into.*\z/, '').strip
            title = File.basename(path, '.rb') if title.empty?
            second = comments[1].to_s
            status = second.start_with?('FAILS') ? :fails : :ok
            problem = status == :fails ? second.sub(/\AFAILS:\s*/, '') : nil
            # (the reference as found on disk, when the item names it from
            # another directory: "run from /app")
            lines = stmts[i..].map { |st| st.slice }
            if ref_path && ref_path != ref && !File.exist?(ref)
              loc = opts[:ref].location
              start = call.location.start_offset
              t = call.slice.b
              t[(loc.start_offset - start)...(loc.end_offset - start)] = ref_path.inspect.b
              lines[0] = t.force_encoding(text.encoding)
            end
            play = opts[:play]&.slice
            QueueItem.new(path: path, number: number, title: title, status: status, problem: problem, track: track, ref: ref, ref_path: ref_path,
                          play: play, note: play_note(opts[:play]), lines: lines.join("\n").freeze)
          rescue SystemCallError
            nil
          end

          # +rel+ (a path written in a queue item, relative to the
          # directory bin/sound.rb runs from) on disk: as given, else under
          # the item's folder's parents, else nil.
          def find_near(rel, item)
            return File.expand_path(rel) if File.exist?(rel)
            return nil if rel.start_with?('/')
            dir = File.dirname(File.expand_path(item))
            4.times do
              cand = File.join(dir, rel)
              return cand if File.exist?(cand)
              dir = File.dirname(dir)
            end
            nil
          end

          # The first note of a `seq(C2).n4.loop` clip's code (a Note
          # constant or a number), or nil.
          def play_note(node)
            n = node
            n = n.receiver while n.is_a?(Prism::CallNode) && n.name != :seq && n.receiver
            return nil unless n.is_a?(Prism::CallNode) && n.name == :seq
            a = n.arguments&.arguments&.first
            case a
            when Prism::IntegerNode then a.value
            when Prism::ConstantReadNode
              # (note constants come from const_missing: C2, Ds2, ...)
              c = a.name.to_s.match?(/\A[A-G][s#b]?-?\d\z/) ? MB::Sound.const_get(a.name) : nil
              c.is_a?(Note) ? c.number : nil
            end
          rescue NameError
            nil
          end

          # The summary of the sound file at +path+ (see Summary).
          def summarize(path)
            sig = Analysis::Signal.from(path, seconds: SUMMARY_SECONDS)
            env = Analysis::Envelope.new(sig)
            part = sig.seconds > PITCH_SECONDS ? sig.slice(0, PITCH_SECONDS) : sig
            pc = Analysis::PitchContour.new(part)
            hz = pc.median&.frequency
            note = hz ? (69 + 12 * Math.log2(hz / 440.0)).round : nil
            Summary.new(seconds: sig.seconds, hz: hz, note: note, label: hz ? pc.note_label : 'unpitched', shape: env.shape,
                        attack: env.attack.to_f, decay: env.decay[20]&.to_f, error: nil)
          rescue StandardError => e
            Summary.new(seconds: nil, hz: nil, note: nil, label: nil, shape: nil, attack: nil, decay: nil, error: "#{e.class}: #{e.message.lines.first&.strip}")
          end

          # The sound files of +folder+ (recursively, by path, at most
          # MAX_FILES) and the lengths of +paths+, from their headers
          # (Sample::LoopInfo, no audio decoded): { 'files' => [[path,
          # seconds], ...], 'seconds' => { path => seconds } } (plain data:
          # the worker process sends it as JSON).
          def scan(folder, paths = [])
            files = File.directory?(folder.to_s) ? Sample::LoopInfo.scan(folder).first(MAX_FILES).map { |e| [e.path, e.seconds] } : []
            secs = paths.to_h { |p| [p, (Sample::LoopInfo.read(p).seconds rescue nil)] }
            { 'files' => files, 'seconds' => secs }
          rescue StandardError
            { 'files' => [], 'seconds' => {} }
          end

          # Renders one note (+note+, a MIDI number) of a graph document
          # (+document+, a path) or a library instrument (+entry+, its head
          # path: "L.kit.tr909") offline (a private Session at +bpm+) and
          # compares it with the reference at +ref+ (HandTune.compare).
          # Returns a Score.
          def score_of(ref:, note:, document: nil, entry: nil, bpm: 120.0)
            t0 = MB::U.clock_now
            target = Analysis::Signal.from(ref, seconds: SCORE_SECONDS)
            seconds = target.seconds.clamp(0.1, SCORE_SECONDS)
            audio = Internal.with_private_rng(1) {
              if document
                HandTune.render(document, {}, note: note, seconds: seconds)
              else
                e = HandTune.entry_at(entry) or raise ArgumentError, "no library entry #{entry}"
                clip = MB::Sound.seq(note).len(Rational(1, 4)).vel(0.8)
                MB::Sound.bounce(seconds.seconds, bpm: bpm, channels: 1, gain: 1.0) { e.(clip) }.to_a.map { |c| c[0...(seconds * RATE).round] }
              end
            }
            c = HandTune.compare(target, audio[0], seconds: seconds)
            Score.new(total: c.total, lufs: Reference.lufs(audio, RATE), ms: ((MB::U.clock_now - t0) * 1000).round, error: nil)
          rescue StandardError => e
            Score.new(total: nil, lufs: nil, ms: ((MB::U.clock_now - t0) * 1000).round, error: "#{e.class}: #{e.message.lines.first&.strip}")
          end

          # The transition table as text (help, specs).
          def table
            TRANSITIONS.map { |(s, e), (to, what)| format('%-10s %-8s -> %-10s %s', s, e, to, what) }.join("\n")
          end
        end

        attr_reader :session, :state, :ref, :synths, :folder, :background, :line, :track

        def initialize(session:, folder: nil)
          @session = session
          @state = :reference
          @folder = folder || Wizard.remembered_folder || Wizard.default_folder
          @refs = [].freeze
          @queue = [].freeze
          @samples = [].freeze
          @scanning = nil
          @scan_gen = 0
          @ref = nil
          @synths = [].freeze
          @synth = nil
          @line = nil
          @track = nil
          @queue = [].freeze
          @background = Background.new(session)
          @mutex = Mutex.new
          @cursor = { reference: 0, synth: 0 }
          @query = { reference: '', synth: '' }
          @tuned = nil
        end

        # The cursor of each list ({ reference:, synth: }: indexes into
        # #shown) and its find words ({ reference:, synth: }).
        attr_reader :cursor, :query

        # The track the last tune line set up (HandTune.tune tells the
        # tuner: .tuned), or nil.
        attr_reader :tuned

        # Called by HandTune.tune when a tune line set up +track+.
        def note_tuned(track) = @tuned = track

        # The list of the step (+state+: :reference or :synth) narrowed by
        # its find words (every word in the entry's name or about).
        def shown(state = @state)
          list = state == :synth ? @synths : refs
          words = @query[state].to_s.downcase.split(/\s+/).reject(&:empty?)
          return list if words.empty?
          list.select { |x| t = "#{x.name} #{x.about} #{x.respond_to?(:kind) ? x.kind : ''}".downcase; words.all? { |w| t.include?(w) } }
        end

        # The entry under the cursor of +state+'s list, or nil.
        def under_cursor(state = @state)
          list = shown(state)
          return nil if list.empty?
          @cursor[state] = @cursor[state].to_i.clamp(0, list.length - 1)
          list[@cursor[state]]
        end

        # The synth picked (step 2), or nil.
        attr_reader :synth

        # Lists +dir+'s sound files next (remembered for the next tuner).
        def folder=(dir)
          @folder = File.expand_path(dir.to_s)
          Wizard.remember_folder(@folder)
          refresh if @state == :reference
        end

        # The step's number (1, 2, 3).
        def step = STATES.index(@state) + 1

        # Reads the references again (queue, folder, loaded samples).
        def refresh
          @queue = Wizard.queue_items.freeze
          @samples = loaded_samples.freeze
          paths = @queue.filter_map(&:ref_path) + @samples.map(&:first)
          @scan_gen = @scan_gen.to_i + 1
          key = [:scan, @folder, @scan_gen]
          if @background.offload?
            # (the headers read in the worker: about 3 ms a file on the
            # console's GVL otherwise; the folder's files show when read)
            @scanning = key
            @background.want(key, { 'do' => 'scan', 'path' => @folder, 'paths' => paths }) { Wizard.scan(@folder, paths) }
            build_refs(nil)
          else
            @scanning = nil
            build_refs(Wizard.scan(@folder, paths))
          end
          self
        end

        # The references (see #refresh; the folder's files once read).
        def refs
          if @scanning && (r = @background.get(@scanning))
            @scanning = nil
            build_refs(r.is_a?(Exception) ? nil : r)
          end
          @refs
        end

        # True while the folder is being read (in the worker).
        def scanning?
          refs
          !@scanning.nil?
        end

        # Sends +event+ (EVENTS) with its argument: :pick takes a Ref
        # (step 1) or a Synth (step 2).  Returns the next state.
        def event(event, arg = nil)
          to, = TRANSITIONS.fetch([@state, event]) { raise ArgumentError, "tuner: #{event.inspect} isn't an event (#{EVENTS.join(', ')})" }
          case [@state, event]
          in [:reference, :pick]
            raise ArgumentError, 'tuner: pick a reference (a Wizard::Ref)' unless arg.is_a?(Ref)
            @ref = arg
            @track = track_for(arg)
            @synths = synths_for(arg).freeze
            @synth = nil
            @cursor[:synth] = 0
            @query[:synth] = ''
          in [:synth, :pick]
            raise ArgumentError, 'tuner: pick a synth (a Wizard::Synth)' unless arg.is_a?(Synth)
            raise ArgumentError, "tuner: #{arg.name} can't load: #{arg.problem}" if arg.problem
            @synth = arg
            @line = tune_line(arg)
            @tuned = nil
          in [_, :restart]
            refresh
          else
            nil
          end
          @state = to
        end

        # Picks +x+ (a Ref, a Synth, or an index into the step's list).
        def pick(x)
          x = shown.fetch(x) if x.is_a?(Integer)
          event(:pick, x)
        end

        def back = event(:back)
        def restart = event(:restart)

        # The summary of +ref+ if worked out, else nil (+want+: work it out
        # in the background).
        def summary(ref, want: true)
          return nil unless ref
          key = [:summary, *ref.key]
          r = @background.get(key)
          return failed(Summary, r) if r.is_a?(Exception)
          r || (want ? @background.want(key, { 'do' => 'summary', 'path' => ref.path }) { Wizard.summarize(ref.path) } && nil : nil)
        end

        # The score of +synth+ against the picked reference if worked out,
        # else nil (+want+: work it out in the background).
        def score(synth, want: true)
          return nil unless synth && @ref && !synth.problem
          key = [:score, synth.kind, synth.name, *@ref.key]
          r = @background.get(key)
          return failed(Score, r) if r.is_a?(Exception)
          return r if r || !want
          @background.want(key, -> { score_job(synth) }) { Wizard.score_of(**score_job(synth).transform_keys(&:to_sym).except(:do)) } && nil
        end

        # The MIDI note the reference is played on: a queue item's, a drum
        # word's (DRUM_NOTES), the reference's pitch, else its role's.
        def note
          return nil unless @ref
          return @ref.item.note if @ref.item&.note
          s = summary(@ref, want: false)
          return s.note.clamp(12, 108) if s&.note
          drum_note || UI::PatchRender.role_of(@ref.name)[:note]
        end

        # The GM drum note the reference's words name (DRUM_NOTES), or nil.
        def drum_note = words(@ref&.name).lazy.map { |x| DRUM_NOTES[x] }.find(&:itself)

        # True when +synth+ is a kit (a kit entry, or a document whose voice
        # is a kit: it plays a voice only on that voice's note).
        def kit?(synth)
          return synth.entry.kind == :kit if synth&.entry
          text = synth&.path ? File.read(synth.path) : (synth&.kind == :queue ? @ref&.item&.lines.to_s : '')
          text.match?(/\b(kit|drum_kit|tr909|tr808)\s*[({]/)
        rescue SystemCallError
          false
        end

        # The note +synth+ plays the reference's part on: a kit's voice note
        # for kits (DRUM_NOTES by the reference's words, else the kick's or
        # the snare's by its role), else #note.
        def note_for(synth)
          return @ref.item.note if synth&.kind == :queue && @ref&.item&.note
          return note unless kit?(synth)
          drum_note || (role == :drum ? DRUM_NOTES[:snare] : DRUM_NOTES[:kick])
        end

        # The play: clip's code for the picked reference (a queue item's;
        # else its note (+synth+'s: Wizard#note_for), as long as the
        # reference at the session's tempo).
        def play_code(synth = nil)
          return @ref.item.play if @ref&.item&.play && (synth.nil? || synth.kind == :queue || !kit?(synth))
          n = Note.new(note_for(synth).to_i).name
          secs = (@ref&.seconds || summary(@ref, want: false)&.seconds || 0.5).to_f
          beat = 60.0 / @session.transport.bpm.to_f
          len = [[1, '.n4'], [2, '.n2'], [4, '.n1'], [8, '.len(2)']].find { |b, _| b * beat >= secs * 1.05 }&.last || '.len(4)'
          "seq(#{n})#{len}.loop"
        end

        # The reference's role (:kick, :drum, :bass, :pluck, :lead, :pad):
        # its words, else its summary (percussive and low: kick).
        def role
          return nil unless @ref
          w = words(@ref.name)
          r = ROLE_WORDS.keys.find { |k| w.include?(k) || (k == :drum && w.intersect?(%i[snare clap hat perc rim tom drums])) }
          return r if r
          s = summary(@ref, want: false)
          return nil unless s && !s.error
          if s.shape == :percussive
            s.hz.nil? || s.hz < 120 ? (s.hz ? :kick : :drum) : :pluck
          else
            s.hz && s.hz < 150 ? :bass : s.shape == :sustained ? :lead : :pad
          end
        end

        # The `tune` line for +synth+ and the picked reference (what the
        # screen runs, and the take keeps).
        def tune_line(synth)
          raise ArgumentError, 'tuner: pick a reference first' unless @ref
          return @ref.item.lines if synth.kind == :queue
          t = @track.inspect
          tail = ", ref: #{@ref.path.inspect}, play: #{play_code(synth)}"
          case synth.kind
          when :fit
            text = File.read(synth.path)
            name = synth.name.to_sym
            version = FitPatch.version_path(text, name)
            "tune #{t}, #{version.inspect}#{tail}, as: #{name.inspect}"
          when :init, :library
            path = synth.entry.head_path
            synth.ears ? "tune #{t}, #{path}#{tail}" : "tune #{t}, #{path}#{tail}, as: :#{@track}_#{synth.entry.name}"
          when :blank
            code, params = blank_voice
            "tune #{t}, #{code.inspect}#{tail}, as: :#{@track}_blank,\n  " + params.map { |k, (r, v)| "#{k}: (#{RubyValue.to_ruby(r.begin)}..#{RubyValue.to_ruby(r.end)}).at(#{RubyValue.to_ruby(v)})" }.join(', ')
          else
            raise ArgumentError, "tuner: no tune line for #{synth.kind}"
          end
        end

        # The `audition` line for +what+ (a Ref: the sound, loudness-matched
        # to the synth under +match+ when its score knows its loudness; a
        # Synth: on the reference's note), or nil.
        def audition_line(what, match: nil)
          case what
          when Ref
            l = match && score(match, want: false)&.lufs
            l && l.finite? ? "audition #{what.path.inspect}, lufs: #{l.round(1)}" : "audition #{what.path.inspect}"
          when Synth
            return nil if what.problem
            n = Note.new(note_for(what).to_i).name
            case what.kind
            when :init, :library then "audition #{what.entry.head_path}, note: #{n}"
            when :fit then "audition #{what.path.inspect}, note: #{n}"
            when :queue, :blank
              # (the fit's document as tune would write it: its version)
              v = version_of(what) or return nil
              "audition #{v.inspect}, note: #{n}"
            end
          end
        end

        # The document of +synth+ (its version, written if new: the text
        # the tune line makes, through Take::Reader), or nil for synths
        # that aren't documents.
        def version_of(synth)
          return synth.path if synth.kind == :fit
          return synth.entry.location if synth.entry && !synth.ears && synth.kind != :blank && synth.kind != :queue
          return nil if synth.ears
          take = "MB::Sound::Take::Replay.new(bpm: 120) do |r|\n  r.line 0r, [], #{tune_line(synth).inspect}\nend\n"
          v = Take.read(take).versions[@track]&.first
          v&.path
        rescue StandardError
          nil
        end

        # The blank voice (a sine through an ADSR, its times from the
        # reference's envelope): [code, { param => [range, value] }].
        def blank_voice
          s = summary(@ref, want: false)
          perc = s.nil? || s.shape.nil? || s.shape == :percussive
          attack = (s&.attack || 0.003).clamp(0.0011, 1.0).round(4)
          decay = (s&.decay || 0.3).clamp(0.02, 4.0).round(3)
          sustain = perc ? 0.0 : 0.7
          release = perc ? 0.05 : 0.25
          vals = [attack, decay, sustain, release]
          # (four different numbers: fit_patch names a positional literal by
          # its value)
          (1...vals.length).each { |i| vals[i] = (vals[i] + 0.001).round(4) while vals[0...i].include?(vals[i]) }
          attack, decay, sustain, release = vals
          params = { attack: [0.0005..2.0, attack], decay: [0.005..8.0, decay], sustain: [0.0..1.0, sustain], release: [0.005..8.0, release] }
          code = "synth(midi) { |v| v.hz.sine * v.amp_env(#{params.values.map { |_, x| RubyValue.to_ruby(x.to_f) }.join(', ')}) }"
          [code, params]
        end

        # Stops the background work.
        def close = @background.close

        def to_s
          case @state
          when :reference
            lines = refs.first(20).each_with_index.map { |r, i| format('%3d  %-40s %s', i, r.name[0, 40], r.seconds ? "#{r.seconds.round(2)} s" : '') }
            more = refs.length > 20 ? "\n  ... #{refs.length - 20} more (tuner.refs)" : ''
            "tuner step 1, a reference (#{refs.length}#{scanning? ? ', reading the folder' : ''}: the queue, #{@folder}, loaded samples): tuner.pick(i)\n#{lines.join("\n")}#{more}"
          when :synth
            lines = @synths.first(20).each_with_index.map { |x, i| format('%3d  %-8s %-28s %s', i, x.kind, x.name.to_s[0, 28], x.problem ? "can't: #{x.problem[0, 50]}" : x.about.to_s[0, 60]) }
            "tuner step 2, a synth for #{@ref.name} (track #{@track.inspect}): tuner.pick(i), tuner.back\n#{lines.join("\n")}"
          else
            "tuner step 3: #{@line.lines.first.strip}#{@line.include?("\n") ? ' ...' : ''} (tuner.back: the synths)"
          end
        end

        def inspect = "#<HandTune::Wizard step #{step} #{@state}#{@ref ? " #{@ref.name}" : ''}>"

        private

        # #refs from the queue, the samples, and +scan+ (Wizard.scan's
        # result, or nil before it).
        def build_refs(scan)
          secs = scan ? scan['seconds'] || scan[:seconds] || {} : {}
          files = scan ? scan['files'] || scan[:files] || [] : []
          list = []
          seen = {}
          @queue.each do |q|
            next unless q.ref_path
            seen[q.ref_path] = true
            list << Ref.new(kind: :queue, name: "#{q.number} #{q.title}", path: q.ref_path, seconds: secs[q.ref_path], item: q,
                            about: q.status == :fails ? "queue #{q.number} (its fit fails: #{q.problem.to_s[0, 60]})" : "queue #{q.number}: #{q.title}")
          end
          files.each do |path, sec|
            next if seen[path]
            seen[path] = true
            list << Ref.new(kind: :file, name: path.delete_prefix("#{@folder}/"), path: path, seconds: sec, item: nil, about: "in #{@folder}")
          end
          @samples.each do |path, about|
            next if seen[path]
            seen[path] = true
            list << Ref.new(kind: :sample, name: File.basename(path), path: path, seconds: secs[path], item: nil, about: about)
          end
          @refs = list.freeze
        end

        # [[path, about], ...] of Samples read from files in this process
        # and of the samples tracks' samplers play (the A/B references'
        # tracks left out).
        def loaded_samples
          out = Sample.loaded.filter_map { |s| s.file && [s.file, 'read in this session'] }
          refs = Reference.pairs(@session).values.map(&:ref)
          graphs = @session.respond_to?(:ui_graphs) ? @session.ui_graphs : {}
          graphs.each do |name, input|
            next if refs.include?(name) || name.to_s.start_with?('audition')
            UI::Inspect.roots(input).each do |root|
              UI::Inspect.nodes_of(root).each do |n|
                next unless n.is_a?(GraphNode::SamplerVoice)
                n.instrument.samples.each { |s| out << [s.file, "played by track #{name.inspect}"] if s.file }
              end
            end
          end
          out.uniq(&:first)
        rescue StandardError
          out || []
        end

        # Words of +text+ (a file or entry name) as Symbols.
        def words(text)
          File.basename(text.to_s).sub(/\.\w+\z/, '').downcase.split(/[^a-z0-9]+/).reject(&:empty?).map(&:to_sym)
        end

        # The track a reference is tuned on: a queue item's, else the
        # reference's first word that names one (`03_kick.wav`: :kick).
        def track_for(ref)
          return ref.item.track if ref.item
          w = words(ref.name).map(&:to_s).find { |x| x.match?(/\A[a-z][a-z0-9_]*\z/) } || 'ref'
          base = w.to_sym
          return base unless taken?(base)
          :"#{base}_tune"
        end

        # True when +name+ is a track of the set that isn't one the tuner
        # set up (a pair's patch) or that tune would redefine harmlessly.
        def taken?(name)
          tr = @session.arrangement.tracks[name] or return false
          !Reference.pairs(@session).key?(name) && !!tr
        end

        # The synths for +ref+: its queue fit, the track's fit documents
        # (newest version first), the init voice, a blank voice, other
        # fits, then the library's instruments and kits (those whose words
        # fit the reference's role first).
        def synths_for(ref)
          out = []
          if (q = ref.item)
            out << Synth.new(kind: :queue, name: :"#{q.track}_fit", about: "the queue's fit: #{q.title}",
                             problem: q.status == :fails ? q.problem : nil)
          end
          mine, others = fit_documents.partition { |name, _| name.to_s.start_with?("#{@track}_") || name == @track }
          mine.each { |name, path, about| out << Synth.new(kind: :fit, name: name, about: about, path: path) }
          init = Library.index.entries(kind: :instrument).find { |e| e.name == :init }
          out << Synth.new(kind: :init, name: :init, about: 'the init voice: two morphing oscillators, lp4, ADSR, every number a knob', entry: init) if init
          out << Synth.new(kind: :blank, name: :blank, about: 'a sine through an ADSR set from the reference\'s envelope: build it up with retune')
          others.each { |name, path, about| out << Synth.new(kind: :fit, name: name, about: about, path: path) }
          out.concat(library_synths)
          out
        end

        # [[name, path, about], ...] of the fit documents in FitPatch.dir
        # (newest first) and the last versions of the track's fits.
        def fit_documents
          dir = FitPatch.dir
          return [] unless File.directory?(dir)
          docs = Dir.glob(File.join(dir, "*#{GraphIO::EXTENSION}")).sort_by { |p| -File.mtime(p).to_f }
          out = docs.map { |p|
            name = File.basename(p, GraphIO::EXTENSION).to_sym
            [name, p, "fit document #{File.basename(p)} (#{File.mtime(p).strftime('%m-%d %H:%M')})"]
          }
          versions = Dir.glob(File.join(dir, 'versions', "#{@track}_*#{GraphIO::EXTENSION}")).sort_by { |p| -File.mtime(p).to_f }.first(5)
          versions.each do |p|
            base = File.basename(p, GraphIO::EXTENSION)
            name = base.sub(/-[0-9a-f]{12}\z/, '').to_sym
            next if out.any? { |_, q, _| q && File.file?(q) && File.read(q) == File.read(p) }
            out << [name, p, "a version of #{name} (#{base[/[0-9a-f]{12}\z/]}, #{File.mtime(p).strftime('%m-%d %H:%M')})"]
          end
          out
        rescue SystemCallError
          []
        end

        # The library's instruments and kits as Synths, those whose name
        # or tags have a word of the reference's role first (then by name).
        def library_synths
          r = role
          want = r ? ROLE_WORDS[r] : []
          entries = Library.index.entries(kind: :instrument).reject { |e| e.name == :init } + Library.index.entries(kind: :kit)
          ranked = entries.each_with_index.sort_by { |e, i|
            hit = ([e.name, *e.name_words, *e.tags, e.family] & want).empty? ? 1 : 0
            kit_first = r == :kick || r == :drum ? (e.kind == :kit ? 0 : 1) : 0
            [hit, kit_first, i]
          }.map(&:first)
          ranked.map { |e|
            doc = e.settings.is_a?(Hash) && e.settings[:document]
            Synth.new(kind: :library, name: e.name, entry: e, ears: !doc,
                      about: [e.kind == :kit ? 'kit' : (e.family == :preset ? nil : e.family.to_s), e.about.to_s[0, 70]].compact.join(': ') +
                             (doc ? '' : ' (by ear: not a graph document, no retune or refine)'))
          }
        end

        # A +klass+ (Summary, Score) saying background job +e+ failed.
        def failed(klass, e)
          msg = "#{e.class}: #{e.message.lines.first&.strip}"
          klass == Summary ? Summary.new(seconds: nil, hz: nil, note: nil, label: nil, shape: nil, attack: nil, decay: nil, error: msg) : Score.new(total: nil, lufs: nil, ms: nil, error: msg)
        end

        # What a score of +synth+ needs, as plain data (Wizard.score_of's
        # keywords; the worker process gets it as JSON): the reference's
        # path, the synth's document (its version) or library head path,
        # the note, the tempo.
        def score_job(synth)
          { 'do' => 'score', 'ref' => @ref.path, 'document' => version_of(synth), 'entry' => (synth.entry&.head_path rescue nil),
            'note' => note_for(synth).to_i, 'bpm' => @session.transport.bpm.to_f }
        end
      end

      # The tuner's background work (the folder's headers, summaries, and
      # scores), a folder's scan first, then the most recently wanted job,
      # one at a time, from one thread at a low priority.  Each job runs in
      # the tuner's worker process (Remote, started through the process
      # starter: Starter) when it can start, so the console's GVL stays the
      # render thread's: measured on the Mac container (800-frame buffers,
      # a reese riff and a beat playing), 50 summaries run in this process
      # made the render thread wait p99 15 ms, max 62 ms (32 GCs, 0.6 s),
      # 10 scores p99 10.8 ms, max 41 ms, the folder's headers 164 ms on
      # the console's thread (max 10.5 ms); in the worker, the waits stay
      # at the idle numbers (design/notes/hand_tune.md).  Without a worker
      # (no starter while a render thread runs, $MB_SOUND_TUNER_WORKER=0)
      # jobs wait until nothing renders, then run here; .inline runs none
      # until #drain (specs).  The thread ends after IDLE seconds without
      # work.
      class Wizard::Background
        IDLE = 10.0

        class << self
          # True to run no thread: jobs wait for #drain (specs, captures).
          attr_accessor :inline
        end

        def initialize(session)
          @session = session
          @mutex = Mutex.new
          @cond = ConditionVariable.new
          @jobs = {}
          @results = {}
          @thread = nil
          @closed = false
          @busy = nil
          @remote = nil
          @remote_tried = false
          @remote_failed = false
        end

        # The result kept under +key+, or nil.
        def get(key) = @mutex.synchronize { @results[key] }

        # Queues a job for +key+ unless its result is kept or it is queued
        # (then it moves to the front): +remote+ (a Hash of plain data, or a
        # Proc making one, for the worker process: Remote) and +block+ (the
        # same work here).  Returns true.
        def want(key, remote = nil, &block)
          @mutex.synchronize {
            return true if @results.key?(key) || @busy == key || @closed
            @jobs.delete(key)
            @jobs[key] = [remote, block]
            start unless @thread&.alive? || Wizard::Background.inline
            @cond.signal
          }
          true
        end

        # Keys queued (newest last) and the one running.
        def pending = @mutex.synchronize { [@jobs.keys, @busy] }

        # True while a job runs or waits.
        def busy? = @mutex.synchronize { !@busy.nil? || !@jobs.empty? }

        # Where jobs run: :worker (a process), :here, or nil (not decided
        # until the first job).
        def where
          return nil unless @remote_tried
          @remote&.alive? ? :worker : @remote_failed ? :here : nil
        end

        # True when jobs go to the worker process (one can start; not
        # .inline).
        def offload? = !Wizard::Background.inline && !@remote_failed && (!@remote.nil? || Wizard::Remote.usable?)

        # Drops queued jobs (results stay).
        def clear = @mutex.synchronize { @jobs.clear }

        # Runs every queued job on the calling thread, here (specs).
        def drain
          loop do
            key, (_, job) = @mutex.synchronize { @jobs.shift }
            break unless key
            r = job.call
            @mutex.synchronize { @results[key] = r }
          end
        end

        def close
          t = @mutex.synchronize {
            @closed = true
            @jobs.clear
            @cond.signal
            @thread
          }
          t&.join(2)
          @remote&.close
          @remote = nil
        end

        private

        def start
          @thread = Thread.new { run }
          @thread.name = 'mb-sound tuner'
          @thread.priority = -3
          @thread.report_on_exception = false
        end

        def run
          loop do
            key, (remote, job) = @mutex.synchronize {
              deadline = MB::U.clock_now + IDLE
              while @jobs.empty? && !@closed
                left = deadline - MB::U.clock_now
                if left <= 0
                  @thread = nil
                  return
                end
                @cond.wait(@mutex, left)
              end
              return(@thread = nil) if @closed
              # (a folder's scan first: the list waits on it)
              k = @jobs.keys.find { |x| x[0] == :scan } || @jobs.keys.last
              @busy = k
              [k, @jobs.delete(k)]
            }
            r = begin
              (w = remote && worker) ? w.call(remote.respond_to?(:call) ? remote.call : remote) : (wait_for_quiet; job.call)
            rescue StandardError => e
              e
            end
            @mutex.synchronize {
              @results[key] = r
              @busy = nil
            }
            UI.tiles&.invalidate rescue nil
          end
        end

        # The worker process (started on the first job when it can be:
        # Remote.usable?), or nil.
        def worker
          unless @remote_tried
            @remote_tried = true
            @remote = Wizard::Remote.new if Wizard::Remote.usable?
            @remote_failed = @remote.nil?
          end
          return @remote if @remote&.alive?
          @remote_failed = true
          nil
        rescue StandardError => e
          warn "the tuner's worker didn't start (#{e.message}); its summaries and scores run in this process"
          @remote_failed = true
          @remote = nil
        end

        # Without the worker, waits until no render thread runs (measured:
        # jobs here while a Session plays made the render thread wait up to
        # 62 ms; see the class description), then for nothing more.
        def wait_for_quiet
          sleep 0.25 while Worker.live_render? && !@closed
        end
      end

      # The tuner's worker process (a Worker running .serve): summaries
      # and scores off the console's GVL.  Requests and answers are JSON
      # lines: {"id": n, "do": "summary", "path": ...} or {"id": n, "do":
      # "score", "ref":, "document":, "entry":, "note":, "bpm":} ->
      # {"id": n, "summary": {...}} / {"id": n, "score": {...}}.
      class Wizard::Remote
        # True when a worker can start now: through the process starter,
        # or while nothing renders (else a start would fork with the GVL
        # held); never with $MB_SOUND_TUNER_WORKER=0.
        def self.usable?
          return false if ENV['MB_SOUND_TUNER_WORKER'] == '0'
          !Starter.current.nil? || !Worker.live_render?
        end

        # The worker process's loop.
        def self.serve(input = $stdin, output = $stdout)
          Process.setpriority(Process::PRIO_PROCESS, 0, 10) rescue nil
          output.sync = true
          output.puts(JSON.generate(ready: true))
          while (line = input.gets)
            msg = JSON.parse(line)
            break if msg['quit']
            out =
              case msg['do']
              when 'summary' then { summary: Wizard.summarize(msg['path']).to_h }
              when 'scan' then { scan: Wizard.scan(msg['path'], msg['paths'] || []) }
              when 'score'
                { score: Wizard.score_of(ref: msg['ref'], note: msg['note'].to_i, document: msg['document'], entry: msg['entry'], bpm: msg['bpm'].to_f).to_h }
              else { error: "unknown request #{msg['do'].inspect}" }
              end
            output.puts(JSON.generate(out.merge(id: msg['id'])))
          end
        rescue StandardError => e
          output.puts(JSON.generate(error: "#{e.class}: #{e.message}"))
        end

        def initialize
          @worker = Worker.new(serve: 'MB::Sound::HandTune::Wizard::Remote.serve')
          @id = 0
          @ready = false
        end

        def alive? = @worker.alive?

        # Runs request +h+ in the worker and returns its Summary or Score
        # (waiting off the GVL; a Score or Summary with the error when the
        # worker fails).
        def call(h)
          @ready ||= @worker.wait_ready
          id = (@id += 1)
          @worker.send_message(h.merge('id' => id))
          loop do
            msg = @worker.next_message(60) or raise "the tuner's worker took over 60 s"
            raise msg['error'].to_s if msg['error'] && (msg['exited'] || msg['id'].nil? || msg['id'] == id)
            next unless msg['id'] == id
            return Wizard::Summary.new(**self.class.symbols(msg['summary'])) if msg['summary']
            return Wizard::Score.new(**self.class.symbols(msg['score'])) if msg['score']
            return msg['scan'] if msg['scan']
          end
        end

        def close = @worker.close

        # +h+ (from JSON) with Symbol keys, and its shape a Symbol.
        def self.symbols(h)
          h = h.transform_keys(&:to_sym)
          h[:shape] = h[:shape].to_sym if h[:shape].is_a?(String)
          h
        end
      end

      # The console's tuner (MB::Sound extends it; hand-tune-3).
      module TunerMethods
        # The tuner: pick a reference, then the synth to tune against it,
        # then tune (see HandTune::Wizard).  Shows `ui :tuner` (NAV h on
        # the tiles) and returns the tuner (it prints its step and list;
        # `tuner.pick(3)`, `tuner.back` from Ruby).  +folder+ lists another
        # folder's sound files (remembered); `tuner off` closes it and puts
        # back the screen before.
        #
        #     tuner
        #     tuner 'tmp/refs'
        #     tuner off
        def tuner(folder = nil)
          return UI::TunerScreen.close if folder == :off || folder == false
          raise ArgumentError, "tuner takes a folder of sound files (got #{folder.inspect})" unless folder.nil? || folder.is_a?(String) || folder.is_a?(Pathname)
          raise ArgumentError, "tuner: no folder #{folder}" if folder && !File.directory?(folder.to_s)
          UI::TunerScreen.open(folder: folder&.to_s)
        end
      end
    end

    extend HandTune::TunerMethods
  end
end
