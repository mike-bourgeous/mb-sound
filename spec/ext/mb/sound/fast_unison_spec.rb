require 'shellwords'

RSpec.describe('MB::Sound::FastUnison', :aggregate_failures) do
  let(:fast) { MB::Sound::FastUnison }
  let(:mirror) { MB::Sound::Unison::Detune::RubyKernel }
  let(:fractions) { MB::Sound::Unison.fractions(7, rng: Random.new(1)) }
  let(:positions) { fractions.map { |a| (a + 1) * 0.5 } }

  it 'loads when the GC runs at every allocation' do
    so = File.expand_path('../../../../lib/mb/sound/fast_unison.so', __dir__)
    code = 'require "bundler/setup"; require "numo/narray"; GC.stress = true; require ARGV[0]; GC.stress = false; p MB::Sound::FastUnison.respond_to?(:interp)'
    out = `ruby -e #{code.shellescape} #{so.shellescape} 2>&1`

    expect($?).to be_success, out
    expect(out.lines.last.to_s.strip).to eq('true'), out
  end

  # Calls +method+ on the kernel and the Ruby mirror with fresh output frames
  # and expects the same samples (and return values).
  def compare(method, n, *args)
    a = Numo::SFloat.zeros(7, n)
    b = Numo::SFloat.zeros(7, n)
    ra = fast.public_send(method, a, *args)
    rb = mirror.public_send(method, b, *args)
    expect(a).to eq(b), "#{method} n=#{n} #{args.drop(2).inspect}"
    expect(ra).to eq(rb)
    a
  end

  # Runs interp on the kernel and the mirror for a few buffers with their
  # own state arrays, expecting the same samples and states.
  def compare_interp(n, f, d, k, state = [1.01, 1.02, 0])
    sa = Numo::DFloat.cast(state)
    sb = sa.dup
    3.times do |i|
      a = Numo::SFloat.zeros(7, n)
      b = Numo::SFloat.zeros(7, n)
      expect(fast.interp(a, f, d, positions, sa, k)).to be_nil
      mirror.interp(b, f, d, positions, sb, k)
      expect(a).to eq(b), "interp n=#{n} k=#{k} buffer #{i}"
      expect(sa).to eq(sb)
    end
  end

  [1, 31, 128, 500].each do |n|
    context "with #{n} samples" do
      let(:rng) { Random.new(n) }
      let(:detune) { Numo::SFloat.new(n).rand(-1, 1) }
      let(:freq) { Numo::SFloat.new(n).rand(50, 2000) }

      it 'matches the Ruby mirror exactly in every mode, with a frequency buffer or number' do
        [freq, 220.0, 220].each do |f|
          compare(:exact, n, f, detune, fractions)
          compare(:scale, n, f, fractions.map { |a| 1 + a / 10 })
          [0, 1, 16, 32, 1000].each do |k|
            compare_interp(n, f, detune, k)
          end
          compare_interp(n, f, detune, 16, [1.0, 1.03, 5])
        end
      end

      it 'reads DFloat and view inputs as float32' do
        d = Numo::DFloat.new(n * 2).rand(-1, 1)[0...n]
        compare(:exact, n, freq.cast_to(Numo::DFloat), d, fractions)
        compare_interp(n, freq[0..], d, 16)
      end
    end
  end

  it 'computes the exact formula' do
    d = Numo::SFloat[0.1, 0.25, -0.5, 1]
    out = Numo::SFloat.zeros(3, 4)
    fast.exact(out, 440.0, d, [-1, 0, 0.5])
    expected = Numo::DFloat[-1, 0, 0.5].reshape(3, 1) * Numo::DFloat.cast(d).reshape(1, 4)
    expect(out.cast_to(Numo::DFloat)).to be_within(1e-4).of(440.0 * 2 ** (expected / 12))
  end

  it 'interpolates the outermost ratio between control points and spaces copies linearly in Hz' do
    d = Numo::SFloat.zeros(8).fill(1)
    r = 2 ** (1.0 / 12)

    # One control point per buffer (control 0): a ramp to the last sample's ratio
    out = Numo::SFloat.zeros(3, 8)
    state = Numo::DFloat[1, 1, 0]
    fast.interp(out, 100.0, d, [0, 0.5, 1], state, 0)
    expect(state[0]).to be_within(1e-12).of(r)
    expect(state[1]).to eq(state[0])
    expect(state[2]).to eq(0)
    upper = 100 * (1 + (r - 1) * Numo::DFloat.new(8).seq(1) / 8)
    expect(out[2, true].cast_to(Numo::DFloat)).to be_within(1e-4).of(upper)
    expect(out[0, true].cast_to(Numo::DFloat)).to be_within(1e-4).of(1e4 / upper)
    expect(out[1, true].cast_to(Numo::DFloat)).to be_within(1e-4).of((upper + 1e4 / upper) / 2)

    # Every 4 samples of the stream: ramps over the 4 samples after the
    # control point (here at the third sample of the buffer)
    out = Numo::SFloat.zeros(3, 8)
    state = Numo::DFloat[1, 1, 2]
    fast.interp(out, 100.0, d, [0, 0.5, 1], state, 4)
    # The next control point (sample 6) found the same ratio
    expect(state[0]).to be_within(1e-12).of(r)
    expect(state[1]).to eq(state[0])
    expect(state[2]).to eq(2)
    upper = 100 * (1 + (r - 1) * Numo::DFloat[0, 0, 0.25, 0.5, 0.75, 1, 1, 1])
    expect(out[2, true].cast_to(Numo::DFloat)).to be_within(1e-4).of(upper)
  end

  it 'rejects bad arguments' do
    out = Numo::SFloat.zeros(2, 4)
    d = Numo::SFloat.zeros(4)
    expect { fast.exact(Numo::SFloat.zeros(8), 1.0, d, [0, 1]) }.to raise_error(ArgumentError, /2D SFloat/)
    expect { fast.exact(Numo::DFloat.zeros(2, 4), 1.0, d, [0, 1]) }.to raise_error(ArgumentError, /2D SFloat/)
    expect { fast.exact(out, 1.0, Numo::SFloat.zeros(3), [0, 1]) }.to raise_error(ArgumentError, /detune/)
    expect { fast.exact(out, Numo::SFloat.zeros(5), d, [0, 1]) }.to raise_error(ArgumentError, /frequency/)
    expect { fast.exact(out, 1.0, d, [0]) }.to raise_error(ArgumentError, /one value per copy/)
    expect { fast.scale(out, 1.0, 5) }.to raise_error(TypeError)
    expect { fast.interp(out, 1.0, d, [0, 1], Numo::DFloat[1, 1, 0], -1) }.to raise_error(ArgumentError, /negative/)
    expect { fast.interp(out, 1.0, d, [0, 1], Numo::DFloat[1, 1], 4) }.to raise_error(ArgumentError, /state/)
    expect { fast.interp(out, 1.0, d, [0, 1], [1, 1, 0], 4) }.to raise_error(ArgumentError, /state/)
    expect { fast.interp(out, 1.0, d, [0, 1], Numo::DFloat[1, 1, 4], 4) }.to raise_error(ArgumentError, /phase/)
    expect { fast.interp(out, 1.0, d, [0, 1], Numo::DFloat[1, 1, 0].freeze, 4) }.to raise_error(FrozenError)
    expect { fast.exact(Numo::SFloat.zeros(4, 4)[true, 0...2], 1.0, Numo::SFloat.zeros(2), [0, 1, 0, 1]) }.to raise_error(ArgumentError, /contiguous/)
    expect { fast.exact(out.freeze, 1.0, d, [0, 1]) }.to raise_error(FrozenError)
  end
end
