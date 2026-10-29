module MB
  module Sound
    module UI
      module Inspect
        # Sorts the nodes of a played graph into the sections a sound
        # designer looks for (sound-design-nav-1, from the classifier of
        # research-sound-design-nav; design/notes/sound_design_ui.md,
        # Sections): SOURCE (oscillators, samples, struck bodies, glide),
        # FILTER, AMP (drive and the voice's amp), MOD (LFOs and modulators
        # not tied to one section), FX (effects, post-amp filters, pans),
        # the Minimoog way: each envelope sits in the section it shapes (an
        # amp envelope in AMP, a filter envelope in FILTER, a pitch
        # envelope in SOURCE).  Plumbing (Tees, constants, knobs, arithmetic,
        # note and synth wiring, ...) is hidden and counted by reason.
        #
        # Reads only settings (#sources, #feedback_sources, #port_info,
        # #param_info, recipes, preview data), never samples, so Poll calls
        # it on the painter thread.
        #
        #     r = Inspect::Classify.call(Inspect.roots(input))
        #     r.rows        # Rows, in section order
        #     r.hidden      # { 'tees' => 40, ... }
        #     r.unfit       # nodes that fit no section (a guard spec keeps it empty)
        module Classify
          # One shown row: +section+ (one of SECTIONS), +label+ (DSL words:
          # "saw", "lp4", "highpass"), +what+ (a few words of role: "amp
          # env", "post-amp EQ", or nil), +dest+ (where a control row goes:
          # ["lp4 cutoff"]), +count+ (every copy: synth lanes, unison copies,
          # channels), +copies+ (the copies one voice has in one channel),
          # +channels+ (2 for nodes after a stereo mixer), +nodes+ (the
          # copies), +voice+ (a drum voice's name, or nil), +stage+ (signal
          # order from the source, for sorting), +knobs+ (knob readers read
          # only through hidden arithmetic that reach this row, as
          # [[param name, reader], ...]: see .attach_knobs).
          Row = Data.define(:section, :label, :what, :dest, :count, :copies, :channels, :nodes, :voice, :stage, :knobs)

          # The result of .call: +rows+, +hidden+ ({ reason => count }),
          # +plumbing+ ([[reason, node], ...] of the hidden nodes), +unfit+
          # (nodes in no section), +total+ (nodes walked), +lanes+ (synth
          # lanes).
          Result = Data.define(:rows, :hidden, :plumbing, :unfit, :total, :lanes) do
            def by_section = rows.group_by(&:section)
          end

          # Classes that are never shown (their settings are other nodes'
          # params), with the reason the hidden counts list them under.
          PLUMBING = {
            'GraphNode::Tee' => 'tees', 'GraphNode::Tee::Branch' => 'tees',
            'GraphNode::Constant' => 'constants', 'GraphNode::Knob' => 'knobs', 'GraphNode::Knob::Reader' => 'knobs',
            'GraphNode::Multiplier' => 'arithmetic', 'GraphNode::Mixer' => 'arithmetic', 'GraphNode::ProcNode' => 'arithmetic',
            'GraphNode::Silence' => 'sequencing', 'GraphNode::NodeSequence' => 'sequencing',
            'GraphNode::Ports::Port' => 'ports', 'Notes::EnvelopeInputs' => 'note plumbing', 'Notes::EnvelopeInputs::Port' => 'note plumbing',
            'Notes::Frequency' => 'note plumbing', 'Notes::Number' => 'note plumbing', 'Notes::Trigger' => 'note plumbing',
            'Notes::KeyTrigger' => 'note plumbing', 'Notes::NoteEnvelope::GmTime' => 'note plumbing', 'Notes::Choke' => 'note plumbing',
            'Notes::FadeIn' => 'note plumbing', 'Notes::Gate' => 'note plumbing', 'Notes::PitchMark' => 'note plumbing',
            'Notes::FlamMark' => 'note plumbing', 'Notes::Lift' => 'note plumbing',
            'MIDI::Stream' => 'MIDI', 'MIDI::ClipSource' => 'MIDI', 'MIDI::Allocator' => 'MIDI', 'MIDI::Allocator::Lane' => 'MIDI',
            'Synth' => 'synth wiring', 'Synth::Output' => 'synth wiring', 'GraphNode::ChannelMixer::Output' => 'multi-output wiring',
            'GraphNode::Reverb::ReverbOutput' => 'multi-output wiring', 'GraphNode::Dynamics::Output' => 'multi-output wiring',
            'GraphNode::Chorus::Tail' => 'multi-output wiring', 'GraphNode::MultitapDelay::DelayTap' => 'multi-output wiring',
            'GraphNode::FeedbackLoop::Variable' => 'multi-output wiring', 'Drums::Voice::Tap' => 'multi-output wiring',
            'Sequence::TempoNode' => 'tempo', 'SQ80::TimeScale' => 'tempo',
            'GraphNodeInput' => 'synth wiring', 'Drums::Kit' => 'synth wiring',
          }.freeze

          # Modulation sources with nothing to turn (shown as where a row's
          # param comes from, never as rows).
          CONTROLLERS = %w[
            Notes::Velocity Notes::Control Notes::Bend Notes::Aftertouch Notes::PolyPressure Notes::Pressure Notes::Resonance
          ].freeze

          ENVELOPES = %w[Envelope Notes::NoteEnvelope].freeze
          MODULATORS = %w[GraphNode::Drift GraphNode::SampleHold GraphNode::Dust GraphNode::Quantize].freeze
          OSCILLATORS = %w[Tone Notes::KeyedTone GraphNode::ChannelMixer::Unison GraphNode::SamplerVoice GraphNode::Grains].freeze
          FILTERS = %w[GraphNode::FourPole GraphNode::Formant GraphNode::DiodeLadder].freeze
          RESONATORS = %w[GraphNode::ModalResonator GraphNode::Resonator].freeze
          SHAPERS = %w[GraphNode::Shaper GraphNode::CurveShaper].freeze
          EFFECTS = %w[
            GraphNode::Reverb GraphNode::Chorus GraphNode::MultitapDelay GraphNode::FeedbackLoop GraphNode::Dynamics
            GraphNode::Dynamics::Crossover::Band GraphNode::Decimator GraphNode::Sounding GraphNode::Limiter
          ].freeze
          ARITHMETIC = %w[GraphNode::Multiplier GraphNode::Mixer GraphNode::ProcNode].freeze
          TRIGGERS = %w[Notes::Trigger Notes::KeyTrigger GraphNode::Dust].freeze
          # (always control signals, wherever they are)
          CONTROL = %w[
            Notes::Glide Notes::Frequency Notes::Number Notes::Trigger Notes::KeyTrigger Sequence::TempoNode SQ80::TimeScale
            Notes::Gate Notes::PitchMark Notes::FlamMark Notes::Lift
            GraphNode::Drift GraphNode::Constant GraphNode::Knob GraphNode::Knob::Reader
          ].freeze

          # DSL words for node classes without a recipe of their own.
          WORDS = {
            'GraphNode::FourPole' => 'lp4', 'GraphNode::DiodeLadder' => 'diode', 'Notes::NoteEnvelope' => 'env', 'Envelope' => 'env',
            'GraphNode::ChannelMixer::Unison' => 'unison', 'GraphNode::Reverb' => 'reverb', 'GraphNode::Chorus' => 'chorus',
            'GraphNode::Dynamics' => 'compress', 'GraphNode::Formant' => 'formant', 'GraphNode::ModalResonator' => 'resonate',
            'GraphNode::Resonator' => 'ping', 'Notes::Glide' => 'glide', 'GraphNode::Decimator' => 'decimate',
            'GraphNode::ChannelMixer::Pan' => 'pan', 'GraphNode::Drift' => 'drift', 'GraphNode::SampleHold' => 'sample_hold',
            'GraphNode::Dust' => 'dust', 'GraphNode::MultitapDelay' => 'multitap', 'GraphNode::FeedbackLoop' => 'feedback',
            'GraphNode::Sounding' => 'sounding', 'GraphNode::Quantize' => 'quantize', 'GraphNode::Limiter' => 'limit',
            'GraphNode::Dynamics::Crossover::Band' => 'bands', 'Drums::Repeats' => 'bursts', 'Drums::ChokeGate' => 'choke',
          }.freeze

          module_function

          # The class name without MB::Sound::.
          def short_class(n)
            n.class.name.to_s.delete_prefix('MB::Sound::')
          end

          # The recorded call's method name of +n+, or nil.
          def call_name(n)
            rec = n.instance_variable_defined?(:@graph_recipe) ? n.instance_variable_get(:@graph_recipe) : nil
            c = rec.respond_to?(:call) ? rec.call : nil
            c && (c.respond_to?(:written) && c.written || c.name)
          end

          def preview(n)
            n.respond_to?(:preview_data) ? (n.preview_data rescue nil) : nil
          end

          # The node a source really is: through Tee branches to the Tee's
          # input (only Tees: other multi-output nodes keep their outputs,
          # whose inputs differ per channel).
          def resolve(s)
            8.times do
              if s.is_a?(GraphNode::Tee::Branch) then s = s.original_source
              elsif s.is_a?(GraphNode::Tee) && s.respond_to?(:sources) then s = s.sources.values.first
              else break
              end
            end
            s
          rescue StandardError
            s
          end

          # +n+'s inputs as [[name, role, source], ...] (numbers left out).
          def ins(n)
            if n.respond_to?(:port_info)
              list = (n.port_info[:in] rescue [])
              return list.reject { |p| p[:source].is_a?(Numeric) || p[:source].nil? }.map { |p| [p[:name], p[:role], resolve(p[:source])] }
            end
            return [] unless n.respond_to?(:sources)
            (n.sources rescue {}).reject { |_, s| s.is_a?(Numeric) || s.nil? }.map { |name, s|
              [name, name.to_s.match?(GraphNode::Traversable::MAIN_INPUT) ? :main : :param, resolve(s)]
            }
          end

          def plumbing?(n) = PLUMBING.key?(short_class(n))
          def envelope?(n) = ENVELOPES.include?(short_class(n))
          def controller?(n) = CONTROLLERS.include?(short_class(n))
          def arithmetic?(n) = ARITHMETIC.include?(short_class(n))
          def lfo?(n) = %w[Tone GraphNode::Multiplier].include?(short_class(n)) && call_name(n) == :lfo

          # Nodes that are control signals wherever they are.
          def control?(n)
            envelope?(n) || controller?(n) || lfo?(n) || CONTROL.include?(short_class(n))
          end

          # The DSL word for +n+ (never a class name).
          def label(n)
            return n.graph_node_name.to_s if n.respond_to?(:named?) && n.named?
            d = preview(n)
            return d[:filter_type].to_s if d.is_a?(Hash) && d[:filter_type]
            return d[:mode].to_s if d.is_a?(Hash) && d[:mode]
            return base_word(n) if short_class(n) == 'Filter::SampleWrapper' && !%i[delay smooth].include?(call_name(n))
            cn = call_name(n)
            return cn.to_s if cn && cn.to_s.match?(/\A[a-z]/) && cn.to_s != 'constant'
            return n.wave_type.to_s if n.respond_to?(:wave_type) && n.wave_type
            WORDS[short_class(n)] || Inspect.snake(short_class(n).split('::').last)
          end

          # A wrapped filter's kind when it has no cookbook type ("comb").
          def base_word(n)
            f = n.instance_variable_defined?(:@base_filter) ? n.instance_variable_get(:@base_filter) : nil
            f ? Inspect.snake(f.class.name.split('::').last) : 'filter'
          end

          # Every node of graph +roots+: their #graph where they have one,
          # plus everything reachable through #sources and
          # #feedback_sources (ChannelMixers have no #graph), without
          # numbers.
          def walk(roots)
            seen = {}
            out = []
            stack = roots.flat_map { |r| [r, *(r.respond_to?(:graph) ? (r.graph rescue []) : [])] }
            until stack.empty?
              n = stack.pop
              next if n.nil? || n.is_a?(Numeric) || seen[n.__id__]
              seen[n.__id__] = true
              out << n
              (n.sources rescue {}).each_value { |x| stack << x } if n.respond_to?(:sources)
              (n.feedback_sources rescue {}).each_value { |x| stack << x } if n.respond_to?(:feedback_sources)
            end
            out
          end

          # Classifies graph +roots+ (Inspect.roots of a player's input).
          def call(roots)
            all = walk(roots)
            edges = {}
            all.each { |n| edges[n.__id__] = ins(n) }
            users = Hash.new { |h, k| h[k] = [] }
            all.each do |n|
              next if n.is_a?(GraphNode::Tee) || n.is_a?(GraphNode::Tee::Branch)
              edges[n.__id__].each { |name, role, s| users[s.__id__] << [n, name, role] }
            end
            edge = ->(n) { edges[n.__id__] ||= ins(n) }

            # Control-derived arithmetic: arithmetic whose inputs are all
            # control (velocity-scaled envelopes, `2 ** lfo`, `cut * lfo`).
            ctrl = {}
            arith = all.select { |n| arithmetic?(n) }
            loop do
              grew = false
              arith.each do |n|
                next if ctrl[n.__id__]
                e = edge.(n)
                next if e.empty? || !e.all? { |_, _, x| control?(x) || ctrl[x.__id__] }
                ctrl[n.__id__] = true
                grew = true
              end
              break unless grew
            end

            # The audio path: from the roots back through main, side, and
            # feedback inputs, never into control nodes.
            signal = {}
            depth = {}
            queue = roots.map { |r| [resolve(r), 0] }
            until queue.empty?
              n, d = queue.shift
              next if signal[n.__id__] || control?(n) || ctrl[n.__id__]
              signal[n.__id__] = n
              depth[n.__id__] = d
              edge.(n).each do |_name, role, s|
                next unless %i[main side feedback].include?(role)
                next if s.respond_to?(:port_type) && s.port_type == :notes
                queue << [s, d + 1]
              end
            end
            max = depth.values.max || 0
            stage = depth.transform_values { |d| max - d }

            # Amp stages (signal Multipliers fed by an envelope); the voice's
            # amp is the one nearest the output (others are a layer's level,
            # like a noise burst's envelope); post-amp nodes follow it.
            env_fed = ->(s) { envelope?(s) || ctrl[s.__id__] && feeds_through_arith?(s, edges) { |x| envelope?(x) } }
            amp_ids = signal.values.select { |n| short_class(n) == 'GraphNode::Multiplier' && edge.(n).any? { |_, _, s| env_fed.(s) } }.map(&:__id__)
            main_depth = amp_ids.map { |id| depth[id] }.compact.min
            main_amps = amp_ids.select { |id| depth[id] == main_depth }
            post = {}
            stack = main_amps.dup
            until stack.empty?
              id = stack.pop
              users[id].each do |u, _, _|
                next unless signal[u.__id__] && !post[u.__id__]
                post[u.__id__] = true
                stack << u.__id__
              end
            end

            voice_of = drum_voices(all)

            # Nodes after a stereo mixer (unison, pan) run once per channel.
            chan = {}
            all.each do |n|
              next unless n.is_a?(GraphNode::ChannelMixer) && n.respond_to?(:outputs) && ((n.outputs.length rescue 1) > 1)
              stack = [n.__id__]
              until stack.empty?
                id = stack.pop
                users[id].each do |u, _, _|
                  next if chan[u.__id__]
                  chan[u.__id__] = true
                  stack << u.__id__
                end
              end
            end

            hidden = Hash.new(0)
            plumbing = []
            unfit = []
            found = [] # [node, section, what]
            hide = ->(n, why) { hidden[why] += 1; plumbing << [why, n] }
            all.each do |n|
              sc = short_class(n)
              (hide.(n, 'drum voices (v V picks one)'); next) if sc == 'Drums::Voice'
              sig = signal.key?(n.__id__)
              sec, what =
                if sc == 'Drums::Repeats' then [:amp, 'bursts']
                elsif sc == 'Drums::ChokeGate' then [:amp, 'choke']
                elsif lfo?(n) && sc == 'GraphNode::Multiplier' then [:mod, 'lfo']
                elsif sc == 'Tone' && !sig && lfo_internal?(n, users) then hide.(n, 'lfo internals'); next
                elsif plumbing?(n) then hide.(n, PLUMBING[sc]); next
                elsif controller?(n) then hide.(n, 'controllers'); next
                elsif envelope?(n) then [:env, nil]
                elsif lfo?(n) || sc == 'GraphNode::Drift' then [:mod, 'lfo']
                elsif MODULATORS.include?(sc) then sig ? (sc == 'GraphNode::Dust' ? [:source, nil] : [:fx, 'crush']) : [:mod, nil]
                elsif sc == 'Notes::Glide' then [:source, 'pitch']
                elsif OSCILLATORS.include?(sc)
                  if sig then [:source, nil]
                  elsif sc == 'Notes::KeyedTone' then [:source, 'FM operator']
                  else [:mod, 'lfo']
                  end
                elsif RESONATORS.include?(sc) then struck?(n, edges) ? [:source, 'struck body'] : [:filter, 'resonator']
                elsif FILTERS.include?(sc) then post[n.__id__] ? [:fx, 'post-amp'] : [:filter, nil]
                elsif sc == 'Filter::SampleWrapper'
                  d = preview(n)
                  cn = call_name(n)
                  if d.is_a?(Hash) && d[:filter_type] then post[n.__id__] ? [:fx, 'post-amp EQ'] : [:filter, nil]
                  elsif cn == :delay then [:fx, 'delay']
                  elsif cn == :smooth then hide.(n, 'smoothing'); next
                  elsif base_word(n) == 'delay' then [:fx, 'delay']
                  else post[n.__id__] ? [:fx, 'post-amp'] : [:filter, nil]
                  end
                elsif SHAPERS.include?(sc) && !sig then hide.(n, 'control shaping'); next
                elsif SHAPERS.include?(sc) then post[n.__id__] ? [:fx, 'drive'] : [:amp, 'drive']
                elsif EFFECTS.include?(sc) then [:fx, nil]
                elsif n.is_a?(GraphNode::ChannelMixer) then [:fx, 'out']
                else [:other, nil]
                end
              found << [n, sec, what]
              unfit << n if sec == :other
            end

            # Envelopes and modulators: where they go; envelopes join the
            # section of what they shape
            section_of = {}
            found.each { |n, sec, _| section_of[n.__id__] = sec unless %i[env mod].include?(sec) }
            found.map! do |n, sec, what|
              next [n, sec, what, []] unless %i[env mod].include?(sec)
              dests = destinations(n, users, signal, main_amps, amp_ids)
              texts = dests.map(&:first).uniq.first(3)
              if sec == :env
                what ||= env_role(texts)
                sec = env_section(what, dests, section_of)
              end
              [n, sec, what, texts]
            end

            # Copies with the same settings are one row
            groups = found.group_by { |n, sec, what, dest| [sec, label(n), what, dest, voice_of[n.__id__], n.class, settings_sig(n)] }
            lanes = [all.count { |n| short_class(n) == 'MIDI::Allocator::Lane' }, 1].max
            rows = groups.map { |(sec, lab, what, dest, voice), list|
              nodes = list.map(&:first)
              stereo = nodes.length.even? && nodes.all? { |n| chan[n.__id__] }
              channels = stereo ? 2 : 1
              copies = nodes.length
              copies /= lanes if lanes > 1 && copies % lanes == 0
              copies /= channels if channels > 1 && copies % channels == 0
              Row.new(section: sec, label: lab.freeze, what: what&.freeze, dest: dest.map(&:freeze).freeze, count: nodes.length, copies: copies,
                      channels: channels, nodes: nodes.freeze, voice: voice, stage: nodes.map { |n| stage[n.__id__] || 999 }.min, knobs: [].freeze)
            }
            order = SECTIONS + [:other]
            rows.sort_by!.with_index { |r, i| [r.voice.to_s, order.index(r.section) || 99, r.stage, i] }
            rows = attach_knobs(all, users, rows)
            Result.new(rows: rows.freeze, hidden: hidden.freeze, plumbing: plumbing.freeze, unfit: unfit.freeze, total: all.length, lanes: lanes)
          end

          # True if Tone +n+ only feeds `lfo` nodes (an LFO's inner tone).
          def lfo_internal?(n, users)
            list = users[n.__id__].reject { |u, _, _| u.is_a?(GraphNode::Tee) || u.is_a?(GraphNode::Tee::Branch) }
            !list.empty? && list.all? { |u, _, _| lfo?(u) && short_class(u) == 'GraphNode::Multiplier' }
          end

          # The section an envelope of role +what+ going to +dests+ joins
          # (sound-design-nav-1, the maintainer's "Fewer, envelopes inside").
          def env_section(what, dests, section_of)
            case what
            when 'amp env', 'level env', 'bursts' then :amp
            when 'filter env' then :filter
            when 'pitch env', 'layer env' then :source
            else
              dests.each do |_, node|
                sec = node && section_of[node.__id__]
                return sec if sec && sec != :other
              end
              :mod
            end
          end

          # True if +s+ is (or is reached through a few arithmetic nodes
          # from) a node for which the block is true.
          def feeds_through_arith?(s, edges, depth = 3, &blk)
            return true if blk.call(s)
            return false if depth == 0 || !arithmetic?(s)
            (edges[s.__id__] || ins(s)).any? { |_, _, x| feeds_through_arith?(x, edges, depth - 1, &blk) }
          end

          # Where control node +n+ goes: [[text, node], ...] for its first
          # non-arithmetic users ("lp4 cutoff", "amp", "pitch"; the node is
          # the user, nil for amp and pitch).
          def destinations(n, users, signal, main_amps, amp_ids)
            out = []
            seen = {}
            queue = [n]
            until queue.empty? || out.length >= 4
              m = queue.shift
              next if seen[m.__id__]
              seen[m.__id__] = true
              users[m.__id__].each do |u, port, _role|
                if main_amps.include?(u.__id__) then out << ['amp', nil]
                elsif amp_ids.include?(u.__id__) then out << ["level (#{layer_of(u, signal)})", u]
                elsif signal[u.__id__] && arithmetic?(u) then out << ['level', u]
                elsif short_class(u) == 'Notes::Frequency' || u.is_a?(Notes::Glide) || (u.is_a?(Notes::Number) && short_class(u) == 'Notes::Number') then out << ['pitch', nil]
                elsif plumbing?(u) || !signal[u.__id__] && (SHAPERS.include?(short_class(u)) || MODULATORS.include?(short_class(u))) then queue << u
                else out << ["#{label(u)} #{port.to_s.sub(/_\d+\z/, '')}", u]
                end
              end
            end
            out
          end

          def env_role(dest)
            return 'amp env' if dest.include?('amp')
            return 'layer env' if dest.any? { |d| d.start_with?('level (') }
            return 'filter env' if dest.any? { |d| d.match?(/\A(lp4|diode|lowpass|highpass|bandpass|notch|formant|filter|peak)/) }
            return 'pitch env' if dest.include?('pitch')
            return 'level env' if dest.include?('level')
            dest.empty? ? 'unused' : 'mod env'
          end

          # The oscillator a layer's level stage +u+ scales (its signal
          # input, through filters and arithmetic): "noise", "sine".
          def layer_of(u, signal)
            queue = [u]
            seen = {}
            8.times do
              nxt = []
              queue.each do |m|
                next if seen[m.__id__]
                seen[m.__id__] = true
                return label(m) if OSCILLATORS.include?(short_class(m)) && !m.equal?(u)
                ins(m).each { |_, role, s| nxt << s if role == :main && signal[s.__id__] }
              end
              queue = nxt
            end
            'a layer'
          end

          # True if resonator +n+ is struck (fed a trigger or impulses, not
          # audio from an oscillator).
          def struck?(n, edges)
            (edges[n.__id__] || ins(n)).any? { |_, role, s|
              role == :main && (TRIGGERS.include?(short_class(s)) || feeds_through_arith?(s, edges) { |x| TRIGGERS.include?(short_class(x)) })
            }
          end

          # The drum voice each node belongs to ({ node id => name }): the
          # nodes of each Drums::Voice's graph.
          def drum_voices(all)
            out = {}
            all.each do |v|
              next unless short_class(v) == 'Drums::Voice'
              name = v.respond_to?(:name) ? v.name : :voice
              g = v.respond_to?(:graph) ? v.graph : nil
              next unless g
              [g].flatten.each { |x| (x.respond_to?(:graph) ? x.graph : [x]).each { |y| out[y.__id__] ||= name } }
            end
            out
          end

          # What tells copies apart (settings, not identity).
          def settings_sig(n)
            info = n.respond_to?(:param_info) ? (n.param_info rescue {}) : {}
            [info.map { |k, v| [k, v.value, v.label] }, preview(n)].hash
          end

          # Knobs read only through hidden arithmetic (an oscillator mix, a
          # drive gain, an envelope amount) join the row their signal
          # reaches: forward from the reader to the first shown node; through
          # a param port, that row; through a shaper's main input, the
          # shaper (a gain before it is its drive); through another node's
          # main input, the SOURCE row feeding it (a mix of oscillators).
          # Knobs a row's own params read are left to the row's params.
          def attach_knobs(all, users, rows)
            row_of = {}
            rows.each_with_index { |r, i| r.nodes.each { |n| row_of[n.__id__] = i } }
            own = rows.map { |r| Inspect.knobs_read(r.nodes.first) rescue [] }
            extra = Hash.new { |h, k| h[k] = [] }
            taken = {}
            all.each do |rd|
              next unless rd.is_a?(GraphNode::Knob::Reader)
              name = rd.knob.name
              next if name.nil? || taken[name]
              target = nil
              seen = {}
              queue = [rd]
              until queue.empty? || target
                m = queue.shift
                next if seen[m.__id__]
                seen[m.__id__] = true
                users[m.__id__].each do |u, _port, role|
                  next unless (i = row_of[u.__id__])
                  target = if role != :main || SHAPERS.include?(short_class(u)) then i
                           else upstream_source(u, row_of, rows) || i
                           end
                  break
                end
                users[m.__id__].each { |u, _, _| queue << u if !row_of[u.__id__] } unless target
              end
              taken[name] = true
              next unless target
              next if own[target].include?(name) || rows.each_with_index.any? { |r, i| i != target && own[i].include?(name) && r.voice == rows[target].voice }
              extra[target] << [name.to_s.split('/').last.to_sym, rd]
            end
            rows.each_with_index.map { |r, i| extra.key?(i) ? r.with(knobs: extra[i].uniq(&:first).freeze) : r }
          end

          # The first SOURCE row feeding node +u+'s main input (backward
          # along main edges), or nil.
          def upstream_source(u, row_of, rows)
            seen = {}
            queue = ins(u).select { |_, role, _| role == :main }.map(&:last)
            until queue.empty?
              m = queue.shift
              next if seen[m.__id__]
              seen[m.__id__] = true
              i = row_of[m.__id__]
              return i if i && rows[i].section == :source
              ins(m).each { |_, role, s| queue << s if role == :main }
            end
            nil
          end
        end
      end
    end
  end
end
