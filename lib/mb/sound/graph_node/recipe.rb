require 'set'

module MB
  module Sound
    module GraphNode
      # Recipes: the DSL calls that built a graph, recorded as the user's code
      # made them, so a graph can print itself back as Ruby (see #to_ruby and
      # Recipe::RubyWriter; design notes in design/notes/graph_io.md).
      #
      # Generated wrappers prepended to the DSL surface (the GraphNode
      # *Methods modules, Tone, Pitch, NotePitch, Notes, Channels, clips,
      # Numeric#constant, MB::Sound's top-level graph methods, and +.new+ of
      # node classes) record each outermost call: a thread-local depth counter
      # means DSL methods calling other DSL methods inside the library leave
      # no records.  A call returning a new object stores a Call on that
      # object (one per block scope, for objects memoized across synth
      # lanes); a call returning its receiver (Tone#sine, #at, #named, ...)
      # appends to the object's configuration list.
      #
      # Build blocks (synth lanes, feedback loops, delay inserts, unison
      # layers; BUILD_BLOCKS) run at depth 0 again, as user code, and each
      # call of the block is an Invocation with its arguments, result, and
      # local variable names (read from the Binding of the block's frame,
      # taken at its first recorded call, once it returns; see
      # #trace_locals).  Runtime blocks (procs, spies, schedules) are never
      # wrapped; they print as their own source text.
      #
      # Recording is always on (MB_SOUND_RECIPES=0 or Recipe.enabled = false
      # turns it off); it costs a little graph build time and nothing while
      # sampling.
      module Recipe
        # One recorded DSL call.  +block_kind+ is :build or :runtime (or nil
        # without a block); +invocations+ the build block's calls; +scope+ the
        # Invocation the call was made in (nil at the top level); +seq+ the
        # call's order (when it returned); +seeds+ seeds drawn from
        # MB::Sound.next_seed during the call; +lane+ the synth lane
        # [index, count] the call was made in, :seeded inside another
        # MB::Sound.with_seed block, or nil (see Recipe.lane).
        Call = Struct.new(:receiver, :name, :args, :kwargs, :block, :block_kind, :invocations, :scope, :seq, :seeds, :lane, :statements)

        # One call of a recorded build block: its arguments, result, the
        # block's local variables when it returned, whether anything inside
        # drew a random seed, and calls made for their effect on a block
        # argument (a delay insert pipeline's d.fb { } and d.wet { }).
        # +frame+ is internal: while the block runs, the block's
        # RubyVM::InstructionSequence until its frame's Binding is taken
        # (then the Binding, or false if it can't be found); nil afterwards
        # (see Recipe.trace_locals).
        Invocation = Struct.new(:args, :result, :locals, :seeded, :statements, :call, :frame)

        # The recipe of one object: the Call that made it (+call+), calls
        # that configured it afterwards (+config+), and Calls that returned
        # it again in other block scopes (+scoped+, e.g. a channel-wide
        # controller shared by every synth lane).  Not copied by Marshal
        # (filter objects are Marshal-copied per channel).
        class Record
          attr_accessor :owner, :call, :config, :scoped

          def initialize(owner, call)
            @owner = owner
            @call = call
            @config = nil
            @scoped = nil
          end

          def marshal_dump
            nil
          end

          def marshal_load(_)
            @owner = nil
          end

          def inspect
            "#<Recipe::Record #{@call&.name}#{" +#{@config.length} config" if @config}>"
          end
        end

        # Thread-local recording state.  +drawn+ is a seed the next
        # outermost call is given that was drawn when its graph was saved
        # (see #given_drawn_seed).
        State = Struct.new(:depth, :current, :scopes, :seeded, :drawn)

        # Methods that take build blocks (run while the graph is built, their
        # nodes part of the recipe), by name.  Every other recorded method's
        # block is a runtime block.
        BUILD_BLOCKS = Set[
          :synth, :feedback, :fb, :delay, :feedback_delay, :unison, :swarm, :oversample, :new, :map_notes, :bands, :multiband,
          :fill, # Kit#fill { grid(...) }
          :blend, # sig.blend(0.3) { |s| fx }
          :sampler, # clip.sampler(brk) { |v, s| ... }, Instrument#sampler, MB::Sound.sampler
          # Rack constructors (MB::Sound::RackMethods): their blocks build
          # each application's graph.  The constructors aren't recorded
          # (a Rack is a value that prints itself, Rack#to_ruby); an
          # application is (`src.then(&rack)`, see Rack#call), with this
          # block as its build block, and documents load them as build blocks
          :rack, :mrack, :note_rack, :irack, :instrument_rack, :arack, :audio_rack, :lrack, :amrack, :listener_rack,
          :modrack, :mod_rack,
        ].freeze

        # Recorded names that only raise the depth (the call itself isn't
        # noted; e.g. #coerce makes a Constant for `0.5 * node`, printed as the
        # number).
        SILENT = Set[:coerce].freeze

        # Methods on bundles that hand out channels: they note each channel
        # of a recorded bundle as bundle[i] (unless the channel has its own
        # recipe) and run at the caller's depth, so blocks given to #map and
        # #each stay user code.
        ELEMENT_ACCESS = [
          :[], :left, :right, :first, :last, :to_a, :to_ary, :outputs, :each, :each_with_index, :map, :each_slice, :zip,
        ].freeze

        # Public DSL methods that aren't recorded, by class or module name,
        # with the reason (the guard spec requires every public method of
        # the recorded surface to be recorded or listed here).
        EXEMPT = {
          'MB::Sound::GraphNode' => {
            get_sampler: 'plumbing: branches a node for another consumer',
            tee: 'plumbing: branches a node',
            as_input: 'plumbing: wraps a node as an input stream',
            multi_sample: 'samples several outputs (not a builder)',
            spy: 'runtime block for debugging', debug: 'debug output', clear_spies: 'debugging',
            samples: 'a Length value (Numeric-like), printed as a value',
            seconds: 'a Length value, printed as a value',
            cycles: 'a Phase value (cycles), printed as a value', cyc: 'alias of cycles',
            radians: 'a Phase value, printed as a value', rad: 'alias of radians',
          },
        }.freeze

        # Aliases recorded under their official name, so recipes and saved
        # documents print the official name whichever one the code used
        # (maintainer, 2026-10-17: saved files use the official name unless
        # it reads drastically different).  Other aliases print as written.
        PRINT_AS = {
          for: :until,
        }.freeze

        @enabled = ENV['MB_SOUND_RECIPES'] != '0'
        # How build block locals are read (see #trace_locals): :frame (the
        # block frame's Binding through FastRecipe, the default) or :trace
        # (a TracePoint, the old way; MB_SOUND_RECIPE_LOCALS=trace).
        @locals_mode = ENV['MB_SOUND_RECIPE_LOCALS'] == 'trace' ? :trace : :frame
        @block_iseqs = ObjectSpace::WeakKeyMap.new
        @seq = 0
        @wrapped = Hash.new { |h, k| h[k] = Set.new }

        class << self
          # How build block locals are read: :frame (default) or :trace (see
          # #trace_locals).
          attr_reader :locals_mode

          def locals_mode=(mode)
            raise ArgumentError, "Recipe.locals_mode must be :frame or :trace (got #{mode.inspect})" unless [:frame, :trace].include?(mode)
            @locals_mode = mode
          end

          # Whether calls are recorded (MB_SOUND_RECIPES=0 turns it off).
          attr_accessor :enabled

          # Recorded names by target (class, module, or :sound, :numeric,
          # :array), for the guard spec and later importers.
          attr_reader :wrapped

          # The thread's recording state.
          def state
            Thread.current[:mb_sound_recipe] ||= State.new(0, nil, [], 0)
          end

          # The innermost build block Invocation running on this thread, or
          # nil at the top level.
          def scope
            state.scopes.last
          end

          # The recipe Record of +obj+, or nil (also for records copied from
          # another object by #dup).
          def record_of(obj)
            return nil unless obj.instance_variable_defined?(:@graph_recipe)
            rec = obj.instance_variable_get(:@graph_recipe)
            rec&.owner.equal?(obj) ? rec : nil
          end

          # The Call that made +obj+ as seen from block scope +scope+ (the
          # scope's own Call for memoized objects returned in several
          # scopes), or nil.
          def call_of(obj, scope = nil)
            rec = record_of(obj)
            return nil unless rec
            return rec.scoped[scope] if rec.scoped&.key?(scope)
            rec.call
          end

          # Calls that configured +obj+ after it was made (Tone#at, #named...).
          def config_of(obj)
            record_of(obj)&.config || []
          end

          # Runs the block without recording the calls it makes (as if a
          # recorded call were running), e.g. a pending unison built from
          # its recorded stand-in (see Unison::Spec#built).
          def quietly
            st = state
            st.depth += 1
            begin
              yield
            ensure
              st.depth -= 1
            end
          end

          # True while calls are recorded (MB_SOUND_RECIPES isn't 0).
          def enabled?
            @enabled
          end

          # Gives +to+ the recipe of +from+ (an object standing in for it,
          # e.g. a blockless unison and the unison built for it later), so
          # graphs reading +to+ print it as +from+ was made.
          def share_record(from, to)
            rec = record_of(from)
            return if rec.nil? || to.frozen? || record_of(to)

            copy = Record.new(to, rec.call)
            copy.config = rec.config&.dup
            copy.scoped = rec.scoped&.dup
            to.instance_variable_set(:@graph_recipe, copy)
          end

          # True for objects that recipes are about.
          def graph_object?(obj)
            obj.is_a?(GraphNode) || obj.is_a?(Channels) || obj.is_a?(MB::Sound::Notes) ||
              obj.is_a?(MB::Sound::Filter) || obj.is_a?(MB::Sound::Sequence::Clip) || obj.is_a?(MultiOutput) ||
              obj.is_a?(MB::Sound::Sequence::Kit) || obj.is_a?(MB::Sound::Wavetable::KeyMap)
          end

          def next_seq
            @seq += 1
          end

          # Runs a recorded method (see the module description).  Yields the
          # block to pass on (wrapped for build blocks).  +kind+ overrides
          # BUILD_BLOCKS for the block (:build for a Rack application, whose
          # block is the rack's; see Rack#call).
          def call(receiver, name, args, kwargs, block, kind: nil)
            st = state
            return yield(block) if st.depth > 0 || !@enabled
            take_frame(st.scopes.last)
            name = PRINT_AS.fetch(name, name)

            if SILENT.include?(name)
              st.depth += 1
              begin
                return yield(block)
              ensure
                st.depth -= 1
              end
            end

            # A seed drawn when a document was saved, given back by its
            # loader: recorded as drawn (not in kwargs), so the graph saves
            # it as drawn again
            drawn = st.drawn
            st.drawn = nil
            seeds = nil
            if drawn && kwargs[:seed] == drawn
              kwargs = kwargs.except(:seed)
              seeds = [drawn]
            end

            kind = block && (kind || (BUILD_BLOCKS.include?(name) ? :build : :runtime))
            call = Call.new(receiver, name, args, kwargs, block, kind, nil, st.scopes.last, 0, seeds, lane(st))
            pass = kind == :build ? wrap_block(block, call) : block

            st.depth += 1
            old_current = st.current
            st.current = call
            result = begin
              yield(pass)
            ensure
              st.depth -= 1
              st.current = old_current
            end

            call.seq = next_seq
            note(receiver, call, result)
            note_implied_ring(result, call) if result.is_a?(Mixer)
            result
          end

          # A sum made where sums end with their first input (see
          # Mixer#ring_implied?) prints as `(a + b).ring(:first)`, so
          # documents saved from it keep the ending; sums directly inside
          # it drop theirs (ring applies to them too: `(a + b + c)
          # .ring(:first)`).  An explicit #ring replaces it.
          def note_implied_ring(mixer, call)
            rec = record_of(mixer)
            if call.name == :ring
              rec&.config&.delete(mixer.implied_ring_call) if mixer.implied_ring_call
              mixer.implied_ring_call = nil
              return
            end
            return unless rec && rec.call.equal?(call) && mixer.ring_implied?

            ring = Call.new(mixer, :ring, [:first], {}, nil, nil, nil, call.scope, next_seq, nil, nil)
            (rec.config ||= []) << ring
            mixer.implied_ring_call = ring
            mixer.summands.each do |s|
              next unless s.is_a?(Mixer) && s.implied_ring_call
              record_of(s)&.config&.delete(s.implied_ring_call)
              s.implied_ring_call = nil
            end
          end

          # Records +call+ on +result+ (see the module description).
          def note(receiver, call, result)
            return unless (graph_object?(result) || result.is_a?(MB::Sound::Wavetable)) && !result.frozen?

            rec = record_of(result)
            if result.equal?(receiver)
              # Configuration of an existing object; Pitches are values, so
              # a Pitch returning itself isn't configured
              return if result.is_a?(MB::Sound::Pitch) && !result.is_a?(MB::Sound::Notes::NotePitch)

              rec ||= result.instance_variable_set(:@graph_recipe, Record.new(result, nil))
              (rec.config ||= []) << call
            elsif rec.nil? || rec.call.nil?
              if rec
                rec.call = call
              else
                result.instance_variable_set(:@graph_recipe, Record.new(result, call))
              end
            elsif rec.call.scope != call.scope
              (rec.scoped ||= {}.compare_by_identity)[call.scope] ||= call
            end
          end

          # Notes each channel of a recorded bundle +bundle+ as bundle[i]
          # (see ELEMENT_ACCESS).
          def note_elements(bundle)
            return unless @enabled && state.depth == 0 && record_of(bundle)
            take_frame(scope)

            outs = bundle.is_a?(Channels) ? bundle.instance_variable_get(:@outputs) : bundle.outputs
            outs.each_with_index do |o, idx|
              next if record_of(o) || o.frozen?
              call = Call.new(bundle, :[], [idx], {}, nil, nil, nil, scope, next_seq, nil, nil)
              o.instance_variable_set(:@graph_recipe, Record.new(o, call))
            end
          end

          # Notes each row clip of recorded Kit +kit+ (its +rows+ Hash) as
          # kit[:row], so clips taken with kit.rows print that way.
          def note_rows(kit, rows)
            return unless @enabled && state.depth == 0 && record_of(kit)
            take_frame(scope)

            rows.each do |name, clip|
              next if record_of(clip) || clip.frozen?
              call = Call.new(kit, :[], [name], {}, nil, nil, nil, scope, next_seq, nil, nil)
              clip.instance_variable_set(:@graph_recipe, Record.new(clip, call))
            end
          end

          # The synth lane [index, count] calls are made in, :seeded inside
          # another MB::Sound.with_seed block (unison copies, drum voices:
          # their seeds derive from the parent's), or nil.
          def lane(st = state)
            MB::Sound::Synth.current_lane || (st.seeded > 0 ? :seeded : nil)
          end

          # Runs the block (which makes one recorded call given +seed:
          # seed+, e.g. a graph document's loader) so that call records
          # +seed+ as a seed it drew rather than one it was given: the
          # graph's recipe then prints it as drawn (drawn_seed(N) in graph
          # documents), and GraphIO.load(seeds: :fresh) redraws it.
          def given_drawn_seed(seed)
            st = state
            st.drawn = seed
            yield
          ensure
            st.drawn = nil
          end

          # Called by MB::Sound.next_seed: remembers the seed on the call
          # being recorded, and marks the build block invocation that drew it.
          def drew_seed(seed)
            st = state
            # Seeds drawn inside MB::Sound.with_seed derive from its seed, so
            # a call made outside it (e.g. a top-level unison whose copies
            # draw) doesn't keep them.  Calls made inside it (lane set) do:
            # they're never printed (see #drawn_seed), but they keep
            # seed-drawing nodes in creation order (RubyWriter#seeded_key).
            st.current.seeds = (st.current.seeds || []) << seed if st.current && (st.seeded == 0 || st.current.lane)
            st.scopes.last&.seeded = true
          end

          # Records a call made for its effect on a block argument (e.g. a
          # delay insert pipeline's d.fb { }) in the current block scope,
          # wrapping its build block.  Returns the block to keep.
          def statement(receiver, name, block)
            st = state
            inv = st.scopes.last
            return block unless @enabled && inv
            take_frame(inv)

            call = Call.new(receiver, name, [], {}, block, :build, nil, inv, next_seq, nil, lane(st))
            (inv.statements ||= []) << call
            wrap_block(block, call)
          end

          # Wraps a build block so each call of it runs at depth 0 and records
          # an Invocation on +call+.
          def wrap_block(block, call)
            wrapped = proc do |*bargs, **kw|
              # Keyword arguments (a rack's extra ports) follow the
              # positional ones in the invocation's args
              inv = Invocation.new(kw.empty? ? bargs : bargs + kw.values, nil, {}, false, nil, call)
              (call.invocations ||= []) << inv
              st = Recipe.state
              saved = [st.depth, st.current]
              st.depth = 0
              st.current = nil
              st.scopes.push(inv)
              begin
                inv.result = Recipe.trace_locals(block, inv) {
                  kw.empty? ? block.call(*bargs) : block.call(*bargs, **kw)
                }
              ensure
                st.scopes.pop
                st.depth, st.current = saved
              end
            end
            wrapped.define_singleton_method(:arity) { block.arity }
            wrapped.define_singleton_method(:parameters) { |**kw| block.parameters(**kw) }
            wrapped.define_singleton_method(:lambda?) { block.lambda? }
            wrapped.define_singleton_method(:source_location) { block.source_location }
            wrapped
          end

          # Runs the block, storing +block+'s local variables (as of its
          # last return) in +inv+'s locals.
          #
          # By default (locals_mode :frame) the first recorded call made
          # inside the block takes the Binding of the block's frame
          # (FastRecipe.frame_binding, see #take_frame), and the locals are
          # read from it after the block returns (a Binding shares its
          # frame's environment, so it sees their final values).  The old
          # way (:trace), a TracePoint(:b_return) targeted at the block,
          # makes YJIT discard all of its compiled code whenever it is
          # enabled, so each graph built while something plays made the
          # render thread recompile everything (50-120 ms buffers after
          # each scene change; scene-build branch, 2026-10-12).  The two
          # differ only for locals of blocks and lambdas nested inside a
          # build block, which the TracePoint also saw (it fired at their
          # returns too) and the frame doesn't: of the 28 synth and effect
          # scripts, only wavetable_bass.rb printed differently (a value
          # passed to a `portamento = ->(pitch) { }` lambda was a `pitch`
          # variable, now a chain).
          def trace_locals(block, inv, &run)
            if block.respond_to?(:graph_io_locals)
              # A block loaded from a graph document (GraphIO::Loader) keeps
              # the document's locals itself
              result = run.call
              block.graph_io_locals.each { |k, v| inv.locals[k] = v }
              return result
            end

            return trace_locals_tracepoint(block, inv, &run) if @locals_mode == :trace

            iseq = block_iseq(block)
            return run.call unless iseq

            inv.frame = iseq
            begin
              run.call
            ensure
              b = inv.frame
              inv.frame = nil
              b.local_variables.each { |v| inv.locals[v] = b.local_variable_get(v) } if b.is_a?(Binding)
            end
          end

          # The old way of reading build block locals (see #trace_locals).
          def trace_locals_tracepoint(block, inv, &run)
            tp = TracePoint.new(:b_return) { |t|
              b = t.binding
              b.local_variables.each { |v| inv.locals[v] = b.local_variable_get(v) }
            }
            begin
              tp.enable(target: block, &run)
            rescue ArgumentError
              # Not traceable (e.g. a block made from a Method): no names
              run.call
            end
          end

          # Takes the Binding of the frame of the build block that +inv+
          # (an Invocation, or nil) is a call of, if not taken yet (see
          # #trace_locals).  Called by the recorder for calls made at depth
          # 0, i.e. by the user's code in the block.
          def take_frame(inv)
            return unless inv && (iseq = inv.frame).is_a?(RubyVM::InstructionSequence)
            inv.frame = MB::Sound::FastRecipe.frame_binding(iseq) || false
          end

          # The RubyVM::InstructionSequence of +block+ if it is a block
          # written in Ruby (not a Method or Symbol proc), else nil
          # (cached per block body).
          def block_iseq(block)
            iseq = RubyVM::InstructionSequence.of(block) rescue nil
            return nil unless iseq
            kind = @block_iseqs[iseq]
            @block_iseqs[iseq] = kind = (iseq.to_a[9] == :block) if kind.nil?
            kind ? iseq : nil
          end

          # Prepends recorders for +names+ to +target+ (a class or module).
          # +key+ files the names for #wrapped.
          def record(target, names, key: target)
            names = names.map(&:to_sym) - @wrapped[key].to_a
            return if names.empty?

            mod = Module.new
            # Aliases share one recorder (so instance_method(:alias) stays
            # equal to the original); __callee__ is the name the code used
            groups = names.group_by { |name|
              um = target.instance_method(name) rescue nil
              um ? [um.owner, um.original_name] : name
            }
            groups.each_value do |(first, *aliases)|
              if target <= MB::Sound::Sequence::Kit && first == :rows
                # kit.rows hands out the row clips: they print as kit[:row]
                mod.define_method(first) do |*args, **kwargs, &block|
                  super(*args, **kwargs, &block).tap { |rows| Recipe.note_rows(self, rows) }
                end
              elsif target <= Channels && ([first] + aliases).any? { |n| ELEMENT_ACCESS.include?(n) }
                mod.define_method(first) do |*args, **kwargs, &block|
                  Recipe.note_elements(self)
                  super(*args, **kwargs, &block)
                end
              else
                mod.define_method(first) do |*args, **kwargs, &block|
                  Recipe.call(self, __callee__, args, kwargs, block) { |b| super(*args, **kwargs, &b) }
                end
              end
              aliases.each { |a| mod.send(:alias_method, a, first) }
            end
            target.prepend(mod)
            @wrapped[key].merge(names)
            names
          end
        end
      end
    end
  end
