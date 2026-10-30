module MB
  module Sound
    # The registry of C kernels and their Ruby mirrors, with one switch
    # choosing which runs (kernels-1, 2026-10-30; arch-core review finding
    # 6, design/notes/kernels.md):
    #
    #     MB::Sound.kernels = :c       # the default: C kernels
    #     MB::Sound.kernels = :ruby    # every kernel's Ruby mirror
    #     MB::Sound.kernels = :check   # both, compared (raises Kernels::Mismatch)
    #     MB::Sound::Kernels.set(fast_plan: :ruby)   # one kernel or group
    #     MB::Sound::Kernels.with(:ruby) { node.sample(800) }
    #
    # MB_SOUND_KERNELS=ruby (or check, or c,fast_plan=ruby,svf=check) sets
    # them at load.  Every kernel registers once, beside its mirror:
    #
    #     # A module function: Kernels.svf(...) calls FastFilter.svf or
    #     # Filter::SVF.process_ruby (the same arguments and results)
    #     Kernels.register :svf, c: FastFilter.method(:svf), ruby: method(:process_ruby)
    #
    #     # Methods of a class (or a module's singleton class): Tone#kernel
    #     # is #kernel_c or #kernel_ruby, with the receiver's state saved and
    #     # restored around the check
    #     Kernels.register :tone, on: Tone, as: :kernel, c: :kernel_c, ruby: :kernel_ruby,
    #       state: %i[kernel_state restore_kernel_state], covers: [...]
    #
    #     # A class: Kernels.reverb_network is FastReverb::Network or the
    #     # mirror class (check mode: a class running both)
    #     Kernels.register :reverb_network, c: FastReverb::Network, ruby: RubyKernel
    #
    #     # A Ruby fast path with a reference path (no C): Kernels.notes_fast?
    #     # is true unless the mode is :ruby
    #     Kernels.register :notes_fast, path: true
    #
    # The dispatchers are aliases of generated methods, so :c costs one
    # Ruby frame for module functions and nothing for methods, and switching
    # modes re-aliases them (rare: tests, debugging).  Check mode runs the
    # Ruby mirror first on deep copies of the arguments (and of the
    # receiver's state, for methods with +state:+), then the C kernel on the
    # originals, so check mode's results and state are :c mode's; then it
    # compares the results, every array argument, and the state, exactly
    # unless the entry has a +tolerance:+.  A kernel called during another
    # kernel's check runs the half in progress (no nested checks).
    #
    # Every C function of a Fast* extension module is the +c:+ of an entry,
    # in an entry's +covers:+ (C functions called only inside a registered
    # C method), or in UNMIRRORED with a reason (I/O, instrumentation);
    # spec/lib/mb/sound/kernels_guard_spec.rb checks that, and that lib/
    # calls C functions only inside registered C paths.
    module Kernels
      MODES = %i[c ruby check].freeze

      # Raised in check mode when a C kernel and its Ruby mirror disagree.
      class Mismatch < RuntimeError; end

      # One registered kernel (see Kernels).  +kind+ is :function, :method,
      # :class, or :path; +c+ and +ruby+ are what runs (callables, method
      # names, or classes); +covers+ the C functions it stands for
      # ("FastFilter.svf"); +check+ true or a String saying why check mode
      # runs only the C kernel; +tolerance+ 0 (exact) or the largest
      # absolute difference check mode accepts.
      Entry = Data.define(:name, :kind, :group, :owner, :as, :c, :ruby, :covers, :tolerance, :check, :state, :check_if, :declines, :about) do
        def to_s
          "#{name} (#{kind}#{owner ? " #{owner_name}##{as}" : ''})"
        end

        def owner_name
          return nil unless owner

          owner.singleton_class? ? "#{owner.attached_object}." : owner.name.to_s
        end
      end

      # C functions with no Ruby mirror, by "Module.function" (or a whole
      # module, "FastAudio"), with the reason.  The guard spec requires every
      # Fast* function to be registered or listed here.
      UNMIRRORED = {
        'FastAudio' => 'device and JACK I/O, run on the device thread (its underrun concealer, FastAudio::Concealer, is compared with Concealment::Reference within 1e-6 by concealment_spec)',
        'FastMIDI' => 'RtMidi device I/O',
        'FastResample' => 'libsamplerate bindings (a library, specs compare against its documented behavior)',
        'FastLatency.mono_ns' => 'clock reads (instrumentation)',
        'FastLatency.spin' => 'holds the GVL for specs (instrumentation)',
        'FastLatency.system_sample' => 'system load and memory reads (instrumentation)',
        'FastLatency::Probe' => 'a pthread timing loop (instrumentation; its histograms are mirrored by LatencyProbe::Histogram)',
        'FastUI::GVLProbe' => 'a Ruby thread event hook (instrumentation)',
        'FastRecipe.frame_binding' => "the VM's debug inspector (a block frame's Binding; no Ruby equivalent: a TracePoint, Recipe.locals_mode :trace, makes YJIT discard its code and also sees nested blocks' locals)",
        'FastPlan.enums' => 'op-code tables the Ruby lowering reads (no computation)',
        'FastLoop.constants' => 'op-code tables the Ruby lowering reads (no computation)',
        'FastSound.fast_math=' => 'sets the C side of MB::Sound.precision (no computation)',
        'FastSound.fast_math?' => 'reads the C side of MB::Sound.precision (no computation)',
        'FastSound.smoothstep' => "not called by lib/: one of fast_sound's first scalar helpers (Ruby has smoothstep in mb-math)",
      }.freeze

      @entries = {}
      @default = :c
      @overrides = {}
      @pending = {}
      @callables = []
      @checked = Hash.new(0)
      @declined = Hash.new(0)
      @nested = Hash.new(0)
      @hooks = []
      @applied = {}

      HALF = :mb_sound_kernel_half

      class << self
        # Entries by name.
        attr_reader :entries

        # Check counts by entry name since the last #reset_checked (kernels
        # compared in check mode), and of calls a +declines:+ kernel declined
        # (returned nil for the caller's Ruby fallback), and of calls made
        # inside another kernel's check (compared through that kernel: its
        # C path runs this kernel's C, its mirror this kernel's mirror).
        attr_reader :checked, :declined, :nested

        # The default mode (:c, :ruby, or :check); entries and groups may
        # override it (#set).
        attr_reader :default

        # Registers a kernel (see Kernels).  Keywords:
        # - c:, ruby: a Method or callable (function), method names with
        #   +on:+/+as:+ (methods), Classes (class), or nothing with +path:+;
        # - group: the override group (default: the extension's name, e.g.
        #   :fast_filter);
        # - covers: C functions this entry stands for ("FastSynth.blit");
        #   a function's own c: is added;
        # - tolerance: 0 or a Float (largest absolute difference in check
        #   mode), or for methods a method name on the receiver giving it;
        # - check: true, or a String: why check mode runs only C;
        # - state: the receiver's instance variables holding its state
        #   (%i[@x1 @y1], deep-copied), or [save, restore] method names on
        #   it (methods);
        # - check_if: a method name on the receiver: check only when true;
        # - declines: true if the C kernel returns nil for arguments it can't
        #   take (the caller then runs its own Ruby code): check mode compares
        #   only the calls it took;
        # - about: one line for listings.
        def register(name, c: nil, ruby: nil, on: nil, as: nil, path: false, group: nil, covers: [], tolerance: 0,
                     check: true, state: nil, check_if: nil, declines: false, about: nil)
          name = name.to_sym
          raise ArgumentError, "kernel #{name.inspect} is already registered (#{@entries[name]})" if @entries.key?(name)
          raise ArgumentError, "kernel #{name.inspect} would hide Kernels.#{name}" if !on && RESERVED.include?(name)
          raise ArgumentError, "kernel #{name.inspect}: check: is true or a reason String" unless check == true || check.is_a?(String)

          kind = if path then :path
                 elsif on then :method
                 elsif c.is_a?(Class) then :class
                 else :function
                 end
          covers = Array(covers).map(&:to_s)
          covers |= [c_name(c)] if kind == :function && c_name(c)
          covers |= [c.name.sub(/\AMB::(Sound::)?/, '')] if kind == :class && c.name&.include?('Fast')
          group ||= infer_group(covers) || name
          state = state&.map(&:to_s)
          entry = Entry.new(
            name: name, kind: kind, group: group.to_sym, owner: on, as: as&.to_sym, c: c, ruby: ruby,
            covers: covers.freeze, tolerance: tolerance, check: check, state: state, check_if: check_if, declines: declines, about: about
          )
          validate(entry)
          @entries[name] = entry
          [name, entry.group].each { |k| @overrides[k] = @pending.delete(k) if @pending.key?(k) }
          define(entry)
          apply(entry)
          entry
        end

        # The entry named +name+ (raises KeyError with the names).
        def [](name)
          @entries.fetch(name.to_sym) do
            raise KeyError, "no kernel #{name.inspect}#{suggestion(name)}"
          end
        end

        # Sets the default mode for every kernel (clearing overrides).
        def mode=(mode)
          mode = check_mode(mode)
          return if mode == @default && @overrides.empty?

          @default = mode
          @overrides = {}
          apply_all
        end

        # The default mode.
        def mode
          @default
        end

        # Overrides the mode of entries or groups: set(fast_plan: :ruby,
        # svf: :check); nil removes an override.
        def set(**modes)
          modes.each do |k, m|
            k = k.to_sym
            raise ArgumentError, "no kernel or kernel group #{k.inspect}#{suggestion(k)}" unless known?(k)

            m.nil? ? @overrides.delete(k) : @overrides[k] = check_mode(m)
          end
          apply_all
        end

        # The current overrides (name or group => mode).
        def overrides
          @overrides.dup
        end

        # The mode of entry +name+ (its override, its group's, or the
        # default).
        def mode_of(name)
          e = self[name]
          @overrides[e.name] || @overrides[e.group] || @default
        end

        # Runs the block with +mode+ as the default and +overrides+, then
        # restores the previous modes.
        def with(mode = nil, **overrides)
          saved = [@default, @overrides.dup]
          if mode
            @default = check_mode(mode)
            @overrides = {}
          end
          overrides.each { |k, m| @overrides[k.to_sym] = check_mode(m) }
          apply_all
          yield
        ensure
          @default, @overrides = saved
          apply_all
        end

        # Parses a MB_SOUND_KERNELS value ("ruby", "check", "c,fast_plan=ruby")
        # into [default, overrides].
        def parse(text)
          default = :c
          overrides = {}
          text.to_s.split(',').map(&:strip).reject(&:empty?).each do |part|
            if part.include?('=')
              k, v = part.split('=', 2)
              overrides[k.strip.to_sym] = check_mode(v.strip.to_sym)
            else
              default = check_mode(part.to_sym)
            end
          end
          [default, overrides]
        end

        # Sets the modes from a MB_SOUND_KERNELS value; overrides naming
        # kernels not yet registered apply when they register.
        def configure(text)
          @default, over = parse(text)
          @overrides = {}
          @pending = {}
          over.each { |k, m| known?(k) ? @overrides[k] = m : @pending[k] = m }
          @configured = [@default, over.freeze]
          apply_all
        end

        # Returns every kernel to the modes MB_SOUND_KERNELS gave (#configure;
        # spec_helper calls this before each example).
        def reset!
          default, over = @configured
          return if @default == default && @overrides == over.select { |k, _| known?(k) }

          @default = default
          @overrides = over.select { |k, _| known?(k) }
          apply_all
        end

        # Override names given in MB_SOUND_KERNELS that no kernel or group
        # has (after everything loaded; for a spec and diagnostics).
        def unknown_overrides
          @pending.keys.reject { |k| known?(k) }
        end

        # Every C function covered by an entry ("FastFilter.svf" => entry).
        def coverage
          h = {}
          @entries.each_value { |e| e.covers.each { |c| h[c] = e } }
          h
        end

        # Clears the check counts.
        def reset_checked
          @declined = Hash.new(0)
          @nested = Hash.new(0)
          @checked = Hash.new(0)
        end

        # Calls +block+ with the new mode of each entry after it changes
        # (+block+ gets the entry and its mode; for switches outside
        # mb-sound, like mb-term's native grid).
        def on_change(&block)
          @hooks << block
        end

        # A one-line-per-kernel listing (name, kind, group, mirror, check).
        def listing
          @entries.values.map do |e|
            mirror = case e.kind
                     when :path then 'reference path'
                     when :method then "#{e.owner_name}##{e.ruby}"
                     when :class then e.ruby.to_s
                     else callable_name(e.ruby)
                     end
            chk = if e.check != true then 'C only in check mode'
                  elsif e.tolerance.is_a?(Symbol) then "within ##{e.tolerance}"
                  elsif e.tolerance.zero? then 'exact'
                  else "within #{e.tolerance}"
                  end
            format('%-24s %-9s %-16s %s (%s)', e.name, e.kind, e.group, mirror, chk)
          end
        end

        # For check mode (generated dispatchers): runs a function entry's
        # mirror and C kernel and compares them.
        def check_function(entry, *args, **kw, &block)
          half = Thread.current[HALF]
          if half
            @nested[entry.name] += 1
            return call_half(entry, half, args, kw, block)
          end
          return call_half(entry, :c, args, kw, block) unless entry.check == true

          r_args = deep_copy(args)
          r_kw = deep_copy(kw)
          r = in_half(:ruby) { __send__(:"#{entry.name}__ruby", *r_args, **r_kw, &block) }
          r = deep_copy(r)
          c = in_half(:c) { __send__(:"#{entry.name}__c", *args, **kw, &block) }
          if c.nil? && entry.declines
            # (the C kernel declined these arguments: the caller's Ruby
            # fallback runs, so there is nothing to compare)
            @declined[entry.name] += 1
            return c
          end
          compare(entry, args, kw, r_args, r_kw, c, r)
          @checked[entry.name] += 1
          c
        end

        # For check mode: runs a method entry's mirror and C method on
        # +recv+ (saving and restoring its state) and compares them.
        def check_method(entry, recv, *args, **kw, &block)
          half = Thread.current[HALF]
          @nested[entry.name] += 1 if half
          if half || entry.check != true || (entry.check_if && !recv.__send__(entry.check_if))
            name = (half || :c) == :ruby ? entry.ruby : entry.c
            return in_half(half || :c) { recv.__send__(name, *args, **kw, &block) }
          end

          save = !entry.state.nil?
          s0 = save_state(entry, recv) if save
          r_args = deep_copy(args)
          r_kw = deep_copy(kw)
          r = in_half(:ruby) { recv.__send__(entry.ruby, *r_args, **r_kw, &block) }
          r = deep_copy(r)
          s_ruby = save_state(entry, recv) if save
          restore_state(entry, recv, s0) if save
          c = in_half(:c) { recv.__send__(entry.c, *args, **kw, &block) }
          tolerance = entry.tolerance.is_a?(Symbol) ? recv.__send__(entry.tolerance) : entry.tolerance
          compare(entry, args, kw, r_args, r_kw, c, r, tolerance)
          if save
            s_c = save_state(entry, recv)
            d = diff(s_c, s_ruby, tolerance)
            raise Mismatch, "kernel #{entry.name}: the state differs after C and Ruby: #{d}" if d
          end
          @checked[entry.name] += 1
          c
        end

        # The result of the mirror of a kernel that writes its buffer with
        # mb_ensure_inplace_sfloat: +values+ (an Array or NArray) written into
        # +buffer+ when that is an inplace contiguous SFloat (the kernel works
        # in place), else a new SFloat.
        def inplace_result(buffer, values)
          if buffer.is_a?(Numo::SFloat) && buffer.inplace? && buffer.contiguous?
            buffer[true] = values
            buffer
          else
            Numo::SFloat.cast(values)
          end
        end

        # The buffer the mirror of a kernel that writes +out+ with
        # mb_ensure_inplace_sfloat (or the SComplex twin) writes into: +out+
        # cast to +type+, itself when it was an inplace contiguous one, else
        # a copy (so a non-inplace +out+ stays as it was, as with C).
        def inplace_buffer(out, type = Numo::SFloat)
          inplace = out.inplace?
          buf = type.cast(out)
          return buf if inplace && buf.contiguous? && buf.equal?(out)

          buf.equal?(out) || !buf.contiguous? ? buf.dup : buf
        end

        # A deep copy of +x+ for the mirror's half of a check: NArrays,
        # Arrays, Hashes, and Strings are copied (keeping frozen and inplace
        # flags, and objects appearing twice appear twice in the copy),
        # objects with #kernel_copy copy themselves (and compare by their
        # #kernel_state), and other objects are shared.
        def deep_copy(x, seen = {}.compare_by_identity)
          return seen[x] if seen.key?(x)

          case x
          when Numo::NArray
            c = begin
              x.dup
            rescue RuntimeError
              x.class.new(*x.shape) # (unallocated: a buffer the kernel fills)
            end
            c.inplace! if x.inplace?
            c.freeze if x.frozen?
            seen[x] = c
          when Array
            c = seen[x] = []
            x.each { |v| c << deep_copy(v, seen) }
            c.freeze if x.frozen?
            c
          when Hash
            c = seen[x] = {}
            x.each { |k, v| c[k] = deep_copy(v, seen) }
            c.freeze if x.frozen?
            c
          when String
            seen[x] = x.frozen? ? x : x.dup
          else
            # (objects holding kernel state, like DelayLines a network
            # writes, copy themselves)
            x.respond_to?(:kernel_copy) ? seen[x] = x.kernel_copy : x
          end
        end

        # nil if +a+ and +b+ match (exactly, or within +tolerance+), else a
        # description of the first difference.
        def diff(a, b, tolerance = 0, path = '')
          case a
          when Numo::NArray
            return "#{at(path)}an #{a.class} vs #{b.class}" unless b.is_a?(Numo::NArray)
            return "#{at(path)}shape #{a.shape} vs #{b.shape}" unless a.shape == b.shape
            return nil if a.size == 0

            begin
              narray_diff(a, b, tolerance, path)
            rescue RuntimeError => e
              raise unless e.message.include?('unallocated')

              nil # (a buffer neither kernel wrote)
            end
          when Array
            return "#{at(path)}an Array vs #{b.class}" unless b.is_a?(Array)
            return "#{at(path)}#{a.length} values vs #{b.length}" unless a.length == b.length

            a.each_with_index do |v, i|
              d = diff(v, b[i], tolerance, "#{path}[#{i}]")
              return d if d
            end
            nil
          when Hash
            return "#{at(path)}a Hash vs #{b.class}" unless b.is_a?(Hash)
            return "#{at(path)}keys #{a.keys} vs #{b.keys}" unless a.keys == b.keys

            a.each do |k, v|
              d = diff(v, b[k], tolerance, "#{path}[#{k.inspect}]")
              return d if d
            end
            nil
          when Float, Integer, Rational, Complex
            return "#{at(path)}#{a.inspect} vs #{b.inspect}" unless b.is_a?(Numeric)

            scalar_diff(a, b, tolerance, path)
          when nil, true, false, Symbol, String
            a == b ? nil : "#{at(path)}#{a.inspect} vs #{b.inspect}"
          else
            # Objects holding kernel state compare by it; others can't be
            # compared (shared, or the kernel's own)
            if a.respond_to?(:kernel_state) && b.respond_to?(:kernel_state)
              diff(a.kernel_state, b.kernel_state, tolerance, path)
            elsif a.class == b.class && a.method(:==).owner != BasicObject && a.method(:==).owner != Kernel
              a == b ? nil : "#{at(path)}#{a.inspect[0, 200]} vs #{b.inspect[0, 200]}"
            end
          end
        end

        private

        def at(path)
          path.empty? ? '' : "#{path}: "
        end

        def scalar_diff(a, b, tolerance, path)
          return nil if a == b || (a.is_a?(Float) && b.is_a?(Float) && a.nan? && b.nan?)
          return "#{at(path)}#{a.inspect} vs #{b.inspect}" if tolerance.zero? || !a.real? || !b.real?
          return nil if (a - b).abs <= tolerance

          "#{at(path)}#{a.inspect} vs #{b.inspect} (tolerance #{tolerance})"
        end

        def narray_diff(a, b, tolerance, path)
          if a.is_a?(Numo::RObject) || b.is_a?(Numo::RObject)
            d = diff(a.to_a, b.to_a, tolerance, path)
            return d
          end

          complex = a.is_a?(Numo::SComplex) || a.is_a?(Numo::DComplex) || b.is_a?(Numo::SComplex) || b.is_a?(Numo::DComplex)
          x = complex ? Numo::DComplex.cast(a) : Numo::DFloat.cast(a)
          y = complex ? Numo::DComplex.cast(b) : Numo::DFloat.cast(b)
          parts = complex ? [[x.real, y.real], [x.imag, y.imag]] : [[x, y]]
          parts.each do |p, q|
            same = p.eq(q) | (p.isnan & q.isnan)
            next if same.all?

            delta = (p - q).abs
            delta[same] = 0
            delta[delta.isnan] = Float::INFINITY
            next if tolerance > 0 && delta.max <= tolerance

            i = delta.max_index
            idx = a.ndim > 1 ? a.shape.reverse.inject([[], i]) { |(acc, r), n| [[r % n] + acc, r / n] }[0] : [i]
            return "#{at(path)}#{a.class} at #{idx.inspect}: #{a[*idx].inspect} vs #{b[*idx].inspect} (#{(~same).count_true} of #{a.size} values differ, largest by #{delta.max})"
          end
          nil
        end

        def compare(entry, args, kw, r_args, r_kw, c, r, tolerance = entry.tolerance)
          d = diff(c, r, tolerance)
          raise Mismatch, "kernel #{entry.name}: the result differs between C and Ruby: #{d}" if d

          args.each_with_index do |a, i|
            next unless a.is_a?(Numo::NArray) || a.is_a?(Array) || a.is_a?(Hash)

            d = diff(a, r_args[i], tolerance)
            raise Mismatch, "kernel #{entry.name}: argument #{i + 1} differs after C and Ruby: #{d}" if d
          end
          kw.each do |k, a|
            next unless a.is_a?(Numo::NArray) || a.is_a?(Array) || a.is_a?(Hash)

            d = diff(a, r_kw[k], tolerance)
            raise Mismatch, "kernel #{entry.name}: #{k}: differs after C and Ruby: #{d}" if d
          end
        end

        # The receiver's state for a check: its +state:+ instance variables
        # (deep copies), or its save method's result.
        def save_state(entry, recv)
          if entry.state[0].start_with?('@')
            entry.state.map { |v| deep_copy(recv.instance_variable_get(v)) }
          else
            recv.__send__(entry.state[0])
          end
        end

        # (in place where it can: NArrays of the same shape, objects with
        # #kernel_restore, so other references to them stay current)
        def restore_state(entry, recv, saved)
          if entry.state[0].start_with?('@')
            entry.state.each_with_index do |v, i|
              cur = recv.instance_variable_get(v)
              if cur.is_a?(Numo::NArray) && saved[i].is_a?(Numo::NArray) && cur.class == saved[i].class && cur.shape == saved[i].shape && !cur.frozen?
                cur[*Array.new(cur.ndim, true)] = saved[i]
              elsif cur.respond_to?(:kernel_restore) && cur.class == saved[i].class
                cur.kernel_restore(saved[i])
              else
                recv.instance_variable_set(v, deep_copy(saved[i]))
              end
            end
          else
            recv.__send__(entry.state[1], saved)
          end
        end

        def in_half(half)
          prev = Thread.current[HALF]
          Thread.current[HALF] = half
          yield
        ensure
          Thread.current[HALF] = prev
        end

        def call_half(entry, half, args, kw, block)
          in_half(half) { __send__(:"#{entry.name}__#{half}", *args, **kw, &block) }
        end

        def check_mode(mode)
          mode = mode.to_sym if mode.is_a?(String)
          return mode if MODES.include?(mode)

          raise ArgumentError, "kernel mode is one of #{MODES.map(&:inspect).join(', ')} (got #{mode.inspect})"
        end

        def known?(name)
          @entries.key?(name) || @entries.each_value.any? { |e| e.group == name }
        end

        def suggestion(name)
          s = DidYouMean::SpellChecker.new(dictionary: (@entries.keys + @entries.values.map(&:group)).uniq.map(&:to_s)).correct(name.to_s).first
          s ? " (did you mean #{s.to_sym.inspect}?)" : ''
        end

        def c_name(c)
          return nil unless c.is_a?(Method) && c.receiver.is_a?(Module) && c.receiver.name&.include?('Fast')

          "#{c.receiver.name.sub(/\AMB::(Sound::)?/, '')}.#{c.name}"
        end

        def callable_name(c)
          if c.is_a?(Method)
            r = c.receiver
            r.is_a?(Module) ? "#{r.name}.#{c.name}" : "#{r.class}##{c.name}"
          else
            c.to_s
          end
        end

        def infer_group(covers)
          mod = covers.first&.split(/[.:]/)&.first
          return nil unless mod&.start_with?('Fast')

          mod.gsub(/([a-z])([A-Z])/, '\1_\2').downcase.to_sym
        end

        def validate(entry)
          case entry.kind
          when :function
            raise ArgumentError, "kernel #{entry.name}: c: and ruby: must be callable" unless entry.c.respond_to?(:call) && entry.ruby.respond_to?(:call)
          when :method
            raise ArgumentError, "kernel #{entry.name}: methods need as:, c:, and ruby: names" unless entry.as && entry.c.is_a?(Symbol) && entry.ruby.is_a?(Symbol)
            [entry.c, entry.ruby].each do |m|
              unless entry.owner.method_defined?(m) || entry.owner.private_method_defined?(m)
                raise ArgumentError, "kernel #{entry.name}: #{entry.owner} has no method #{m}"
              end
            end
            if entry.state && !(entry.state.all? { |v| v.to_s.start_with?('@') } || entry.state.length == 2)
              raise ArgumentError, "kernel #{entry.name}: state: is instance variable names or [save, restore] method names"
            end
          when :class
            raise ArgumentError, "kernel #{entry.name}: c: and ruby: must be classes" unless entry.ruby.is_a?(Class)
          end
        end

        # Defines the generated methods of +entry+ (see Kernels).
        def define(entry)
          n = entry.name
          case entry.kind
          when :function
            sc = singleton_class
            sc.class_eval("def #{n}__c(...) = #{target(entry.c)}(...)", __FILE__, __LINE__)
            sc.class_eval("def #{n}__ruby(...) = #{target(entry.ruby)}(...)", __FILE__, __LINE__)
            e = entry
            sc.define_method(:"#{n}__check") { |*a, **k, &b| Kernels.check_function(e, *a, **k, &b) }
          when :method
            e = entry
            owner = entry.owner
            owner.define_method(:"#{entry.as}__check") { |*a, **k, &b| Kernels.check_method(e, self, *a, **k, &b) }
            owner.__send__(:private, :"#{entry.as}__check")
          when :class
            check = entry.check == true ? check_class(entry) : entry.c
            singleton_class.define_method(:"#{n}__c") { entry.c }
            singleton_class.define_method(:"#{n}__ruby") { entry.ruby }
            singleton_class.define_method(:"#{n}__check") { check }
          when :path
            sc = singleton_class
            sc.class_eval("def #{n}__c? = true; def #{n}__ruby? = false; def #{n}__check? = true", __FILE__, __LINE__)
          end
        end

        # Source text calling +callable+: Module.method for a public method
        # of a named module, else a stored callable.
        def target(callable)
          if callable.is_a?(Method) && callable.receiver.is_a?(Module) && callable.receiver.name &&
             Object.const_get(callable.receiver.name).equal?(callable.receiver) &&
             callable.receiver.public_methods.include?(callable.name)
            "::#{callable.receiver.name}.#{callable.name}"
          else
            @callables << callable
            "@callables[#{@callables.length - 1}].call"
          end
        end

        def apply_all
          @entries.each_value { |e| apply(e) }
        end

        # Points +entry+'s dispatcher at its mode's method.
        def apply(entry)
          mode = mode_of(entry.name)
          return if @applied[entry.name] == mode

          @applied[entry.name] = mode
          n = entry.name
          case entry.kind
          when :function, :class
            singleton_class.alias_method(n, :"#{n}__#{mode}")
          when :path
            singleton_class.alias_method(:"#{n}?", :"#{n}__#{mode}?")
          when :method
            owner = entry.owner
            src = case mode
                  when :c then entry.c
                  when :ruby then entry.ruby
                  else :"#{entry.as}__check"
                  end
            private = owner.private_method_defined?(entry.c)
            owner.alias_method(entry.as, src)
            owner.__send__(private ? :private : :public, entry.as)
          end
          @hooks.each { |h| h.call(entry, mode) }
        end

        # A class running instances of the C class and the mirror class side
        # by side, comparing every call (check mode for class entries).
        def check_class(entry)
          e = entry
          klass = Class.new do
            define_singleton_method(:name) { "#{e.c.name}+#{e.ruby.name}" }
            define_singleton_method(:to_s) { name }
            define_method(:initialize) do |*a, **k, &b|
              r_a = Kernels.deep_copy(a)
              r_k = Kernels.deep_copy(k)
              @kernel_ruby = Kernels.send(:in_half, :ruby) { e.ruby.new(*r_a, **r_k, &b) }
              @kernel_c = Kernels.send(:in_half, :c) { e.c.new(*a, **k, &b) }
            end

            attr_reader :kernel_c, :kernel_ruby

            (e.c.public_instance_methods(true) - Object.public_instance_methods).each do |m|
              define_method(m) do |*a, **k, &b|
                if e.check != true || Thread.current[HALF]
                  half = Thread.current[HALF] || :c
                  obj = half == :ruby ? @kernel_ruby : @kernel_c
                  next Kernels.send(:in_half, half) { obj.public_send(m, *a, **k, &b) }
                end

                r_a = Kernels.deep_copy(a)
                r_k = Kernels.deep_copy(k)
                r = Kernels.deep_copy(Kernels.send(:in_half, :ruby) { @kernel_ruby.public_send(m, *r_a, **r_k, &b) })
                c = Kernels.send(:in_half, :c) { @kernel_c.public_send(m, *a, **k, &b) }
                Kernels.send(:compare, e, a, k, r_a, r_k, c, r)
                Kernels.checked[e.name] += 1
                c.equal?(@kernel_c) ? self : c
              end
            end
          end
          klass
        end
      end

      # Kernels' own methods, which no function kernel may be named.
      RESERVED = singleton_methods.freeze

      configure(ENV['MB_SOUND_KERNELS'])
    end

    class << self
      # The kernel mode: :c (the default), :ruby, or :check (see
      # MB::Sound::Kernels).
      def kernels
        Kernels.mode
      end

      # Sets the kernel mode for every kernel (see MB::Sound::Kernels).
      def kernels=(mode)
        Kernels.mode = mode
      end
    end
  end
end

require_relative 'kernels/arithmetic'
require_relative 'kernels/buffers'
