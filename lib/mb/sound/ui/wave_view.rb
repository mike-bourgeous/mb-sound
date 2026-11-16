module MB
  module Sound
    module UI
      # Live wave displays for the sound-design screen's preview pane, the
      # way wavetable plug-ins draw them (ui-wave-perf-1, a prototype behind
      # an option; the maintainer, 2026-11-15: "Traditional wavetable plugins
      # can update every wave in their display 30 or 60fps including all
      # modulation, so we should be able to come close"): every frame, from
      # the parameter values the voice used in its latest buffer, not from a
      # second copy of the voice played in windows.
      #
      # Off by default (`UI::WaveView.mode = :live`, or
      # MB_SOUND_UI_WAVES=live before start).  When live:
      #
      # - The render thread copies the moving values the shown node used
      #   (an oscillator's frequency, pulse width, and wavetable scan; a
      #   four-pole's cutoff and resonance) into a preallocated ring after
      #   every buffer (Tap#publish: Floats into an Array, nothing
      #   allocated), only while a display watches them.
      # - The painter's poll (4/s) picks the node (the synth lane of the
      #   newest sounding note, by the voice's amp envelope, as the
      #   envelope preview's playhead does) and sets the watch list.
      # - The preview pane, a live pane while it shows a live display,
      #   reads the newest values each frame (Tap#read) and draws: one cycle
      #   of the oscillator from its own kernel (a display copy of the tone
      #   with its shape settings, at those values: ToneDisplay), or a
      #   four-pole's closed-form response at that cutoff and resonance
      #   (FilterDisplay), straight into the screen's cells through the
      #   :plot_wave kernel (Plot::Wave).  What has no cheap form (FM, sync,
      #   phase modulation, AM, noise; the patch's settled cycle) keeps the
      #   rendered previews (UI::ToneCycle, the RENDER pane).
      module WaveView
        MODES = %i[off live].freeze

        @mode = ENV['MB_SOUND_UI_WAVES'].to_s == 'live' ? :live : :off
        @target = nil
        @feed = nil

        class << self
          # :off (the rendered previews, as before) or :live.
          attr_reader :mode

          def mode=(m)
            raise ArgumentError, "Wave view mode must be one of #{MODES.inspect} (got #{m.inspect})" unless MODES.include?(m)
            @mode = m
          end

          def live? = @mode == :live

          # The painter's current Target (see #watch_for), or nil.
          attr_accessor :target

          # The Feed whose tap #watch_for set last (the painter's), or nil.
          attr_accessor :feed
        end

        # What the preview pane draws live: +label+ of the node's row,
        # +kind+ (:tone or :four_pole), +watch+ (the frozen watch list the
        # tap publishes: [[node, key], ...]), +keys+ (the keys in order),
        # +display+ (a ToneDisplay or FilterDisplay, kept per node).
        Target = Data.define(:label, :kind, :watch, :keys, :display)

        # Keys published per node kind.
        KEYS = { tone: %i[frequency width scan].freeze, four_pole: %i[cutoff resonance].freeze, lfo: %i[frequency width scan phase].freeze }.freeze

        # Points of an LFO's drawn cycle (LFOs play naive shapes: the shape
        # is the same at any rate).
        LFO_POINTS = 512

        # The value node +node+ last used for +key+ (render thread; nothing
        # allocated): a Float, or NaN when not known.
        def self.value_of(node, key)
          case node
          when Tone
            st = node.instance_variable_get(:@state)
            return Float::NAN unless st
            v = case key
                when :frequency then st.last_freq
                when :width then st.last_width
                when :scan then st.last_scan
                when :phase then st.phi
                end
            v.is_a?(Float) ? v : (v.is_a?(Numeric) ? v.to_f : Float::NAN)
          when GraphNode::FourPole
            node.send(:last_of, key).to_f
          else
            Float::NAN
          end
        end

        # The render thread's side: a ring of the watched values, written
        # after every buffer, read by the painter (Feed#wave_tap).
        class Tap
          SLOTS = 8
          MAX = 16

          # Buffers published so far.
          attr_reader :seq

          # The watch list ([[node, key], ...], frozen; the painter's).
          attr_reader :watch

          def initialize
            @values = Array.new(SLOTS * MAX, Float::NAN)
            @slot_watch = Array.new(SLOTS)
            @watch = [].freeze
            @seq = 0
          end

          # Sets the watch list (painter thread; a frozen Array).
          def watch=(list)
            @watch = list.frozen? ? list : list.dup.freeze
          end

          # Render thread, after each buffer: copies the watched values into
          # the next slot.  Allocates nothing (Floats in an Array).
          def publish
            w = @watch
            n = w.length
            return if n == 0
            s = (@seq + 1) % SLOTS
            base = s * MAX
            i = 0
            while i < n && i < MAX
              e = w[i]
              @values[base + i] = WaveView.value_of(e[0], e[1])
              i += 1
            end
            @slot_watch[s] = w
            @seq += 1
          end

          # Painter: copies the newest values published for +watch+ (that
          # same list) into +out+ (an Array); true if they were read whole.
          def read(watch, out)
            3.times do
              s = @seq
              slot = s % SLOTS
              return false unless @slot_watch[slot].equal?(watch)
              base = slot * MAX
              i = 0
              n = watch.length
              while i < n
                out[i] = @values[base + i]
                i += 1
              end
              return true if @seq - s < SLOTS - 1
            end
            false
          end
        end

        # Painter (Poll, 4/s): sets the tap's watch list and #target for the
        # inspector's selected row of +info+ (an InspectInfo from
        # +gatherer+), or clears them.
        def self.watch_for(session, gatherer, info)
          feed = session.respond_to?(:ui_feed) ? session.ui_feed : nil
          return clear(feed) unless feed && info&.node && live?
          group = gatherer.group_of(info) or return clear(feed)
          first = group.first
          kind = first.is_a?(Tone) ? (first.lfo? ? :lfo : :tone) : first.is_a?(GraphNode::FourPole) ? :four_pole : nil
          unless kind
            # (an LFO row: Notes#lfo's mixer over its oscillator, which the
            # sections list as LFO internals)
            group = group.map { |n| lfo_tone_of(n) }
            return clear(feed) if group.any?(&:nil?)
            kind = :lfo
          end
          lane = newest_lane(gatherer.amp_env_group(info), group.length)
          node = group[lane] || group.first
          t = @target
          unless t && t.watch[0] && t.watch[0][0].equal?(node)
            display = (t && t.display.node.equal?(node)) ? t.display : (kind == :four_pole ? FilterDisplay.new(node) : ToneDisplay.new(node))
            keys = KEYS.fetch(kind)
            watch = keys.map { |k| [node, k].freeze }.freeze
            t = @target = Target.new(label: info.nodes[info.node].label, kind: kind, watch: watch, keys: keys, display: display)
          end
          @feed = feed
          tap = (feed.wave_tap ||= Tap.new)
          tap.watch = t.watch unless tap.watch.equal?(t.watch)
          t
        end

        # The LFO oscillator under +node+ (a Notes#lfo row), or nil.
        def self.lfo_tone_of(node)
          return node if node.is_a?(Tone) && node.lfo?
          return nil unless node.respond_to?(:graph)
          node.graph.find { |n| n.is_a?(Tone) && n.lfo? }
        rescue StandardError
          nil
        end

        def self.clear(feed)
          @target = nil
          feed.wave_tap.watch = [].freeze if feed&.wave_tap && !feed.wave_tap.watch.empty?
          nil
        end

        # The lane of the newest sounding note among an amp envelope's
        # copies (+envs+, in lane order), else 0 (+count+ lanes).
        def self.newest_lane(envs, count)
          return 0 unless envs && envs.length == count
          best = nil
          envs.each_with_index do |e, i|
            next unless e.respond_to?(:playhead_state)
            stage, _seg, _pos, since = e.playhead_state
            next unless stage == :segment || stage == :sustain
            best = [since, i] if best.nil? || since < best[0]
          end
          best ? best[1] : 0
        end

        # One cycle of an oscillator from its own kernel: a display copy of
        # the tone (its shape, band-limiting, pulse width and pivot,
        # wavetable and interpolation), whose frequency, width, and scan are
        # Constants set to the published values each frame; reset to the
        # same phase every frame, sampled for one period.
        class ToneDisplay
          attr_reader :node, :why, :rate

          # Frames of the longest period drawn (an LFO's slower cycle shows
          # its start).
          MAX_FRAMES = 8192

          def initialize(node)
            @node = node
            @why = unsupported(node)
            @rate = node.sample_rate.to_f
            @freq = nil
            @last_key = nil
            @cycle = nil
            return if @why
            # (Constants that jump: no smoothing between frames)
            @freq = GraphNode::Constant.new(110.0, smoothing: false, sample_rate: @rate)
            @width = node.pwm_width.nil? ? nil : GraphNode::Constant.new(0.5, smoothing: false, sample_rate: @rate)
            @scan = node.wavetable? ? GraphNode::Constant.new(0.0, smoothing: false, sample_rate: @rate) : nil
            wt = node.instance_variable_get(:@wave_type)
            t = Tone.new(wave_type: wt == :wavetable ? :sine : wt, frequency: @freq, sample_rate: @rate)
            t = t.pwm(@width, dc: node.instance_variable_get(:@keep_dc), pivot: numeric(node.instance_variable_get(:@pivot))) if @width
            if @scan
              t = t.wavetable(node.instance_variable_get(:@table), scan: @scan, interpolation: node.instance_variable_get(:@interpolation),
                              scan_wrap: node.instance_variable_get(:@scan_wrap))
            end
            t = t.lfo if node.lfo? # (an LFO's exact edges)
            @tone = t
            # (the state a fresh tone starts from, then a first sample for
            # the tone's own start-up; every cycle starts from that state)
            @tone.state
            @reset = saved_state
            @tone.sample(1)
          rescue StandardError => e
            @why = "#{e.class}: #{e.message}"
          end

          def supported? = @why.nil?

          # One period at +freq+ Hz with +width+ and +scan+ (NaN or nil:
          # the node's own fixed setting): an SFloat, reused when nothing
          # changed since the last call.
          def cycle(freq, width, scan)
            return nil if @why || !(freq.is_a?(Float) && freq.finite? && freq.abs > 0)
            key = [freq.round(2), width && width.finite? ? width.round(4) : nil, scan && scan.finite? ? scan.round(4) : nil]
            return @cycle if key == @last_key && @cycle
            @last_key = key
            @freq.constant = freq.abs
            @width.constant = key[1] if @width && key[1]
            @scan.constant = key[2] if @scan && key[2]
            n = (@rate / freq.abs).ceil.clamp(2, MAX_FRAMES)
            restore_state
            d = @tone.sample(n)
            d = d.real if d.is_a?(Numo::SComplex) || d.is_a?(Numo::DComplex)
            # (the tone's own buffer, kept until the next new cycle; the
            # display copy is sampled nowhere else)
            @cycle = d.is_a?(Numo::SFloat) ? d : Numo::SFloat.cast(d)
          end

          private

          # The display tone's State fields as [getter, setter, value]
          # (copies), restored in place before each cycle (#restore_state;
          # Tone#plan_restore makes a new State, ~30 objects a call).
          def saved_state
            st = @tone.instance_variable_get(:@state)
            (Tone::State::FIELDS - %i[seed jump_residual]).map { |f|
              v = st.public_send(f)
              [f, :"#{f}=", v.is_a?(Array) || v.is_a?(Numo::NArray) ? v.dup : v].freeze
            }.freeze
          end

          # Puts the State fields saved by #saved_state back, in place where
          # they are Arrays or NArrays of the same size.
          def restore_state
            st = @tone.instance_variable_get(:@state)
            @reset.each do |getter, setter, v|
              cur = st.public_send(getter)
              if v.is_a?(Array) && cur.is_a?(Array) && cur.length == v.length
                cur.replace(v)
              elsif v.is_a?(Numo::NArray) && cur.is_a?(Numo::NArray) && cur.size == v.size && cur.class == v.class
                cur[] = v
              else
                st.public_send(setter, v.is_a?(Array) || v.is_a?(Numo::NArray) ? v.dup : v)
              end
            end
          end

          def numeric(v) = v.is_a?(Numeric) ? v : nil

          # Why a live cycle of +node+ isn't drawn (FM, sync, phase or
          # output modulation, noise, feedback have no cheap form), or nil.
          def unsupported(node)
            return 'noise' if node.instance_variable_get(:@noise).to_f > 0
            return 'synced' if node.instance_variable_get(:@sync_source)
            return 'phase modulated' if node.instance_variable_get(:@phase_mod)
            return 'feedback' if node.instance_variable_get(:@feedback)
            g = node.instance_variable_get(:@out_gain)
            return 'amplitude modulated' if g && !g.is_a?(Numeric)
            return 'frequency modulated' if fm?(node)
            nil
          end

          # True if another oscillator reaches the frequency input (FM), not
          # counting LFOs, knobs, and note plumbing.
          def fm?(node)
            src = node.instance_variable_get(:@frequency)
            return false unless src.respond_to?(:graph)
            src.graph.any? { |n| n.is_a?(Tone) && !n.equal?(node) && !n.lfo? && !n.instance_variable_get(:@noise).to_f.positive? }
          rescue StandardError
            true
          end
        end

        # A four-pole's (or diode ladder's) closed-form response at the
        # published cutoff and resonance: its preview data's settings, one
        # filter kept and retuned.
        class FilterDisplay
          attr_reader :node, :why

          def initialize(node)
            @node = node
            @why = nil
            @d = node.preview_data
            @rate = @d[:sample_rate]
            @filter = Filter::FourPole.new(
              cutoff: @d[:cutoff], resonance: @d[:resonance].clamp(0.0, 1.0), mode: @d[:mode], self_oscillate: @d[:self_oscillate], compensation: @d[:compensation],
              resonance_curve: @d[:resonance_curve], normalize: @d[:normalize], tuning: @d[:tuning], sample_rate: @rate,
              drive_mode: @d[:drive_mode] == :stages && @d[:mode] == :diode ? :input : @d[:drive_mode], clip: @d[:drive_mode] == :feedback ? @d[:clip] : :soft
            )
            @top = Plot::Panels.four_pole_top(@d)
            @last_key = nil
            @db = nil
          rescue StandardError => e
            @why = "#{e.class}: #{e.message}"
          end

          def supported? = @why.nil?

          # dB axis: -60 to the four-pole's fixed top.
          def range = (-60.0..@top.to_f)

          # The response in dB at 256 log-spaced frequencies (an SFloat),
          # recomputed when the cutoff moves by more than a 96th of an octave
          # or the resonance by 0.002.
          def curve(cutoff, resonance)
            cutoff = @d[:cutoff] unless cutoff.is_a?(Float) && cutoff.finite?
            resonance = @d[:resonance] unless resonance.is_a?(Float) && resonance.finite?
            key = [(Math.log2([cutoff, 1.0].max) * 96).round, (resonance * 500).round]
            return @db if key == @last_key && @db
            @last_key = key
            @filter.cutoff = cutoff.clamp(20.0, @rate * 0.45)
            @filter.resonance = resonance.clamp(0.0, 1.0)
            _f, db = Plot::Presets.response_db(@filter, @rate)
            @db = Numo::SFloat.cast(db.clip(-60.0, nil))
          end
        end

        # The preview pane's live drawing (prepended to Panes::Preview):
        # while #live? and the selected row is the Target, one title row and
        # the wave below it, every frame (a live pane).
        module PreviewLive
          def priority
            WaveView.live? && @wave_live ? :live : super
          end

          def draw(c, s, state, look: nil)
            @wave_live = false
            return super unless WaveView.live?
            n = s&.inspector&.selected
            t = WaveView.target
            return super unless n && t && t.label == n.label && t.display.supported?
            feed_tap = WaveView.feed&.wave_tap
            vals = (state[:wave_vals] ||= Array.new(Tap::MAX, Float::NAN))
            got = feed_tap && feed_tap.read(t.watch, vals)
            return super unless got || state[:wave_data]
            data, lo, hi, title, mark = WaveView.picture(t, vals, n, c.w)
            return super unless data
            @wave_live = true
            state[:wave_data] = data
            w = c.w
            h = c.h
            return if w <= 0 || h <= 0
            c.clear
            c.text(0, 0, c.fit(title, w), :dim)
            if h > 1
              fg = MB::Term::Cells.pack(Theme.rgb(:key)) || -1
              Plot::Wave.draw(c.grid, data, x: c.x, y: c.y + 1, w: w, h: h - 1, lo: lo, hi: hi, fg: fg,
                              mark: mark || -1, mark_fg: MB::Term::Cells.pack(Theme.rgb(:warn)) || -1)
            end
            nil
          end
        end

        # [data, lo, hi, title, marker dot column or nil] for Target +t+ at
        # values +vals+ (row +n+), drawn +w+ cells wide.
        def self.picture(t, vals, n, w = 0)
          case t.kind
          when :lfo
            f, wd, sc, ph = vals[0], vals[1], vals[2], vals[3]
            d = t.display.cycle(t.display.rate / LFO_POINTS, wd, sc) or return nil
            peak = [d.abs.max.to_f, 1.0].max
            mark = ph.finite? && w > 0 ? ((ph % 1.0) * 2 * w).floor.clamp(0, 2 * w - 1) : nil
            [d, -peak, peak, "#{n.label} #{f.finite? ? Plot::Panels.hz_text(f.abs) : '?'} live, now at #{ph.finite? ? format('%.2f', ph % 1.0) : '?'}", mark]
          when :tone
            f, wd, sc = vals[0], vals[1], vals[2]
            d = t.display.cycle(f, wd, sc) or return nil
            peak = [d.abs.max.to_f, 1.0].max
            peak = (peak * 4).ceil / 4.0 if peak > 1.0
            extra = [wd.finite? ? "pw #{format('%.2f', wd)}" : nil, sc.finite? ? "scan #{format('%.2f', sc)}" : nil].compact.join(' ')
            [d, -peak, peak, "#{n.label} #{Plot::Panels.hz_text(f.abs)} live #{extra}".rstrip]
          when :four_pole
            cut, res = vals[0], vals[1]
            d = t.display.curve(cut, res)
            r = t.display.range
            [d, r.begin, r.end, "#{n.label} #{Plot::Panels.hz_text(cut.finite? ? cut : 0.0)} reso #{res.finite? ? format('%.2f', res) : '?'} live"]
          end
        end

        Panes::Preview.prepend(PreviewLive)
      end
    end
  end
end
