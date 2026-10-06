RSpec.describe(MB::Sound::FastWavetable, aggregate_failures: true) do
  # The C kernels must give exactly the same samples as their Ruby mirrors
  # (MB::Sound::Wavetable::KernelRuby).
  let(:w) { MB::Sound::Wavetable }
  let(:n) { 300 }

  let(:cycle_tables) {
    {
      saw: w[:saw],
      basic: w[:basic],
      complex: w.from_harmonics([[1, 0.5, 0.3], [0.2, 1, 0.1]], complex: true),
      unmipped: w.from_samples(Numo::SFloat.new(3, 100).rand(-1, 1), mips: false),
      half_octave: w.from_harmonics(w::Library.square(200), mips: :half_octave),
    }
  }

  def rand_input(min, max)
    Numo::SFloat.new(n).rand(min, max)
  end

  def out_buffer(table)
    (table.complex? ? Numo::SComplex : Numo::SFloat).zeros(n)
  end

  describe '.oscillate' do
    it 'matches the Ruby mirror with every interpolator, with constant and changing inputs' do
      Numo::NArray.srand(1)
      cases = [
        [440.0, 0, nil, 0.3],
        [rand_input(-3000, 12000), rand_input(-3, 3), rand_input(0, 1), rand_input(-0.2, 1.2)],
        [rand_input(20, 20000), 0.5, 0.3, 0.7],
      ]

      cycle_tables.each do |name, t|
        w::INTERPOLATIONS.each_key do |interp|
          cases.each_with_index do |(f, pm, width, scan), ci|
            st1 = [0.3]
            ts1 = [0.0, 0.0, 0, 0.0, 0.0]
            st2 = st1.dup
            ts2 = ts1.dup

            a = t.oscillate(out_buffer(t).inplace!, f, 1 / 48000.0, 0.7, 0.1, st1, ts1, pm, width, scan, interp, 48000, true).not_inplace!
            b = t.oscillate_ruby(out_buffer(t), f, 1 / 48000.0, 0.7, 0.1, st2, ts2, pm, width, scan, interp, 48000, true)

            expect(a.to_a).to eq(b.to_a), "#{name} #{interp} case #{ci}: max difference #{(a - b).abs.max}"
            expect(st1).to eq(st2)
            expect(ts1).to eq(ts2)
            expect(a.abs.max).to be > 0.05
          end
        end
      end
    end

    it 'continues smoothly across buffers' do
      t = w[:saw]
      st = [0.0]
      ts = [0.0, 0.0, 0, 0.0, 0.0]
      a = t.oscillate(Numo::SFloat.zeros(100), 100.0, 1 / 48000.0, 1, 0, st, ts, 0, nil, 0, nil, 48000, true)
      b = t.oscillate(Numo::SFloat.zeros(100), 100.0, 1 / 48000.0, 1, 0, st, ts, 0, nil, 0, nil, 48000, true)
      whole = t.oscillate(Numo::SFloat.zeros(200), 100.0, 1 / 48000.0, 1, 0, [0.0], [0.0, 0.0, 0, 0.0, 0.0], 0, nil, 0, nil, 48000, true)
      expect(a.concatenate(b)).to all_be_within(1e-6).of_array(whole)
    end

    it 'raises errors for a sample-mode table' do
      t = w.from_samples(Numo::SFloat.zeros(100), mode: :sample, root: 100)
      expect {
        MB::Sound::FastWavetable.oscillate(Numo::SFloat.zeros(10), t.kernel_spec(48000), 1, 1, 1, 0, [0.0], [0.0, 0.0, 0, 0.0, 0.0], 0, nil, 0, 3, false, nil)
      }.to raise_error(ArgumentError, /cycle/)
    end

    it 'raises an error for a bad interpolation code' do
      expect {
        MB::Sound::FastWavetable.oscillate(Numo::SFloat.zeros(10), w[:saw].kernel_spec(48000), 1, 1, 1, 0, [0.0], [0.0, 0.0, 0, 0.0, 0.0], 0, nil, 0, 7, false, nil)
      }.to raise_error(ArgumentError, /interpolation/)
    end

    it 'raises an error for a malformed table' do
      spec = w[:saw].kernel_spec(48000).dup
      spec[2] = [Numo::DFloat.zeros(1, 40)]
      expect {
        MB::Sound::FastWavetable.oscillate(Numo::SFloat.zeros(10), spec, 1, 1, 1, 0, [0.0], [0.0, 0.0, 0, 0.0, 0.0], 0, nil, 0, 3, false, nil)
      }.to raise_error(ArgumentError)
    end
  end

  describe '.sync' do
    it 'matches the Ruby mirror for hard and soft sync with every interpolator' do
      Numo::NArray.srand(4)
      pulses = Numo::SFloat.zeros(n)
      pulses[(0...n).step(37).to_a] = rand_input(0.01, 1)[(0...n).step(37).to_a]

      [w[:saw], w[:basic], w.from_samples(Numo::SFloat.new(2, 64).rand(-1, 1), mips: false), w.from_harmonics([[1, 0.5], [0.3, 1, 0.2]], complex: true)].each do |t|
        w::INTERPOLATIONS.each_key do |interp|
          [false, true].each do |soft|
            [[1000.0, nil, 0.0], [rand_input(100, 8000), rand_input(0.1, 0.9), rand_input(0, 1)]].each_with_index do |(f, width, scan), ci|
              s1 = [0.25, 0.0, 1.0, 3, 0]
              r1 = Numo::DFloat.zeros(MB::Sound::BandLimit::SYNC_TAPS * (t.complex? ? 2 : 1))
              s2 = s1.dup
              r2 = r1.dup

              a = t.sync(out_buffer(t), f, 1 / 48000.0, 0.9, 0.05, s1, r1, pulses, soft, width, scan, interp, 48000, true, t.mipped?).not_inplace!
              b = t.sync_ruby(out_buffer(t), f, 1 / 48000.0, 0.9, 0.05, s2, r2, pulses, soft, width, scan, interp, 48000, true, t.mipped?)
              expect(a.to_a).to eq(b.to_a), "#{t} #{interp} #{soft} #{ci}: max difference #{(a - b).abs.max}"
              expect(s1).to eq(s2)
              expect(r1.to_a).to eq(r2.to_a)
            end
          end
        end
      end
    end

    it 'takes 1 to 4 residual orders' do
      t = w[:saw]
      pulses = Numo::SFloat.zeros(n).tap { |z| z[[17, 100, 200]] = 0.4 }
      out = (1..4).map { |o|
        t.sync(Numo::SFloat.zeros(n), 1000.0, 1 / 48000.0, 1, 0, [0.0, 0.0, 1.0, 0, 0], Numo::DFloat.zeros(32), pulses, false, nil, 0, nil, 48000, true, true, orders: o).not_inplace!
      }
      expect((out[3] - out[1]).abs.max).to be > 1e-4
      expect { t.sync(Numo::SFloat.zeros(n), 1000.0, 1 / 48000.0, 1, 0, [0.0, 0.0, 1.0, 0, 0], Numo::DFloat.zeros(32), pulses, false, nil, 0, nil, 48000, true, true, orders: 5) }.to raise_error(ArgumentError)
    end

    it 'raises an error for a ring of the wrong size' do
      t = w.from_harmonics([1], complex: true)
      expect {
        t.sync(Numo::SComplex.zeros(10), 100, 1, 1, 0, [0.0, 0.0, 1.0, 0, 0], Numo::DFloat.zeros(32), nil, false, nil, 0, nil, 48000, true)
      }.to raise_error(ArgumentError, /Ring/)
    end
  end

  describe '.lookup' do
    it 'matches the Ruby mirror for every wrapping mode, interpolator, and kind of increment' do
      Numo::NArray.srand(2)
      phase = rand_input(-1.5, 2.5)
      incs = rand_input(-0.2, 0.2)
      scan = rand_input(-0.2, 1.2)
      slow = Numo::SFloat.new(n).seq * 0.003 - 0.7

      cycle_tables.each do |name, t|
        w::INTERPOLATIONS.each_key do |interp|
          w::WRAP_MODES.each do |wrap|
            [false, incs, 0.01, nil].each do |inc|
              [phase, slow].each do |ph|
                s1 = [0.25, 1, 0.003, 2]
                s2 = s1.dup
                a = t.lookup(out_buffer(t), ph, inc, scan, interp, 48000, wrap, s1)
                b = t.lookup_ruby(out_buffer(t), ph, inc, scan, interp, 48000, wrap, s2)
                expect(a.to_a).to eq(b.to_a), "#{name} #{interp} #{wrap} #{inc.class}: max difference #{(a - b).abs.max}"
                expect(s1).to eq(s2)
              end
            end
          end
        end
      end
    end

    it 'holds the peak phase change, then releases it' do
      t = w[:saw]
      state = [0.0, 1, 0.0, 0]
      jump = Numo::SFloat.new(100).fill(0.05)
      t.lookup(Numo::SFloat.zeros(100), jump, nil, 0, nil, 48000, :wrap, state)
      expect(state[2]).to be_within(1e-6).of(0.05)
      expect(state[3]).to eq(w::KernelRuby::HOLD - 99)

      still = Numo::SFloat.zeros(2000)
      t.lookup(Numo::SFloat.zeros(2000), still, nil, 0, nil, 48000, :wrap, state)
      expect(state[3]).to eq(0)
      expect(state[2]).to be < 0.05 * 0.995**900
    end
  end

  describe '.play' do
    it 'matches the Ruby mirror with loops, levels, complex data, and every interpolator' do
      Numo::NArray.srand(3)
      data = Numo::SFloat.new(5000).rand(-1, 1)

      [nil, 1000..3999, 0...100].each do |lp|
        [:octave, false].each do |mips|
          [false, true].each do |cx|
            t = w.from_samples(data, mode: :sample, root: 100.0, loop: lp, mips: mips, complex: cx)
            w::INTERPOLATIONS.each_key do |interp|
              [[133.0, 0.0], [rand_input(-500, 3000), 100.0], [100.0, 4990.0], [rand_input(-500, 3000), 3990.0]].each_with_index do |(f, pos), ci|
                st1 = [0.2]
                ts1 = [pos, 0.0, 0]
                st2 = st1.dup
                ts2 = ts1.dup

                a = t.play(out_buffer(t), f, 1 / 48000.0, t.speed(48000), 0.8, 0.0, st1, ts1, interp, 48000)
                b = t.play_ruby(out_buffer(t), f, 1 / 48000.0, t.speed(48000), 0.8, 0.0, st2, ts2, interp, 48000)
                expect(a.to_a).to eq(b.to_a), "#{lp} #{mips} #{cx} #{interp} #{ci}: max difference #{(a - b).abs.max}"
                expect(st1).to eq(st2)
                expect(ts1).to eq(ts2)
              end
            end
          end
        end
      end
    end

    it 'raises an error for a cycle-mode table' do
      expect {
        MB::Sound::FastWavetable.play(Numo::SFloat.zeros(10), w[:saw].kernel_spec(48000), 1, 1, 1, 1, 0, [0.0], [0.0, 0.0, 0, 0.0, 0.0], 3, nil)
      }.to raise_error(ArgumentError, /sample/)
    end
  end
end
