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
      # local variable names (read with a TracePoint targeted at the block
      # when it returns).  Runtime blocks (procs, spies, schedules) are never
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
        Invocation = Struct.new(:args, :result, :locals, :seeded, :statements, :call)

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

        # Thread-local recording state.
        State = Struct.new(:depth, :current, :scopes, :seeded)

        # Methods that take build blocks (run while the graph is built, their
        # nodes part of the recipe), by name.  Every other recorded method's
        # block is a runtime block.
        BUILD_BLOCKS = Set[
          :synth, :feedback, :fb, :delay, :feedback_delay, :unison, :swarm, :oversample, :new, :map_notes, :bands, :multiband,
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

        @enabled = ENV['MB_SOUND_RECIPES'] != '0'
        @seq = 0
        @wrapped = Hash.new { |h, k| h[k] = Set.new }

        class << self
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
          # block to pass on (wrapped for build blocks).
          def call(receiver, name, args, kwargs, block)
            st = state
            return yield(block) if st.depth > 0 || !@enabled

            if SILENT.include?(name)
              st.depth += 1
              begin
                return yield(block)
              ensure
                st.depth -= 1
              end
            end

            kind = block && (BUILD_BLOCKS.include?(name) ? :build : :runtime)
            call = Call.new(receiver, name, args, kwargs, block, kind, nil, st.scopes.last, 0, nil, lane(st))
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
            result
          end

          # Records +call+ on +result+ (see the module description).
          def note(receiver, call, result)
            return unless graph_object?(result) && !result.frozen?

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

            outs = bundle.is_a?(Channels) ? bundle.instance_variable_get(:@outputs) : bundle.outputs
            outs.each_with_index do |o, idx|
              next if record_of(o) || o.frozen?
              call = Call.new(bundle, :[], [idx], {}, nil, nil, nil, scope, next_seq, nil, nil)
              o.instance_variable_set(:@graph_recipe, Record.new(o, call))
            end
          end

          # The synth lane [index, count] calls are made in, :seeded inside
          # another MB::Sound.with_seed block (unison copies, drum voices:
          # their seeds derive from the parent's), or nil.
          def lane(st = state)
            MB::Sound::Synth.current_lane || (st.seeded > 0 ? :seeded : nil)
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

            call = Call.new(receiver, name, [], {}, block, :build, nil, inv, next_seq, nil, lane(st))
            (inv.statements ||= []) << call
            wrap_block(block, call)
          end

          # Wraps a build block so each call of it runs at depth 0 and records
          # an Invocation on +call+.
          def wrap_block(block, call)
            wrapped = proc do |*bargs|
              inv = Invocation.new(bargs, nil, {}, false, nil, call)
              (call.invocations ||= []) << inv
              st = Recipe.state
              saved = [st.depth, st.current]
              st.depth = 0
              st.current = nil
              st.scopes.push(inv)
              begin
                inv.result = Recipe.trace_locals(block, inv) {
                  block.call(*bargs)
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
          def trace_locals(block, inv, &run)
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
              if target <= Channels && ([first] + aliases).any? { |n| ELEMENT_ACCESS.include?(n) }
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
