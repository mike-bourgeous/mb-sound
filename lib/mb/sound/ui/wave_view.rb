# frozen_string_literal: true

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
      # Off by default (`ui.waves :live`, `UI::WaveView.mode = :live`, or
      # MB_SOUND_UI_WAVES=live before start).  When live:
      #
      # - The render thread copies the moving values the shown node used
      #   (an oscillator's frequency, pulse width, and wavetable scan; a
      #   four-pole's cutoff and resonance; an SVF's or biquad's cutoff,
      #   quality, and gain; a voice's note frequency) into a preallocated
      #   ring after every buffer (Tap#publish: Floats into an Array,
      #   nothing allocated), only while a display watches them.
      # - The painter's poll (4/s) picks the node (the synth lane of the
      #   newest sounding note, by the voice's amp envelope, as the
      #   envelope preview's playhead does) and sets the watch list.
      # - The preview pane, a live pane while it shows a live display,
      #   reads the newest values each frame (Tap#read) and draws, without
      #   allocating (wave_budgets_spec): one cycle of the oscillator from
      #   its own kernel (ToneDisplay), a filter's response from its
      #   transfer function through the :plot_response kernel
      #   (FilterDisplay), an LFO's shape with a marker at its phase now,
      #   an envelope's trace with its playhead, straight into the screen's
      #   cells through the :plot_wave kernel (Plot::Wave).  An oscillator
      #   with no cheap cycle (FM, sync, phase modulation, AM, noise,
      #   feedback) shows one period of its voice's output instead
      #   (OutputTap on the Synth's lane, VoiceView).  Shapers keep the
      #   chart preview (their curve has no moving input), and so does the
      #   RENDER pane (UI::PatchRender: the patch's settled note).
      module WaveView
        MODES = %i[off live].freeze

        @mode = ENV['MB_SOUND_UI_WAVES'].to_s == 'live' ? :live : :off
        @target = nil
        @feed = nil
        @output_tap = nil
        @tapped = nil

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
        # +view+ (a ToneDisplay or FilterDisplay, kept per node).
        Target = Data.define(:label, :kind, :watch, :keys, :view)

        # Keys published per node kind.
        KEYS = {
          tone: %i[frequency width scan].freeze, four_pole: %i[cutoff resonance].freeze, lfo: %i[frequency width scan phase].freeze,
          svf: %i[cutoff quality gain].freeze, biquad: %i[cutoff quality].freeze,
          voice: %i[value].freeze, # (one per Notes::Frequency of the lane, up to four)
        }.freeze

        # Target kinds drawn by a FilterDisplay.
        FILTER_KINDS = %i[four_pole svf biquad].freeze

        # Points of an LFO's drawn cycle (LFOs play naive shapes: the shape
        # is the same at any rate).
        LFO_POINTS = 512

        # What a live display draws this frame: +data+ (an SFloat, the
        # view's own buffer), the value range +lo+..+hi+, a marker dot
        # column (+mark+, -1 for none), and the +title+ (a String the view
        # rewrites in place).  One per view, changed in place.
        Picture = Struct.new(:data, :lo, :hi, :mark, :title)

        # Number text appended to a String in place, allocating nothing
        # (the live titles change every frame under an LFO: String#format
        # and interpolation would allocate a few Strings a frame).  Digits
        # come from rounding the scaled value half to even, as Kernel#format
        # does for 0.025 ("0.02"); the scaling's own rounding can still make
        # a value within an ulp of halfway print one step from format's.
        module Label
          module_function

          # Appends +v+ with +dec+ (0..6) decimals, as format('%.<dec>f').
          def fixed(buf, v, dec)
            return buf << QUESTION unless v.is_a?(Numeric) && v.finite?
            scale = POW10[dec]
            q = round_even(v.abs * scale)
            buf << MINUS if v < 0
            int(buf, q / scale)
            return buf if dec == 0
            buf << DOT
            frac = q % scale
            d = scale / 10
            while d > 0
              buf << (ZERO + (frac / d) % 10)
              d /= 10
            end
            buf
          end

          # +x+ (a non-negative Float) rounded to an Integer, halves to even
          # (Kernel#format rounds the shortest decimal form of a value, so
          # 1.015 prints "1.02" and 0.025 "0.02"; a scaled value within a
          # few ulps of a half counts as a half).
          def round_even(x)
            q = x.floor
            r = x - q
            tie = (r - 0.5).abs <= x * 4e-16 # (a decimal tie such as 2.5 for 0.025 * 100, or 101.49999999999999 for 1.015 * 100)
            tie ? (q.odd? ? q + 1 : q) : (r > 0.5 ? q + 1 : q)
          end

          # Appends a non-negative Integer.
          def int(buf, n)
            int(buf, n / 10) if n >= 10
            buf << (ZERO + n % 10)
          end

          # Appends +v+ with three significant digits and no trailing zeros,
          # as format('%.3g') for 1e-4 <= v < 1e6 (outside that, through
          # format).
          def g3(buf, v)
            return buf << ZERO if v == 0
            neg = v < 0
            a = v.abs
            return buf << format('%.3g', v) unless a >= 1e-4 && a < 1e6
            e = Math.log10(a).floor
            q = round_even(a / 10.0**(e - 2))
            if q >= 1000
              e += 1
              q = round_even(a / 10.0**(e - 2))
            elsif q < 100
              e -= 1
              q = round_even(a / 10.0**(e - 2))
            end
            buf << MINUS if neg
            if e >= 2
              int(buf, q * POW10[e - 2])
            elsif e >= 0
              # (e + 1 digits before the point)
              div = POW10[2 - e]
              int(buf, q / div)
              frac = q % div
              if frac != 0
                buf << DOT
                while frac != 0
                  div /= 10
                  buf << (ZERO + frac / div)
                  frac %= div
                end
              end
            else
              buf << ZERO << DOT
              (-e - 1).times { buf << ZERO }
              div = 100
              frac = q
              while frac != 0
                buf << (ZERO + frac / div)
                frac %= div
                div /= 10
              end
            end
            buf
          end

          # Appends Plot::Panels.hz_text(hz): "2400 Hz", "12.5 kHz".
          def hz(buf, hz)
            if hz >= 10_000
              g3(buf, hz / 1000.0) << KHZ
            elsif hz >= 100
              int(buf, hz.round) << HZ
            else
              g3(buf, hz) << HZ
            end
          end

          # Cuts +buf+ to +n+ characters in place, ending in an ellipsis
          # when cut (as Canvas#fit).
          def fit(buf, n)
            len = buf.length
            return buf if len <= n
            if n < 2
              buf[n, len - n] = '' if n >= 0
            else
              buf[n - 1, len - n + 1] = ELLIPSIS
            end
            buf
          end

          POW10 = [1, 10, 100, 1000, 10_000, 100_000, 1_000_000].freeze
          ZERO = 48
          DOT = 46
          MINUS = 45
          QUESTION = 63
          HZ = ' Hz'
          KHZ = ' kHz'
          ELLIPSIS = '…'
        end

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
          when Notes::Frequency
            v = node.value
            v.is_a?(Float) ? v : (v.is_a?(Numeric) ? v.to_f : Float::NAN)
          when Filter::SampleWrapper
            # (SVF and Cookbook remember the last cutoff, quality, and gain
            # they read, planned or not)
            v = case key
                when :cutoff then node.instance_variable_get(:@base_filter).cutoff
                when :quality then node.instance_variable_get(:@base_filter).quality
                when :gain then (f = node.instance_variable_get(:@base_filter)).is_a?(Filter::SVF) ? f.gain : nil
                end
            v.is_a?(Float) ? v : (v.is_a?(Numeric) ? v.to_f : Float::NAN)
          else
            Float::NAN
          end
        end

        # The FilterDisplay kind of +node+ (:four_pole, :svf, :biquad), or
        # nil.
        def self.filter_kind(node)
          return :four_pole if node.is_a?(GraphNode::FourPole)
          return nil unless node.is_a?(Filter::SampleWrapper)
          f = node.instance_variable_get(:@base_filter)
          f.is_a?(Filter::SVF) ? :svf : (f.is_a?(Filter::Cookbook) ? :biquad : nil)
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
          # (A while loop: a return out of a block allocates.)
          def read(watch, out)
            tries = 0
            n = watch.length
            while tries < 3
              tries += 1
              s = @seq
              slot = s % SLOTS
              return false unless @slot_watch[slot].equal?(watch)
              base = slot * MAX
              i = 0
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
          kind = first.is_a?(Tone) ? (first.lfo? ? :lfo : :tone) : filter_kind(first)
          unless kind
            # (an LFO row: Notes#lfo's mixer over its oscillator, which the
            # sections list as LFO internals; only rows the sections call
            # an LFO, so a shaper after a scan-modulated oscillator isn't one)
            return clear(feed) unless info.nodes[info.node].what == 'lfo'
            group = group.map { |n| lfo_tone_of(n) }
            return clear(feed) if group.any?(&:nil?)
            kind = :lfo
          end
          lane = newest_lane(gatherer.amp_env_group(info), group.length)
          node = group[lane] || group.first
          t = @target
          view = t && t.view.node.equal?(node) ? t.view : nil
          if kind == :tone
            # (an oscillator without a cheap cycle: the voice's output)
            view = ToneDisplay.new(node) unless view
            unless view.supported? || view.is_a?(VoiceView)
              why = view.why
              view = nil
              kind = :voice
            end
            kind = :voice if view.is_a?(VoiceView)
          end
          if kind == :voice
            synth = gatherer.synth_of(info, group.length) or return clear(feed)
            unless view.is_a?(VoiceView) && view.lane == lane
              freqs = frequencies_of(synth, lane)
              return clear(feed) if freqs.empty?
              view = VoiceView.new(node, (@output_tap ||= OutputTap.new), lane, freqs, why || (view.respond_to?(:reason) ? view.reason : nil))
            end
            attach_output(synth, lane)
          else
            attach_output(nil, 0)
          end
          unless t && view && t.view.equal?(view) && t.kind == kind
            view ||= FILTER_KINDS.include?(kind) ? FilterDisplay.new(node) : ToneDisplay.new(node)
            keys = KEYS.fetch(kind)
            watch = if kind == :voice
                      view.frequencies.map { |f| [f, :value].freeze }.freeze
                    else
                      keys.map { |k| [node, k].freeze }.freeze
                    end
            t = @target = Target.new(label: info.nodes[info.node].label, kind: kind, watch: watch, keys: keys, view: view)
          end
          @feed = feed
          tap = (feed.wave_tap ||= Tap.new)
          tap.watch = t.watch unless tap.watch.equal?(t.watch)
          t
        end

        # The Notes::Frequency nodes of +synth+'s lane +lane+ (the voice's
        # note frequencies: v.hz and its transpositions), at most four.
        def self.frequencies_of(synth, lane)
          outs = synth.instance_variable_get(:@lanes)&.[](lane) or return [].freeze
          Array(outs).flat_map { |o| o.respond_to?(:graph) ? o.graph.grep(Notes::Frequency) : [] }.uniq.first(4).freeze
        rescue StandardError
          [].freeze
        end

        # Sets +synth+'s output tap to lane +lane+ (nil: detaches the tap
        # from the Synth it was on).
        def self.attach_output(synth, lane)
          old = @tapped
          return if synth.nil? && old.nil?
          if old && !old.equal?(synth)
            old.output_tap = nil if old.output_tap.equal?(@output_tap)
            @tapped = nil
          end
          return unless synth
          @output_tap.lane = lane
          synth.output_tap = @output_tap unless synth.output_tap.equal?(@output_tap)
          @tapped = synth
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
          attach_output(nil, 0)
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

        # A held value as a display tone's input: one reused SFloat per
        # frame count, filled in place when the value changes, so drawing a
        # cycle allocates nothing (a Constant queues each change as a new
        # Array and fills a new frozen buffer).  Not a GraphNode: only the
        # display copies read it, never a graph.
        class Hold
          attr_reader :sample_rate
          attr_accessor :value

          def initialize(value, sample_rate:)
            @value = value.to_f
            @sample_rate = sample_rate.to_f
            @buf = nil
            @filled = nil
          end

          def sample(count)
            buf = @buf
            unless buf && buf.length == count
              buf = @buf = Numo::SFloat.new(count)
              @filled = nil
            end
            v = @value
            unless v.eql?(@filled)
              BufferHelper.fill(buf, v, 0, count)
              @filled = v
            end
            buf
          end
        end

        # One cycle of an oscillator from its own kernel: a display copy of
        # the tone (its shape, band-limiting, pulse width and pivot,
        # wavetable and interpolation), whose frequency, width, and scan are
        # Holds set to the published values each frame; reset to the same
        # phase every frame, sampled for one period.  Allocates nothing
        # while the period's length stays the same (a new length: a new
        # input and output buffer).
        class ToneDisplay
          attr_reader :node, :why, :rate, :picture

          # Frames of the longest period drawn (an LFO's slower cycle shows
          # its start).
          MAX_FRAMES = 8192

          def initialize(node)
            @node = node
            @why = unsupported(node)
            @rate = node.sample_rate.to_f
            @picture = Picture.new(nil, -1.0, 1.0, -1, String.new(capacity: 96, encoding: Encoding::UTF_8))
            @freq = nil
            @kf = @kw = @ks = nil
            @cycle = nil
            @real = nil
            @peak = 1.0
            @mm = [0.0, 0.0]
            @tk = nil
            return if @why
            @freq = Hold.new(110.0, sample_rate: @rate)
            @width = node.pwm_width.nil? ? nil : Hold.new(0.5, sample_rate: @rate)
            @scan = node.wavetable? ? Hold.new(0.0, sample_rate: @rate) : nil
            wt = node.instance_variable_get(:@wave_type)
            t = Tone.new(wave_type: wt == :wavetable ? :sine : wt, frequency: @freq, sample_rate: @rate)
            # (the warp's pivot as a held input too: a number would be
            # rounded to a float through a packed String every cycle)
            if @width
              pv = node.instance_variable_get(:@pivot)
              pv = pv.is_a?(Numeric) ? pv.to_f : t.warp_pivot
              t = t.pwm(@width, dc: node.instance_variable_get(:@keep_dc), pivot: Hold.new(Kernels::Arithmetic.f32(pv), sample_rate: @rate))
            end
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
          # changed since the last call (by the frequency to a hundredth of
          # a hertz, width and scan to 1e-4).  #peak is its largest
          # absolute value.
          def cycle(freq, width, scan)
            return nil if @why || !(freq.is_a?(Float) && freq.finite? && freq.abs > 0)
            kf = (freq * 100).round
            kw = width && width.finite? ? (width * 10_000).round : nil
            ks = scan && scan.finite? ? (scan * 10_000).round : nil
            return @cycle if @cycle && kf == @kf && kw == @kw && ks == @ks
            @kf = kf
            @kw = kw
            @ks = ks
            @freq.value = freq.abs
            @width.value = width.round(4) if @width && kw
            @scan.value = scan.round(4) if @scan && ks
            n = (@rate / freq.abs).ceil.clamp(2, MAX_FRAMES)
            restore_state
            d = @tone.sample(n)
            if d.is_a?(Numo::SComplex)
              @real = Numo::SFloat.new(n) unless @real && @real.length == n
              Kernels.complex_part(@real, d, false)
              d = @real
            end
            d = Numo::SFloat.cast(d) unless d.is_a?(Numo::SFloat)
            # (the tone's own buffer, kept until the next new cycle; the
            # display copy is sampled nowhere else)
            Kernels.min_max(d, @mm)
            lo = @mm[0]
            hi = @mm[1]
            @peak = -lo > hi ? -lo : hi
            @cycle = d
          end

          # The largest absolute value of the last #cycle.
          attr_reader :peak

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
          # they are Arrays or NArrays of the same size (nothing allocated
          # then: Array#replace of a same-length Array, Kernels.copy).
          def restore_state
            st = @tone.instance_variable_get(:@state)
            @reset.each do |getter, setter, v|
              cur = st.public_send(getter)
              if v.is_a?(Array) && cur.is_a?(Array) && cur.length == v.length
                restore_array(cur, v)
              elsif v.is_a?(Array) && cur.is_a?(Array) && v.none?(Array) && !cur.frozen?
                # (a state the kernel lengthens on its first buffer, such as
                # a wavetable's: back to its first length, in place)
                cur.replace(v)
              elsif v.is_a?(Numo::NArray) && cur.is_a?(Numo::NArray) && cur.size == v.size && cur.class == v.class && !cur.frozen? && Kernels.copy(cur, v)
                nil
              elsif !v.equal?(cur)
                st.public_send(setter, v.is_a?(Array) || v.is_a?(Numo::NArray) ? v.dup : v)
              end
            end
          end

          # Copies Array +v+ into +cur+ element by element (nested Arrays
          # of the same shape in place too).
          def restore_array(cur, v)
            i = 0
            n = v.length
            while i < n
              x = v[i]
              c = cur[i]
              if x.is_a?(Array) && c.is_a?(Array) && c.length == x.length
                restore_array(c, x)
              elsif x.is_a?(Numo::NArray) && c.is_a?(Numo::NArray) && c.size == x.size && c.class == x.class && !c.frozen? && Kernels.copy(c, x)
                nil
              elsif !x.equal?(c)
                cur[i] = x.is_a?(Array) || x.is_a?(Numo::NArray) ? x.dup : x
              end
              i += 1
            end
          end

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

        # A filter's response at the published settings, from its transfer
        # function (#z_polynomials) through the :plot_response kernel,
        # allocating nothing while the settings only move (an SVF retuned
        # allocates its coefficients' Array): a four-pole or diode ladder at
        # its cutoff and resonance, an SVF at its cutoff, quality, and gain,
        # a cookbook biquad at its cutoff and quality.  One filter made from
        # the node's preview data (as Plot::Panels draws it), kept and
        # retuned; the dB axis is the chart preview's.
        class FilterDisplay
          attr_reader :node, :why, :picture, :lo, :hi, :kind

          # Points of a response curve (as Presets.response_db draws it).
          POINTS = 256

          def initialize(node)
            @node = node
            @why = nil
            @picture = Picture.new(nil, -60.0, 0.0, -1, String.new(capacity: 96, encoding: Encoding::UTF_8))
            @lo = -60.0
            @hi = 0.0
            @kind = WaveView.filter_kind(node)
            @k1 = @k2 = @k3 = nil
            @db = Numo::SFloat.new(POINTS)
            @b = Array.new(5, 0.0)
            @a = Array.new(5, 0.0)
            @mm = [0.0, 0.0]
            @d = node.preview_data
            raise ArgumentError, 'no preview data' unless @d
            @rate = @d[:sample_rate].to_f
            case @kind
            when :four_pole
              @filter = Filter::FourPole.new(
                cutoff: @d[:cutoff], resonance: @d[:resonance].clamp(0.0, 1.0), mode: @d[:mode], self_oscillate: @d[:self_oscillate], compensation: @d[:compensation],
                resonance_curve: @d[:resonance_curve], normalize: @d[:normalize], tuning: @d[:tuning], sample_rate: @rate,
                drive_mode: @d[:drive_mode] == :stages && @d[:mode] == :diode ? :input : @d[:drive_mode], clip: @d[:drive_mode] == :feedback ? @d[:clip] : :soft
              )
              @top = Plot::Panels.four_pole_top(@d).to_f
            when :svf
              @filter = Filter::SVF.new(@d[:filter_type], @rate, @d[:cutoff], quality: @d[:quality], gain: @d[:gain])
              @top = Plot::Panels.cookbook_top(@d).to_f
            when :biquad
              @filter = Filter::Cookbook.new(@d[:filter_type], @rate, @d[:cutoff], quality: @d[:quality], db_gain: @d[:db_gain])
              @top = Plot::Panels.cookbook_top(@d).to_f
            else
              raise ArgumentError, "no live response for #{node.class}"
            end
            @hi = @top
          rescue StandardError => e
            @why = "#{e.class}: #{e.message}"
          end

          def supported? = @why.nil?

          # The response in dB (at least -60) at POINTS log-spaced
          # frequencies from 20 Hz to Nyquist (an SFloat, reused) for the
          # cutoff and the second and third settings (a four-pole's
          # resonance; an SVF's or biquad's quality, an SVF's gain; NaN: the
          # preview's), recomputed when the cutoff moves by more than a 96th
          # of an octave or a setting by about 0.2 %.  Sets #hi to the
          # preview's top, raised in 6 dB steps if the curve passes it
          # (Panels.db_range).
          def curve(cutoff, second, third = Float::NAN)
            cutoff = @d[:cutoff] unless cutoff.is_a?(Float) && cutoff.finite?
            k1 = (Math.log2(cutoff > 1.0 ? cutoff : 1.0) * 96).round
            if @kind == :four_pole
              second = @d[:resonance] unless second.is_a?(Float) && second.finite?
              k2 = (second * 500).round
              k3 = 0
            else
              second = (@d[:quality] || 0.7071).to_f unless second.is_a?(Float) && second.finite? && second > 0
              k2 = (Math.log2(second) * 500).round
              third = nil unless @kind == :svf && third.is_a?(Float) && third.finite? && third > 0
              k3 = third ? (Math.log2(third) * 500).round : 0
            end
            return @db if k1 == @k1 && k2 == @k2 && k3 == @k3
            @k1 = k1
            @k2 = k2
            @k3 = k3
            case @kind
            when :four_pole
              @filter.cutoff = cutoff.clamp(20.0, @rate * 0.45)
              @filter.resonance = second.clamp(0.0, 1.0)
            when :svf
              @filter.cutoff = cutoff.clamp(20.0, @rate * 0.49)
              @filter.quality = second
              @filter.gain = third if third
            when :biquad
              @filter.center_frequency = cutoff.clamp(20.0, @rate * 0.49)
              @filter.quality = second
            end
            @filter.z_polynomials(@b, @a)
            Plot::Response.db(@db, @b, @a, @rate, 20.0, @rate * 0.4995, -60.0)
            Kernels.min_max(@db, @mm)
            peak = @mm[1]
            @hi = peak.finite? && peak > @top ? ((peak / 6.0).ceil * 6).to_f : @top
            @db
          end
        end

        # The render thread's copy of one Synth lane's output (the voice
        # the inspector shows), for what has no closed form (FM, sync,
        # phase or amplitude modulation, noise, feedback: VoiceView).  Set
        # as the Synth's #output_tap; every buffer #write copies the lane's
        # first channel into a ring (Kernels.circular_write: nothing
        # allocated, the buffer itself never kept: #sample buffers may be
        # shared and reused); the painter copies the newest samples out
        # with #read.
        class OutputTap
          # Samples kept (about 170 ms at 48 kHz).
          SIZE = 8192

          # Samples written so far, and the number of lane changes (a new
          # lane's samples don't continue the old one's).
          attr_reader :written, :generation, :lane

          def initialize
            @ring = Numo::SFloat.zeros(SIZE)
            @written = 0
            @generation = 0
            @lane = 0
          end

          # Painter: shows lane +i+ from now on.
          def lane=(i)
            return if i == @lane
            @lane = i
            @generation += 1
          end

          # Render thread (Synth#sample_lanes): copies the lane's buffer.
          def write(data)
            e = data && data[@lane]
            e = e[0] if e.is_a?(Array)
            return unless e.is_a?(Numo::SFloat)
            n = e.size
            return if n == 0 || n > SIZE
            return unless Kernels.circular_write(@ring, e, @written % SIZE)
            @written += n
          end

          # Painter: copies the newest +len+ samples into +out+ (an SFloat
          # of at least +len+); returns the count written before them (the
          # absolute index of out[0]), or nil (too few yet, or the render
          # thread overwrote them meanwhile).
          def read(out, len)
            w0 = @written
            return nil if w0 < len || len > SIZE / 2
            return nil unless Kernels.circular_read(@ring, (w0 - len) % SIZE, len, out)
            return nil if @written - w0 > SIZE - len
            w0 - len
          end
        end

        # One period of the shown voice's output, from the OutputTap, every
        # frame: the period from the voice's note frequency (the lowest of
        # its Notes::Frequency nodes' latest values, published by the value
        # tap), its start locked to the rising zero crossing nearest where
        # the last frame's start falls a whole number of periods later (so
        # a steady sound stands still instead of swimming), interpolated to
        # a sub-sample start; the amplitude range follows the peak with a
        # slow decay.  Allocates nothing while the note stays (a new period
        # length makes a new view of the cycle buffer).
        class VoiceView
          attr_reader :node, :why, :picture, :rate, :tap, :frequencies, :lane

          # Longest period drawn, in samples (a 12 Hz cycle at 48 kHz).
          MAX_PERIOD = 4000

          def initialize(node, tap, lane, frequencies, why)
            @node = node
            @tap = tap
            @lane = lane
            @frequencies = frequencies
            @why = nil
            @reason = why
            @rate = node.respond_to?(:sample_rate) ? node.sample_rate.to_f : 48_000.0
            @picture = Picture.new(nil, -1.0, 1.0, -1, String.new(capacity: 96, encoding: Encoding::UTF_8))
            @win = Numo::SFloat.zeros(OutputTap::SIZE / 2)
            @buf = Numo::SFloat.zeros(MAX_PERIOD + 1)
            @cycle = nil
            @n = 0
            @anchor = nil
            @gen = nil
            @hold = 0.0
            @low = 0
            @mm = [0.0, 0.0]
            @start = nil
          end

          def supported? = true

          # Why the oscillator itself isn't drawn ("frequency modulated").
          attr_reader :reason

          # The last cycle's start (absolute sample index, fractional), for
          # measuring how steady the picture is.
          attr_reader :start

          # One period at fundamental +f+ Hz (an SFloat), or nil before
          # enough samples; the last one again when the ring was busy.
          def cycle(f)
            return @cycle unless f.is_a?(Float) && f.finite? && f > 0
            p = @rate / f
            return @cycle if p < 2 || p > MAX_PERIOD
            n = p.round
            len = (p * 3).ceil + 2
            len = @win.size if len > @win.size
            base = @tap.read(@win, len) or return @cycle
            unless @gen == @tap.generation
              @gen = @tap.generation
              @anchor = nil
              @hold = 0.0
            end
            # (a start whose period ends half a period before the newest sample)
            desired = base + len - 1 - 1.5 * p
            pred = @anchor ? @anchor + ((desired - @anchor) / p).round * p : desired
            lo = (pred - p * 0.5 - base).floor
            lo = 1 if lo < 1
            hi = (pred + p * 0.5 - base).ceil
            top = len - 2 - n
            hi = top if hi > top
            best = nil
            bestd = 0.0
            win = @win
            i = lo
            while i <= hi
              a = win[i - 1]
              b = win[i]
              if a < 0.0 && b >= 0.0
                x = base + i - 1 + a / (a - b)
                d = (x - pred).abs
                if best.nil? || d < bestd
                  best = x
                  bestd = d
                end
              end
              i += 1
            end
            start = best || pred
            rel = start - base
            if rel < 0.0 || rel + p > len - 1
              rel = len - 1 - 1.5 * p
              start = base + rel
            end
            @anchor = start
            @start = start
            unless @n == n
              @n = n
              @cycle = @buf[0...n]
            end
            c = @cycle
            step = p / n
            j = 0
            while j < n
              pos = rel + j * step
              k = pos.floor
              a = win[k]
              c[j] = a + (win[k + 1] - a) * (pos - k)
              j += 1
            end
            Kernels.min_max(c, @mm)
            peak = -@mm[0] > @mm[1] ? -@mm[0] : @mm[1]
            hold_range(peak)
            c
          end

          # The amplitude range's half height: the peak rounded up to a step
          # of 1.5 dB, raised at once, lowered only after the peak stays
          # under 70 % of it for RANGE_FRAMES frames (a band-limited edge's
          # peak differs a little from period to period: a range following
          # it moved the whole picture by a dot every frame).
          def range = @hold

          RANGE_FRAMES = 30
          RANGE_STEP = 2**0.25

          private

          def hold_range(peak)
            peak = 1e-4 unless peak > 1e-4
            if peak > @hold
              @hold = RANGE_STEP**(Math.log(peak) / Math.log(RANGE_STEP)).ceil
              @low = 0
            elsif peak < @hold * 0.7
              @low += 1
              if @low >= RANGE_FRAMES
                @hold = RANGE_STEP**(Math.log(peak) / Math.log(RANGE_STEP)).ceil
                @low = 0
              end
            else
              @low = 0
            end
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
            return if n && draw_envelope(c, n, state)
            t = WaveView.target
            return super unless n && t && t.label == n.label && t.view.supported?
            feed_tap = WaveView.feed&.wave_tap
            vals = (state[:wave_vals] ||= Array.new(Tap::MAX, Float::NAN))
            got = feed_tap && feed_tap.read(t.watch, vals)
            return super unless got || state[:wave_data]
            pic = WaveView.picture(t, vals, n, c.w)
            return super unless pic
            @wave_live = true
            state[:wave_data] = pic.data
            w = c.w
            h = c.h
            return if w <= 0 || h <= 0
            c.clear
            c.text(0, 0, Label.fit(pic.title, w), :dim)
            if h > 1
              fg = MB::Term::Cells.pack(Theme.rgb(:key)) || -1
              Plot::Wave.draw(c.grid, pic.data, x: c.x, y: c.y + 1, w: w, h: h - 1, lo: pic.lo, hi: pic.hi, fg: fg,
                              mark: pic.mark, mark_fg: MB::Term::Cells.pack(Theme.rgb(:warn)) || -1)
            end
            nil
          end

          private

          # An envelope row (Plot::Panels::EnvelopeView's rendered trace,
          # kept per preview data) drawn by the wave kernel with the
          # playhead as its marker; true if it drew.
          def draw_envelope(c, n, state)
            d = n.params&.preview
            return false unless d.is_a?(Hash) && d[:kind] == :envelope
            tr = Plot::Panels::EnvelopeView.trace(d)
            unless state[:env_trace].equal?(tr)
              state[:env_trace] = tr
              state[:env_data] = Numo::SFloat.cast(tr.level)
              state[:env_range] = [[tr.level.min, 0.0].min, [tr.level.max, 1.0].max]
              state[:env_title] ||= String.new(capacity: 64, encoding: Encoding::UTF_8)
              state[:env_title_w] = nil
            end
            @playhead = !n.live.nil?
            @wave_live = @playhead # (a live pane while a note's playhead moves, as before)
            w = c.w
            h = c.h
            return true if w <= 0 || h <= 0
            live = n.live
            at = live && Plot::Panels::EnvelopeView.playhead(tr, live, elapsed_now(live) || live[:elapsed])
            mark = at && tr.total > 0 ? ((at / tr.total) * 2 * w).floor.clamp(0, 2 * w - 1) : -1
            title = state[:env_title]
            unless state[:env_title_w] == w
              state[:env_title_w] = w
              Label.fit(title.clear << tr.label.to_s << ' live', w)
            end
            c.clear
            c.text(0, 0, title, :dim)
            if h > 1
              lo, hi = state[:env_range]
              Plot::Wave.draw(c.grid, state[:env_data], x: c.x, y: c.y + 1, w: w, h: h - 1, lo: lo, hi: hi,
                              fg: MB::Term::Cells.pack(Theme.rgb(:key)) || -1, mark: mark, mark_fg: MB::Term::Cells.pack(Theme.rgb(:warn)) || -1)
            end
            true
          end
        end

        # The Picture of Target +t+ at values +vals+ (row +n+), drawn +w+
        # cells wide: the view's own Picture, changed in place (nothing
        # allocated while the values only move), or nil.
        def self.picture(t, vals, n, w = 0)
          v = t.view
          pic = v.picture
          title = pic.title
          case t.kind
          when :lfo
            f, wd, sc, ph = vals[0], vals[1], vals[2], vals[3]
            d = v.cycle(v.rate / LFO_POINTS, wd, sc) or return nil
            peak = v.peak > 1.0 ? v.peak : 1.0
            pic.data = d
            pic.lo = -peak
            pic.hi = peak
            pic.mark = ph.finite? && w > 0 ? ((ph % 1.0) * 2 * w).floor.clamp(0, 2 * w - 1) : -1
            title.clear << n.label << ' '
            f.finite? ? Label.hz(title, f.abs) : title << '?'
            title << ' live, now at '
            ph.finite? ? Label.fixed(title, ph % 1.0, 2) : title << '?'
          when :tone
            f, wd, sc = vals[0], vals[1], vals[2]
            d = v.cycle(f, wd, sc) or return nil
            peak = v.peak > 1.0 ? v.peak : 1.0
            peak = (peak * 4).ceil / 4.0 if peak > 1.0
            pic.data = d
            pic.lo = -peak
            pic.hi = peak
            pic.mark = -1
            title.clear << n.label << ' '
            Label.hz(title, f.abs) << ' live'
            Label.fixed(title << ' pw ', wd, 2) if wd.finite?
            Label.fixed(title << ' scan ', sc, 2) if sc.finite?
          when :four_pole, :svf, :biquad
            cut, second = vals[0], vals[1]
            pic.data = v.curve(cut, second, t.kind == :svf ? vals[2] : Float::NAN)
            pic.lo = v.lo
            pic.hi = v.hi
            pic.mark = -1
            title.clear << n.label << ' '
            Label.hz(title, cut.finite? ? cut : 0.0) << (t.kind == :four_pole ? ' reso ' : ' Q ')
            second.finite? ? Label.fixed(title, second, 2) : title << '?'
            title << ' live'
          when :voice
            f = Float::NAN
            i = 0
            while i < t.watch.length
              x = vals[i]
              f = x if x.is_a?(Float) && x.finite? && x > 0 && !(f <= x)
              i += 1
            end
            d = v.cycle(f) or return nil
            pic.data = d
            pic.lo = -v.range
            pic.hi = v.range
            pic.mark = -1
            title.clear << n.label << ' '
            title << v.reason << ': ' if v.reason
            title << 'voice out '
            f.finite? ? Label.hz(title, f) : title << '?'
            title << ' live'
          else
            return nil
          end
          pic
        end

        Panes::Preview.prepend(PreviewLive)
      end
    end
  end
end