end

require_relative 'recipe/surface'
require_relative 'recipe/ruby_writer'

module MB
  module Sound
    module GraphNode
      module Recipe
        # #to_ruby for graph nodes, bundles, Notes, and clips.
        module ToRuby
          # Returns Ruby code that builds this graph again from the DSL calls
          # that built it (see Recipe::RubyWriter).  +inputs+ names free
          # inputs (e.g. `inputs: { midi: notes }`); +seeds: true+ prints the
          # random seeds drawn (seed: N), so noise and random phases rebuild
          # the same whatever the root seed.
          #
          #     220.hz.ramp.filter(:lowpass, cutoff: 800).softclip.to_ruby
          #     # => "220.hz.ramp.filter(:lowpass, cutoff: 800).softclip"
          def to_ruby(inputs: {}, seeds: false)
            RubyWriter.new(self, inputs: inputs, seeds: seeds).to_s
          end
          alias to_rb to_ruby
        end
      end

      include Recipe::ToRuby
      Channels.include(Recipe::ToRuby)
    end

    Notes.include(GraphNode::Recipe::ToRuby)
    Sequence::Clip.include(GraphNode::Recipe::ToRuby)
    Sequence::Kit.include(GraphNode::Recipe::ToRuby)

    # The console's `ruby node`.
    module RecipeMethods
      # Prints Ruby code that builds +graph+ (a node, bundle, synth, or an
      # Array of nodes) again (see GraphNode#to_ruby).  Returns nil.
      #
      # Example (bin/sound.rb):
      #     s = 220.hz.ramp.filter(:lowpass, cutoff: 800).softclip
      #     ruby s
      def ruby(graph, inputs: {}, seeds: false)
        puts GraphNode::Recipe::RubyWriter.new(graph, inputs: inputs, seeds: seeds).to_s
      end
    end
    extend RecipeMethods
  end
end
