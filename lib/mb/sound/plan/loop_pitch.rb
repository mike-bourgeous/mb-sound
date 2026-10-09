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
          PITCH_RESPONSE_KINDS = { one_a: 0, one_b: 1, add: 2, scale: 3, copy: 4, delay: 5, half: 6, svf: 7 }.freeze

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
            hit = @pc_have
            k = 0
            while k < nl
              x = values[leaves[k]]
              raise "No value for #{leaves[k]} in the latency estimate" if x.nil?

              srcs[k] = x
              hit &&= same_value?(x, prev[k])
              k += 1
            end
            j = 0
            while j < rings.length
              x = rings[j].last_delay
              srcs[nl + j] = x
              hit &&= same_value?(x, prev[nl + j])
              j += 1
            end
            t = @pitch_ring.last_delay
            srcs[-1] = t
            @pc_srcs, @pc_prev = prev, srcs
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

          # Check mode (MB_SOUND_PLAN_CHECK): #pitch_track in C, then from the
          # same state in Ruby; returns [the C result, nil or a description
          # of the difference].
          def pitch_track_check(values, count)
            before = pitch_state
            c = pitch_track_c(values, count)
            c = c.map { |x| x.is_a?(Numo::NArray) ? x.dup : x }
            c_state = pitch_state
            restore_pitch_state(before)
            r = pitch_track_ruby(values, count)
            r_state = pitch_state

            problem = nil
            if pitch_dump(c) != pitch_dump(r)
              problem = "pitch tracking differs: C #{c.inspect[0, 300]} vs Ruby #{r.inspect[0, 300]}"
            elsif pitch_dump(c_state) != pitch_dump(r_state)
              problem = "pitch tracking state differs: C #{c_state.inspect} vs Ruby #{r_state.inspect}"
            end
            [c, problem]
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

          # Floats and NArrays as bytes (so -0.0 and 0.0 differ).
          def pitch_dump(x)
            case x
            when Array then x.map { |y| pitch_dump(y) }
            when Numo::NArray then [x.class.name, x.shape, x.to_binary]
            when Float then [x].pack('G')
            else x
            end
          end

          def same_floats?(a, b)
            a.each_with_index.all? { |x, i| [x].pack('G') == [b[i]].pack('G') }
          end
        end
      end
    end
  end
end
