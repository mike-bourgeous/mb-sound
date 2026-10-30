module MB
  module Sound
    module Plan
      module Loop
        # Latency compensation at the pitch and the sustain shelf in C
        # (FastLoop.pitch_track, ext/mb/sound/fast_loop/loop_pitch.c), the
        # same values as Program#pitch_track_ruby bit for bit (specs and check
        # mode compare them).  The Ruby version evaluated each 16-sample point
        # in scalar Ruby (~4 us per point) and the DC moments over whole
        # blocks in NArray math; the kernel evaluates both at the points only
        # (research-fused-ops 3b8c8b7f: pluck 85 -> 37% of realtime at
        # 128-sample blocks on dense_modulated.mid with the prototype).
        class Program
          # Kinds of #pitch_code's value expressions (loop_pitch.c's VK_*).
          PITCH_VALUE_KINDS = { const: 0, src: 1, mul: 2, add: 3, div: 4, pow: 5 }.freeze

          # Kinds of #response_program's entries (loop_pitch.c's RK_*).
          PITCH_RESPONSE_KINDS = { one_a: 0, one_b: 1, add: 2, scale: 3, copy: 4, delay: 5, half: 6, svf: 7, four_pole: 8 }.freeze

          # #pitch_track through the C kernel.  Checks whether anything moved
          # before calling it (the same test as #pitch_track_ruby: frozen
          # buffers that are the same object, equal numbers), so loops whose
          # parameters hold cost one comparison per source per block.
          def pitch_track_c(values, count)
            return [0.0, 1.0, 0.0] unless @pitch_ring

            code = pitch_code
            leaves = code[:leaves]
            rings = code[:rings]
            nl = leaves.length

            # Sources this block (swapped with the previous block's)
            srcs = (@pc_srcs ||= Array.new(code[:nsrc]))
            prev = (@pc_prev ||= Array.new(code[:nsrc]))
            # Their generations (see GraphNode::FrozenView)
            gens = (@pc_gens ||= Array.new(code[:nsrc], 0))
            prev_gens = (@pc_prev_gens ||= Array.new(code[:nsrc], 0))
            hit = @pc_have
            k = 0
            while k < nl
              x = values[leaves[k]]
              raise "No value for #{leaves[k]} in the latency estimate" if x.nil?

              srcs[k] = x
              gens[k] = x.is_a?(Numo::NArray) ? GraphNode::FrozenView.generation(x) : 0
              hit &&= same_value?(x, prev[k], prev_gens[k])
              k += 1
            end
            j = 0
            while j < rings.length
              x = rings[j].last_delay
              srcs[nl + j] = x
              gens[nl + j] = x.is_a?(Numo::NArray) ? GraphNode::FrozenView.generation(x) : 0
              hit &&= same_value?(x, prev[nl + j], prev_gens[nl + j])
              j += 1
            end
            t = @pitch_ring.last_delay
            srcs[-1] = t
            @pc_srcs, @pc_prev = prev, srcs
            @pc_gens, @pc_prev_gens = prev_gens, gens
            @pc_have = true

            pos = @pitch_pos || 0

            # Nothing moved since the last evaluation: the held values
            if hit && @pitch_b && @pitch_a == @pitch_b && !t.is_a?(Numo::NArray) && t == @pitch_t
              @pitch_pos = pos + count
              return @pitch_b
            end

            code[:rates].each { |idx, filter| code[:scalars][idx] = filter.sample_rate.to_f }

            st = (@pc_state ||= Numo::DFloat.zeros(10))
            if @pitch_a
              st[0] = @pitch_a[0]; st[1] = @pitch_a[1]; st[2] = @pitch_a[2]
              st[3] = @pitch_b[0]; st[4] = @pitch_b[1]; st[5] = @pitch_b[2]
              st[6] = 1.0
            else
              st[6] = 0.0
            end
            st[7] = @stretch || 0.0
            st[8] = @stretch ? 1.0 : 0.0
            st[9] = @sustain_ratio

            outs = (@pc_outs ||= {})[count] ||= Array.new(3) { Numo::DFloat.zeros(count) }
            first = (-pos) % PITCH_STEP
            ramped = FastLoop.pitch_track(code[:words], code[:scalars], srcs, count, first, pos, st, outs)

            @pitch_t = t.is_a?(Numo::NArray) ? nil : t
            a = [st[0], st[1], st[2]]
            b = [st[3], st[4], st[5]]
            @pitch_a = a unless a == @pitch_a && same_floats?(a, @pitch_a)
            @pitch_b = b unless b == @pitch_b && same_floats?(b, @pitch_b)
            @stretch = st[7] if st[8] != 0
            @sustain_ratio = st[9]
            @pitch_pos = pos + count

            ramped ? outs : @pitch_b
          end

          # The encoded response program for FastLoop.pitch_track: a Hash with
          # :words (Int32), :scalars (DFloat), :leaves (boundary input and
          # param Values whose block data are sources), :rings (delays whose
          # times are sources), :nsrc (leaves, rings, then the pitch delay's
          # time), and :rates ([scalar index, filter] whose sample rates are
          # refreshed per call).
          def pitch_code
            @pitch_code ||= begin
              list, oa, ob = response_program
              vk = PITCH_VALUE_KINDS
              vex = []
              scalars = []
              rates = []
              leaves = []
              leaf_idx = {}.compare_by_identity
              rings = []
              ring_idx = {}.compare_by_identity
              vmemo = {}.compare_by_identity

              const = ->(x) {
                scalars << x.to_f
                vex << [vk[:const], scalars.length - 1, 0]
                vex.length - 1
              }

              # Mirrors #value_of
              venc = nil
              venc = lambda do |v|
                case v
                when Plan::Const then const.call(v.parts[0])
                when Plan::Value
                  op = v.op
                  if op.is_a?(Plan::Op::Input) || op.is_a?(Plan::Op::Param)
                    idx = leaf_idx[v] ||= (leaves << v).length - 1
                    vex << [vk[:src], idx, 0]
                    next vex.length - 1
                  end
                  next vmemo[v] if vmemo.key?(v)

                  vmemo[v] = case op
                             when Plan::Op::Fill then const.call(op.value.parts[0])
                             when Plan::Op::Copy then venc.call(op.a)
                             when Plan::Op::Mul, Plan::Op::Add, Plan::Op::Div, Plan::Op::Pow
                               a = venc.call(op.a)
                               b = venc.call(op.b)
                               kind = { Plan::Op::Mul => :mul, Plan::Op::Add => :add, Plan::Op::Div => :div, Plan::Op::Pow => :pow }.fetch(op.class)
                               vex << [vk[kind], a, b]
                               vex.length - 1
                             else
                               const.call(1.0)
                             end
                else
                  const.call(v.to_f)
                end
              end

              entries = list.map { |e|
                kind = PITCH_RESPONSE_KINDS.fetch(e[0])
                w = [kind, e[2] || 0, 0, 0, 0, 0, 0, 0]
                case e[0]
                when :add
                  w[2] = e[3]
                when :scale
                  w[3] = venc.call(e[3])
                  w[6] = e[4] ? 1 : 0
                when :delay
                  w[3] = ring_idx[e[3]] ||= (rings << e[3]).length - 1 # a ring index for now
                when :svf
                  op = e[3]
                  w[3] = venc.call(op.cutoff)
                  w[4] = venc.call(op.quality)
                  w[5] = op.gain.nil? ? const.call(1.0) : venc.call(op.gain)
                  w[6] = op.filter.instance_variable_get(:@type_id)
                  scalars << op.filter.sample_rate.to_f
                  w[7] = scalars.length - 1
                  rates << [w[7], op.filter]
                when :four_pole
                  # (loop_pitch.c's RK_FOUR_POLE words and scalars)
                  op = e[3]
                  f = op.filter
                  w[3] = venc.call(op.cutoff)
                  w[4] = venc.call(op.resonance)
                  w[5] = scalars.length
                  scalars << f.sample_rate.to_f << f.k_max.to_f << f.compensation.to_f
                  f.instance_variable_get(:@mix).each { |x| scalars << x.to_f }
                  w[6] = f.send(:kernel_options)[0] | (f.diode? && f.normalize? ? 4 : 0) | (f.diode? ? 8 : 0) | (f.instance_variable_get(:@tuning_number) << 4)
                  rates << [w[5], f]
                end
                w
              }

              nl = leaves.length
              entries.each { |w| w[3] += nl if w[0] == PITCH_RESPONSE_KINDS[:delay] }
              nsrc = nl + rings.length + 1

              sus_idx = 0
              if @sustain
                scalars << @sustain[:filter].sample_rate.to_f
                sus_idx = scalars.length - 1
                rates << [sus_idx, @sustain[:filter]]
              end
              scalars << 0.0 if scalars.empty?

              flags = (@history ? 1 : 0) | (@sustain ? 2 : 0) | (uneven_filters?(list) ? 4 : 0)
              header = [vex.length, entries.length, oa || -1, ob || -1, flags, nsrc, nsrc - 1, sus_idx]
              {
                words: Numo::Int32[*header, *vex.flatten, *entries.flatten],
                scalars: Numo::DFloat[*scalars],
                leaves: leaves.freeze,
                rings: rings.freeze,
                nsrc: nsrc,
                rates: rates.freeze,
              }
            end
          end

          private

          def pitch_state
            [@pitch_a&.dup, @pitch_b&.dup, @pitch_pos, @pitch_t, @stretch, @sustain_ratio]
          end

          def restore_pitch_state(s)
            @pitch_a, @pitch_b, @pitch_pos, @pitch_t, @stretch, @sustain_ratio = s
          end

          # True if +a+ and +b+ hold the same Float bits element by element
          # (as their pack('G') bytes, without the Strings for usual values).
          def same_floats?(a, b)
            i = 0
            n = a.length
            while i < n
              return false unless same_float?(a[i], b[i])
              i += 1
            end
            true
          end

          def same_float?(x, y)
            return [x].pack('G') == [y].pack('G') unless x.is_a?(Float) && y.is_a?(Float)
            # (atan2 tells -0.0 from 0.0 without making Infinity Objects)
            return x != 0.0 || Math.atan2(x, -1.0) == Math.atan2(y, -1.0) if x == y
            x.nan? && y.nan? && [x].pack('G') == [y].pack('G')
          end
        end
      end

      Kernels.register :loop_pitch, on: Loop::Program, as: :pitch_track, c: :pitch_track_c, ruby: :pitch_track_ruby,
        state: %i[pitch_state restore_pitch_state], covers: %w[FastLoop.pitch_track]
    end
  end
end
