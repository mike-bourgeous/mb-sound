require 'monitor'

module MB
  module Sound
    # Genre templates: what a genre is (tempo, meter, phrase lengths, a song
    # form, drum grids and fills, track roles with suggested patches and
    # levels, scenes, knobs, mix targets, and tips), as the library's own
    # objects, ready to compose, print, and play.  See design/notes/genres.md.
    #
    #     t = genre(:dnb)                      # a Genre::Template
    #     t.form; t.kits[:drop]; t.scene(:drop); t.tips
    #     genre(:dnb, tempo: 170)              # override any field (Data#with)
    #     genre(:dnb) { role :bass, :jungle_reese, level: -2.db }   # or with the builder
    #     genre(:dnb).short.play               # set it up and play its form, about a minute long
    #     puts genre(:dnb).to_ruby             # Genre.template :dnb, ... do ... end
    #
    # Templates are registered with Genre.define and built on first use (see
    # lib/mb/sound/genre/ for the shipped ones).
    module Genre
      # A track role: the +patch+ that plays it (a preset name, else an
      # MB::Sound method taking a MIDI source, like :tr808), its +level+ (a
      # gain, written in dB; nil for none), preset +params+ (numbers, or
      # Symbols naming template knobs: the preset's param reads the knob), a knob
      # name whose value drives a lowpass on the output (+filter+), a ducking
      # +amount+ keyed by the template's pulse kick (+duck+), the track's
      # launch quantization +q+ and launch +fade+, and a few words +about+ it.
      Role = Data.define(:patch, :level, :params, :filter, :duck, :q, :fade, :about) do
        def initialize(patch:, level: nil, params: {}, filter: nil, duck: nil, q: nil, fade: nil, about: nil)
          raise ArgumentError, "A role's patch is a preset or method name (got #{patch.inspect})" unless patch.is_a?(Symbol)
          unless params.is_a?(Hash) && params.values.all? { |v| v.is_a?(Numeric) || v.is_a?(Symbol) }
            raise ArgumentError, "params: must be a Hash of numbers or knob names (got #{params.inspect})"
          end
          raise ArgumentError, "filter: names a knob (got #{filter.inspect})" unless filter.nil? || filter.is_a?(Symbol)
          super(patch: patch, level: level, params: params.dup.freeze, filter: filter, duck: duck, q: q, fade: fade, about: about&.dup&.freeze)
        end

        # The keyword options that rebuild this role (for Template#to_ruby).
        def options
          to_h.except(:patch).reject { |k, v| v.nil? || (k == :params && v.empty?) }
        end
      end

      # Mix targets: integrated +loudness+ in LUFS (a number or a Range),
      # +true_peak+ ceiling (dBTP, as Decibels), the frequency below which
      # the low end stays mono (+mono_below+, Hz), the +master+ chain as an
      # Array of steps [preset or GraphNode method name, args, params]
      # applied in order (empty for none), and the master bus +gain+ (nil to
      # keep the Session's).
      Mix = Data.define(:loudness, :true_peak, :mono_below, :master, :gain) do
        def initialize(loudness: nil, true_peak: nil, mono_below: nil, master: [], gain: nil)
          super(loudness: loudness, true_peak: true_peak, mono_below: mono_below, master: master.dup.freeze, gain: gain)
        end

        # A one-line summary (e.g. "-8..-6 LUFS, -0.5 dBTP, mono below 120 Hz,
        # master dnb_master").
        def summary
          parts = []
          parts << "#{loudness} LUFS" if loudness
          parts << "#{true_peak.to_db.round(2)} dBTP" if true_peak
          parts << "mono below #{mono_below} Hz" if mono_below
          parts << "master #{master.map(&:first).join(' -> ')}" unless master.empty?
          parts << "master gain #{gain.to_db.round(2)} dB" if gain
          parts.join(', ')
        end

        # Compares a Loudness::Result (or anything with #integrated and
        # #true_peak in dB) with the targets, and with +data+ (the audio, an
        # Array of channels) the side below 120 Hz (or #mono_below) against
        # the mid.  Returns lines of text.
        def report(result, data = nil)
          lines = []
          lufs = result.integrated
          if loudness
            lo, hi = loudness.is_a?(Range) ? [loudness.begin, loudness.end] : [loudness, loudness]
            verdict = lufs < lo - 0.5 ? 'quiet' : lufs > hi + 0.5 ? 'loud' : 'on target'
            lines << format('loudness %.1f LUFS (target %s: %s)', lufs, loudness, verdict)
          else
            lines << format('loudness %.1f LUFS', lufs)
          end
          tp = result.true_peak
          if true_peak
            ceiling = Decibels.db_of(true_peak, 'true_peak')
            lines << format('true peak %.2f dBTP (ceiling %.1f: %s)', tp, ceiling, tp > ceiling + 0.1 ? 'over' : 'ok')
          else
            lines << format('true peak %.2f dBTP', tp)
          end
          if data && (side = Genre.low_side_db(data, frequency: mono_below || 120))
            hz = mono_below || 120
            text = side.finite? ? format('%.1f dB', side) : '-inf dB'
            verdict = mono_below ? (side < -30 ? ': mono' : ': not mono') : ''
            lines << "side below #{hz} Hz #{text} re mid (#{mono_below ? "mono_below #{hz}" : 'no mono_below'}#{verdict})"
          end
          lines
        end
      end

      # The ghost kick that keys roles' duck: (Template#pulse_kick): a short
      # 808 kick ("Tunnel Vision"'s; the default 2.4 s decay would hold the
      # ducking down between kicks).
      PULSE_KICK = { tune: 54, decay: 0.38, tone: 0.62, sigh: 0.9 }.freeze

      # Scene keys that are scene options rather than tracks or knobs.
      SCENE_OPTIONS = [:q, :fade, :others].freeze

      # Scene values that a track may take besides kit and clip names.
      SCENE_LITERALS = [:on, :off, :cut, :keep, nil].freeze

      @definitions = {}
      @built = {}
      @lock = Monitor.new # reentrant: a template built on first use may start `like` another

      class << self
        # Registers a template +name+ built from the +block+ (see Builder) on
        # first use.  Redefining a name replaces it.  Returns +name+.
        def define(name, title = nil, &block)
          raise ArgumentError, "Genre names are Symbols (got #{name.inspect})" unless name.is_a?(Symbol)
          raise ArgumentError, 'Genre.define needs a block' unless block
          @lock.synchronize do
            @definitions[name] = [title, block]
            @built.delete(name)
          end
          name
        end

        # The registered template +name+ (built on first use).
        def [](name)
          name = name.to_sym if name.is_a?(String)
          @lock.synchronize do
            return @built[name] if @built.key?(name)
            title, block = @definitions[name]
            unless block
              raise ArgumentError, "No genre #{name.inspect} (genres: #{@definitions.keys.map(&:inspect).join(', ')})#{Form.suggest(name, @definitions.keys)}"
            end
            @built[name] = template(name, title, &block)
          end
        end

        # The registered genre names.
        def names
          @lock.synchronize { @definitions.keys }
        end

        # Builds a template named +name+ from the +block+ (see Builder),
        # starting from +base+ (a Template) if given.  Not registered.
        def template(name, title = nil, base: nil, &block)
          Builder.build(name, title, base: base, &block)
        end

        # Ruby code for a template value (Decibels as -6.db, Ranges,
        # Rationals as 3/4r, Durations, Hashes with Symbol keys).
        def ruby(value)
          case value
          when Decibels
            value.inspect
          when Range
            "#{ruby(value.begin)}#{value.exclude_end? ? '...' : '..'}#{ruby(value.end)}"
          when Rational
            value.denominator == 1 ? value.numerator.to_s : "#{value.numerator}/#{value.denominator}r"
          when Hash
            return '{}' if value.empty?
            "{ #{kwargs(value)} }"
          when Array
            "[#{value.map { |v| ruby(v) }.join(', ')}]"
          when Sequence::Duration
            Form.ruby_value(value)
          else
            value.inspect
          end
        end

        # +hash+ as keyword arguments (`a: 1, b: :x`).
        def kwargs(hash)
          hash.map { |k, v| "#{k}: #{ruby(v)}" }.join(', ')
        end

        # The node a role's +patch+ makes from +source+ (a clip, kit, or
        # other MIDI source): a preset's graph (with +params+), else the
        # Genre::Patches or MB::Sound method of that name called with the
        # source.
        def build_patch(patch, source, params = {})
          if GraphIO.find_preset(patch)
            MB::Sound.preset(patch, midi: source, **params) # (knob names bind there; see GraphIO's Loader)
          elsif Patches.respond_to?(patch)
            Patches.public_send(patch, source, **knob_params(params))
          elsif MB::Sound.respond_to?(patch)
            MB::Sound.public_send(patch, source, **knob_params(params))
          else
            names = GraphIO.presets.values.flatten
            raise ArgumentError, "No preset or method #{patch.inspect} for a genre role#{Form.suggest(patch, names)}"
          end
        end

        # +params+ with Symbol values replaced by those knobs' nodes (for
        # methods; presets take knob names themselves).
        def knob_params(params)
          params.transform_values { |v| v.is_a?(Symbol) ? MB::Sound.knob(v) : v }
        end

        # Side (L - R) power below +frequency+ Hz relative to mid (L + R)
        # power there, in dB, for a stereo pair of Numo arrays (-Float::INFINITY
        # for identical channels; nil for one channel or a silent low end).
        def low_side_db(data, frequency: 120, sample_rate: 48000)
          return nil if data.length < 2
          l, r = Numo::DFloat.cast(data[0]), Numo::DFloat.cast(data[1])
          bins = (frequency.to_f * l.length / sample_rate).floor
          return nil if bins < 1
          power = ->(x) { (Numo::Pocketfft.rfft(x.dup)[1..bins].abs**2).sum }
          mid = power.((l + r) * 0.5)
          side = power.((l - r) * 0.5)
          return nil if mid <= 0
          side <= 0 ? -Float::INFINITY : 10 * Math.log10(side / mid)
        end

        # The master chain for +mix+ (a node or bundle) from Mix#master steps
        # [name, args, params]: each a preset with an :input, else a
        # GraphNode method of that name.
        def master_chain(mix, steps)
          steps.reduce(mix) { |m, (name, args, params)|
            if GraphIO.find_preset(name)
              MB::Sound.preset(name, input: m, **params)
            else
              m.public_send(name, *args, **knob_params(params))
            end
          }
        end

        # A copy of +form+ with every plain-number section, fill, and phrase
        # fill length divided by +divisor+ (rounded, at least 1 bar; phrase
        # fills at least every 2 bars).
        def scale_form(form, divisor)
          return form if divisor == 1
          shrink = ->(len, min = 1) { len.is_a?(Numeric) ? [(len.to_r / divisor).round, min].max : len }
          sections = form.sections.transform_values { |s|
            length = shrink.(s.length)
            fill = s.fill && s.fill.with(length: [shrink.(s.fill.length), length].then { |f, l| f.is_a?(Numeric) && l.is_a?(Numeric) ? [f, l].min : f })
            s.with(length: length, fill: fill)
          }
          phrase = form.phrase_fills.map { |f| f.with(every: shrink.(f.every, 2), length: shrink.(f.length)) }
          Form.new(sections: sections, order: form.order, phrase_fills: phrase)
        end
      end

      # A genre template (see Genre and design/notes/genres.md): a frozen
      # value; #with (or Genre.template with +base:+) makes changed copies.
      Template = Data.define(
        :name, :title, :about, :tempo, :tempo_range, :meter, :phrases, :key, :form,
        :kits, :clips, :roles, :scenes, :knobs, :pulse, :mix, :tips
      ) do
        # Data#with, plus an optional builder block applied on top:
        # `t.with(tempo: 170) { role :bass, :jungle_reese }`.
        def with(**changes, &block)
          t = changes.empty? ? self : super(**changes)
          block ? Genre.template(name, title, base: t, &block) : t
        end

        # The Scale of the template's key (nil without one).
        def scale
          key && MB::Sound.scale(*key)
        end

        # A bar's length in whole notes.
        def bar_length
          Rational(meter[0], meter[1])
        end

        # The form's length in bars, played straight through.
        def bars
          form.bars(bar_length: bar_length)
        end

        # The form's length in seconds at the template's tempo.
        def seconds
          bars * bar_length * 4 * 60 / tempo.to_r
        end

        # The values of scene +name+ for Arrangement#scene: kit and clip
        # names resolved to the template's Kits and Clips; knob values and
        # scene options passed on.
        def scene(name)
          values = scenes.fetch(name) { raise ArgumentError, "No scene #{name.inspect} in genre #{self.name.inspect}#{Form.suggest(name, scenes.keys)}" }
          values.to_h { |k, v|
            next [k, v] if Genre::SCENE_OPTIONS.include?(k) || knobs.key?(k)
            [k, v.is_a?(Symbol) && !Genre::SCENE_LITERALS.include?(v) ? material(v) : v]
          }
        end

        # The Kit or Clip named +name+.
        def material(name)
          kits.fetch(name) { clips.fetch(name) { raise ArgumentError, "No kit or clip #{name.inspect} in genre #{self.name.inspect}#{Form.suggest(name, kits.keys + clips.keys)}" } }
        end

        # A copy whose form is scaled to about +seconds+ long: every section
        # (and fill) divided by the power of two that comes closest (at
        # least 1 bar each; never longer than the full form).  Role params
        # named +bars+ (a riser's sweep, sized to its fill) scale too.
        def short(seconds = 60)
          divisor = 2**[Math.log2(self.seconds.to_f / seconds.to_f).round, 0].max
          return self if divisor == 1
          scaled = roles.transform_values { |r|
            next r unless r.params[:bars].is_a?(Numeric)
            r.with(params: r.params.merge(bars: [r.params[:bars].to_r / divisor, 1].max))
          }
          with(form: Genre.scale_form(form, divisor), roles: scaled)
        end

        # The graph for role +name+ playing +source+: the patch, a lowpass
        # driven by the role's filter knob, its level, and ducking under the
        # pulse kick.
        def patch(name, source)
          r = roles.fetch(name) { raise ArgumentError, "No role #{name.inspect} in genre #{self.name.inspect}#{Form.suggest(name, roles.keys)}" }
          node = Genre.build_patch(r.patch, source, r.params)
          node = node.filter(:lowpass, cutoff: MB::Sound.knob(r.filter), quality: 0.7) if r.filter
          node = node * r.level if r.level
          node = node.duck(pulse_kick, amount: r.duck, release: 1.n16) if r.duck
          node
        end

        # A ghost kick for ducking: the pulse kit's kick row on a tr808 with
        # a short kick (Genre::PULSE_KICK), never heard.
        def pulse_kick
          raise ArgumentError, "Genre #{name.inspect} has no pulse: kit for duck:" unless pulse
          MB::Sound.tr808(Sequence::Kit.new({ kick: kits.fetch(pulse)[:kick] }), kick: Genre::PULSE_KICK)
        end

        # Sets the template up on the current Session: tempo, meter, launch
        # quantization (1 bar), knobs, the master chain and gain, a track per
        # role (built with #patch), and the scenes.  Returns self.
        def setup
          MB::Sound.bpm(tempo)
          MB::Sound.transport.bar_length = bar_length unless meter == [4, 4]
          MB::Sound.quant(1)
          knobs.each { |n, (default, options)| MB::Sound.knob(n, default, **options) }
          MB::Sound.master_gain(mix.gain) if mix.gain
          unless mix.master.empty? && !mix.mono_below
            chain = mix.master
            mono = mix.mono_below
            MB::Sound.master { |m| Genre.master_chain(mono ? m.mono_below(mono) : m, chain) }
          end
          template = self
          roles.each { |n, r| MB::Sound.track(n, q: r.q, fade: r.fade) { |c| template.patch(n, c) } }
          scenes.each_key { |s| MB::Sound.scene(s, **scene(s)) }
          self
        end

        # #setup, then plays the form (see FormMethods#play_form; options go
        # there).  Returns the Form::Playback.
        def play(**options)
          setup
          MB::Sound.play_form(form, **options)
        end

        # Ruby code that builds this template again (Genre.template ... do
        # ... end; Genre.define takes the same block to register one).
        def to_ruby
          l = ["Genre.template #{name.inspect}, #{title.inspect} do"]
          l << "  about #{about.inspect}" if about
          l << "  tempo #{Genre.ruby(tempo)}#{", range: #{Genre.ruby(tempo_range)}" if tempo_range}"
          l << "  meter #{meter.join(', ')}"
          l << "  phrases #{phrases.join(', ')}" unless phrases.empty?
          l << "  key #{key.map(&:inspect).join(', ')}" if key
          form.to_ruby.each_line(chomp: true) { |line| l << "  #{line}" }
          kits.each { |n, k| l << "  kit #{n.inspect}, #{k.to_ruby}" }
          clips.each { |n, c| l << "  clip #{n.inspect}, #{c.to_ruby}" }
          knobs.each { |n, (d, o)| l << "  knob #{n.inspect}, #{Genre.ruby(d)}#{", #{Genre.kwargs(o)}" unless o.empty?}" }
          roles.each { |n, r|
            opts = r.options
            l << "  role #{n.inspect}, #{r.patch.inspect}#{", #{Genre.kwargs(opts)}" unless opts.empty?}"
          }
          scenes.each { |n, v| l << "  scene #{n.inspect}#{", #{Genre.kwargs(v)}" unless v.empty?}" }
          l << "  pulse #{pulse.inspect}" if pulse
          call = ->(m, v) { text = Genre.ruby(v); text.start_with?('-') ? "  #{m}(#{text})" : "  #{m} #{text}" } # (-1 alone warns)
          l << call.(:loudness, mix.loudness) if mix.loudness
          l << call.(:true_peak, mix.true_peak) if mix.true_peak
          l << call.(:mono_below, mix.mono_below) if mix.mono_below
          mix.master.each { |n, a, o|
            l << "  master #{[n.inspect, *a.map { |v| Genre.ruby(v) }, (Genre.kwargs(o) unless o.empty?)].compact.join(', ')}"
          }
          l << call.(:master_gain, mix.gain) if mix.gain
          tips.each { |t| l << "  tip #{t.inspect}" }
          l << 'end'
          l.join("\n")
        end
        alias_method :to_s, :to_ruby

        def ==(other)
          other.is_a?(Template) && to_ruby == other.to_ruby
        end
        alias_method :eql?, :==

        def hash
          to_ruby.hash
        end

        # A summary: tempo, meter, key, form, roles, mix, and the first tip.
        def summary
          secs = seconds.to_f
          lines = []
          lines << "genre #{name.inspect}: #{title}"
          lines << "  #{Genre.ruby(tempo)} BPM#{" (#{tempo_range})" if tempo_range}, #{meter.join('/')}" \
                   "#{", #{key[1].to_s.capitalize.sub('s', '#')} #{key[0]}" if key}, phrases of #{phrases.join('/')} bars"
          lines << "  form: #{form.steps.map { |n, t| "#{n} #{form.sections[n].length}#{" x#{t}" if t > 1}" }.join(', ')} " \
                   "(#{Genre.ruby(bars)} bars, #{(secs / 60).floor}:#{format('%02d', secs.round % 60)})"
          lines << "  roles: #{roles.map { |n, r| "#{n} (#{r.patch}#{", #{r.level.to_db.round(1)} dB" if r.level}#{', ducked' if r.duck})" }.join(', ')}"
          lines << "  kits: #{kits.keys.join(', ')}" unless kits.empty?
          lines << "  mix: #{mix.summary}" unless mix.summary.empty?
          lines << "  #{tips.length} tips (.tips): #{tips.first}" unless tips.empty?
          lines.join("\n")
        end

        def inspect
          "#<#{summary}>"
        end

        def pretty_print(q)
          q.text(inspect)
        end
      end

      # The block builder for templates (Genre.define, Genre.template,
      # Template#with): one method per part.  Other calls (grid, seq, chord,
      # events, scale, ...) go to MB::Sound, so kits and clips use the usual
      # DSL.  Re-declaring a kit, clip, role, knob, or scene replaces it.
      class Builder
        # Builds a Template named +name+ from the +block+, starting from
        # +base+ (a Template) if given.
        def self.build(name, title = nil, base: nil, &block)
          b = new(name, title, base)
          b.instance_exec(&block) if block
          b.__template__
        end

        def initialize(name, title, base)
          @name = name
          @title = title
          @tempo_range = nil
          @meter = [4, 4]
          @phrases = []
          @kits = {}
          @clips = {}
          @roles = {}
          @scenes = {}
          @knobs = {}
          @mix = {}
          @tips = []
          like(base) if base
          @title = title if title
        end

        # Starts from another template (a name or a Template): copies every
        # part (later calls change them).
        def like(template)
          t = template.is_a?(Template) ? template : Genre[template]
          @title ||= t.title
          @about, @tempo, @tempo_range, @meter, @phrases, @key, @form, @pulse =
            t.about, t.tempo, t.tempo_range, t.meter, t.phrases, t.key, t.form, t.pulse
          @kits, @clips, @roles, @scenes, @knobs = t.kits.dup, t.clips.dup, t.roles.dup, t.scenes.dup, t.knobs.dup
          @mix = t.mix.to_h.compact
          @tips = t.tips.dup
          nil
        end

        # The template's title (a few words).
        def title(text)
          @title = text
        end

        # Where the template came from and what it is (a sentence or two).
        def about(text)
          @about = text
        end

        # The default tempo (BPM) and the genre's usual +range+.
        def tempo(bpm, range: nil)
          raise ArgumentError, "tempo must be a positive number (got #{bpm.inspect})" unless bpm.is_a?(Numeric) && bpm > 0
          @tempo = bpm
          @tempo_range = range if range
        end

        # The time signature (e.g. `meter 7, 8`).
        def meter(beats, unit = 4)
          @meter = [beats, unit]
        end

        # Phrase lengths in bars (e.g. `phrases 8, 16, 32`).
        def phrases(*bars)
          @phrases = bars
        end

        # The key the template's material is written in: a mode and a root
        # (as for MB::Sound.scale: `key :minor, :f`).
        def key(mode, root)
          @key = [mode, root]
        end

        # The song form: a `flow` block (see Form::Builder).
        def flow(&block)
          @form = Form.build(&block)
        end
        alias form flow

        # A drum Kit (e.g. `kit :drop, grid(16, kick: 'X.........X.....')`).
        def kit(name, kit)
          raise ArgumentError, "kit #{name.inspect}: needs a Sequence::Kit (got #{kit.class})" unless kit.is_a?(Sequence::Kit)
          @kits[name] = kit
        end

        # A Clip of material (a riff, chords, a hook).
        def clip(name, clip)
          raise ArgumentError, "clip #{name.inspect}: needs a Sequence::Clip (got #{clip.class})" unless clip.is_a?(Sequence::Clip)
          @clips[name] = clip
        end

        # A track role played by +patch+ (a preset name, or an MB::Sound
        # method taking a MIDI source); options as Genre::Role.  A nil patch
        # removes the role.
        def role(name, patch, **options)
          return @roles.delete(name) && nil if patch.nil?
          @roles[name] = Role.new(patch: patch, **options)
        end

        # A knob the scenes turn and roles' filter: options read (as
        # MB::Sound.knob: `knob :cut, 2400, range: 150..8000, curve: :exp`).
        def knob(name, default, **options)
          @knobs[name] = [default, options.freeze].freeze
        end

        # A scene: role names to kit or clip names (or :on, :off, :cut,
        # :keep, nil), knob values, and scene options (q:, fade:, others:).
        # `scene :x, nil` removes one.
        def scene(name, values = :none, **kwargs)
          return @scenes.delete(name) && nil if values.nil?
          @scenes[name] = kwargs.freeze
        end

        # One scene per layer for a looper's build-up: each scene named
        # after the track it adds, holding every layer so far (`layers beat:
        # :beat, bass: :bass_a, keys: :keys_a`).
        def layers(**track_material)
          so_far = {}
          track_material.each do |track, material|
            so_far[track] = material
            scene track, **so_far
          end
        end

        # The kit whose kick row keys roles' duck: (a ghost kick).
        def pulse(kit_name)
          @pulse = kit_name
        end

        # Target integrated loudness in LUFS (a number or a Range).
        def loudness(lufs)
          @mix[:loudness] = lufs
        end

        # True-peak ceiling (e.g. `true_peak -1.db`).
        def true_peak(db)
          @mix[:true_peak] = db
        end

        # Makes the low end mono below +hz+ (GraphNode#mono_below, the first
        # stage of the master chain): an option for club systems and vinyl,
        # not for headphone or ambient mixes.  `mono_below nil` removes it.
        def mono_below(hz)
          @mix[:mono_below] = hz
        end

        # Adds a step to the master chain: an effect preset (`master
        # :dnb_master`) or a GraphNode method with its arguments (`master
        # :limit, ceiling: -1.db`).  Steps run in order; `master nil` clears
        # the chain.
        def master(name, *args, **params)
          return @mix[:master] = [] if name.nil?
          @mix[:master] = [*@mix[:master], [name, args.freeze, params.freeze].freeze]
        end

        # The master bus gain (e.g. `master_gain 0.db`).
        def master_gain(gain)
          @mix[:gain] = gain
        end

        # A practical tip (a sentence).
        def tip(text)
          @tips << text.dup.freeze
        end

        # Removes parts by name: `without roles: [:pluck], scenes: [:pullup]`.
        # Removed roles leave the scenes too.
        def without(roles: [], kits: [], clips: [], scenes: [], knobs: [])
          roles.each { |n| @roles.delete(n) }
          @scenes = @scenes.transform_values { |v| v.except(*roles).freeze } unless roles.empty?
          kits.each { |n| @kits.delete(n) }
          clips.each { |n| @clips.delete(n) }
          scenes.each { |n| @scenes.delete(n) }
          knobs.each { |n| @knobs.delete(n) }
          nil
        end

        BUILDER_METHODS = [
          :like, :title, :about, :tempo, :meter, :phrases, :key, :flow, :form, :kit, :clip, :role, :knob,
          :scene, :layers, :pulse, :loudness, :true_peak, :mono_below, :master, :master_gain, :tip, :without,
        ].freeze

        def method_missing(name, *args, **kwargs, &block)
          return MB::Sound.public_send(name, *args, **kwargs, &block) if MB::Sound.respond_to?(name)
          raise NoMethodError, "Unknown genre template method #{name}#{Form.suggest(name, BUILDER_METHODS)}"
        end

        def respond_to_missing?(name, include_private = false)
          MB::Sound.respond_to?(name) || super
        end

        def inspect
          "#<MB::Sound::Genre::Builder #{@name.inspect}>"
        end

        # The finished Template (checked; see #__check__).
        def __template__
          raise ArgumentError, "Genre #{@name.inspect} needs a tempo" unless @tempo
          raise ArgumentError, "Genre #{@name.inspect} needs a flow" unless @form
          t = Template.new(
            name: @name, title: (@title || @name.to_s).dup.freeze, about: @about&.dup&.freeze,
            tempo: @tempo, tempo_range: @tempo_range, meter: @meter.dup.freeze, phrases: @phrases.dup.freeze,
            key: @key&.dup&.freeze, form: @form, kits: @kits.dup.freeze, clips: @clips.dup.freeze,
            roles: @roles.dup.freeze, scenes: @scenes.dup.freeze, knobs: @knobs.dup.freeze, pulse: @pulse,
            mix: Mix.new(**@mix), tips: @tips.dup.freeze
          )
          __check__(t)
          t
        end

        private

        # Raises for scenes naming unknown roles, kits, or clips, form
        # sections without a scene, a missing pulse kit, a role filter that
        # isn't a knob, or a tempo outside its range.
        def __check__(t)
          where = "Genre #{t.name.inspect}"
          if t.tempo_range && !t.tempo_range.cover?(t.tempo)
            raise ArgumentError, "#{where}: tempo #{t.tempo} is outside its range #{t.tempo_range}"
          end
          t.scenes.each do |s, values|
            values.each do |k, v|
              next if SCENE_OPTIONS.include?(k) || t.knobs.key?(k)
              raise ArgumentError, "#{where}: scene #{s.inspect} names #{k.inspect}, which is neither a role nor a knob#{Form.suggest(k, t.roles.keys + t.knobs.keys)}" unless t.roles.key?(k)
              next unless v.is_a?(Symbol) && !SCENE_LITERALS.include?(v)
              next if t.kits.key?(v) || t.clips.key?(v)
              raise ArgumentError, "#{where}: scene #{s.inspect} plays #{v.inspect} on #{k.inspect}, which is no kit or clip#{Form.suggest(v, t.kits.keys + t.clips.keys)}"
            end
          end
          t.form.sections.each_value do |sec|
            next if sec.scene == false
            scene = sec.scene || sec.name
            raise ArgumentError, "#{where}: form section #{sec.name.inspect} has no scene #{scene.inspect}#{Form.suggest(scene, t.scenes.keys)}" unless t.scenes.key?(scene)
          end
          if t.pulse && !(t.kits.key?(t.pulse) && t.kits[t.pulse].rows.key?(:kick))
            raise ArgumentError, "#{where}: pulse #{t.pulse.inspect} must be a kit with a kick row"
          end
          if t.roles.any? { |_, r| r.duck } && !t.pulse
            raise ArgumentError, "#{where}: roles duck under the pulse kick, but there is no pulse"
          end
          t.roles.each do |n, r|
            r.params.each do |k, v|
              next unless v.is_a?(Symbol) && !t.knobs.key?(v)
              raise ArgumentError, "#{where}: role #{n.inspect} param #{k}: names #{v.inspect}, which is no knob#{Form.suggest(v, t.knobs.keys)}"
            end
            next unless r.filter
            raise ArgumentError, "#{where}: role #{n.inspect} filters with #{r.filter.inspect}, which is no knob#{Form.suggest(r.filter, t.knobs.keys)}" unless t.knobs.key?(r.filter)
          end
        end
      end
    end
  end
end

require_relative 'genre/patches'
require_relative 'genre/dnb'
require_relative 'genre/jungle'
require_relative 'genre/ambient'
require_relative 'genre/funk'
require_relative 'genre/house'
require_relative 'genre/techno'
