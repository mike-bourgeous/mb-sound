RSpec.describe(MB::Sound::Notes, 'acid helpers') do
  let(:transport) { MB::Sound::Sequence::Transport.new(bpm: 128) }
  # A sixteenth at 128 BPM, in samples
  let(:step) { 60.0 / 128 / 4 * 48000 }

  # Samples each of +nodes+ (through their own samplers) for +count+ samples
  def render(nodes, count)
    samplers = nodes.map(&:get_sampler)
    bufs = nodes.map { [] }
    (count / 800.0).ceil.times do
      samplers.each_with_index { |s, i| bufs[i] << s.sample(800).dup }
    end
    bufs.map { |b| b.reduce(:concatenate)[0...count] }
  end

  def peaks(data, step, count)
    count.times.map { |i| data[(i * step).round...((i + 1) * step).round].max }
  end

  describe '#accent' do
    it 'is 1 for accented notes and 0 for others, held per note' do
      n = MB::Sound.acid(MB::Sound::A1, !MB::Sound::A1, MB::Sound::A1, MB::Sound::R).notes(transport: transport)
      a, = render([n.accent], (step * 4).round)
      expect(a[0...step.round].to_a.uniq).to eq([0.0])
      expect(a[step.round...(2 * step).round].to_a.uniq).to eq([1.0])
      expect(a[(2 * step).round...(4 * step).round].to_a.uniq).to eq([0.0])
    end

    it 'takes a threshold' do
      n = MB::Sound.seq(MB::Sound::A1, !MB::Sound::A1).n16.notes(transport: transport)
      expect(n.accent(0.7)).to be_a(MB::Sound::Notes::Accent)
      a, = render([n.accent(0.7)], 100)
      expect(a[0]).to eq(1.0) # default velocity 0.75 >= 0.7
      expect(n.accent).to equal(n.accent)
    end
  end

  describe '#accent_sweep' do
    it 'builds up over consecutive accents like the 303 capacitor' do
      notes = [!MB::Sound::A1, !MB::Sound::A1, !MB::Sound::A1, MB::Sound::A1, MB::Sound::R, MB::Sound::R]
      n = MB::Sound.acid(*notes).notes(transport: transport)
      sweep, = render([n.accent_sweep(n.acid_env, resonance: 0.75)], (step * 6).round)
      p = peaks(sweep, step, 6)
      expect(p[0]).to be_within(0.01).of(0.57)
      expect(p[1]).to be_within(0.01).of(0.78)
      expect(p[2]).to be_within(0.01).of(0.86)
      expect(p[3]).to be < p[2] # discharging
      expect(p[5]).to be < 0.2
    end

    it 'ignores unaccented notes' do
      n = MB::Sound.acid(MB::Sound::A1, MB::Sound::A1).notes(transport: transport)
      sweep, = render([n.accent_sweep(n.acid_env)], (step * 2).round)
      expect(sweep.abs.max).to eq(0)
    end

    it 'is slower with more resonance' do
      sweeps = [0.0, 1.0].map { |r|
        n = MB::Sound.acid(!MB::Sound::A1, MB::Sound::R, MB::Sound::R, MB::Sound::R).notes(transport: transport)
        render([n.accent_sweep(n.acid_env, resonance: r)], (step * 4).round)[0]
      }
      # higher resonance: a lower first peak but a longer tail
      expect(sweeps[1].max).to be < sweeps[0].max
      expect(sweeps[1][-1]).to be > sweeps[0][-1]
    end
  end

  describe '#acid_env' do
    it 'decays over the accent decay on accented notes and +decay+ otherwise' do
      n = MB::Sound.acid(MB::Sound::A1, MB::Sound::R, MB::Sound::R, MB::Sound::R, !MB::Sound::A1, MB::Sound::R, MB::Sound::R, MB::Sound::R, gate: 2).notes(transport: transport)
      env, = render([n.acid_env(decay: 0.4, release: 0.5)], (step * 8).round)
      # gate 2: held for two steps (0.23 s); linear decays to 0
      normal = env[(0.1 * 48000).round]
      accented = env[(4 * step + 0.1 * 48000).round]
      expect(normal).to be_within(0.02).of(0.75)
      expect(accented).to be_within(0.02).of(0.5)
    end

    it 'does not restart on slid notes' do
      n = MB::Sound.acid(~MB::Sound::A1, MB::Sound::C2, MB::Sound::R, MB::Sound::R).notes(transport: transport)
      env, = render([n.acid_env(decay: 1)], (step * 2).round)
      s = step.round
      expect(env[s + 10]).to be < env[s - 10]
    end

    it 'takes a decay node' do
      n = MB::Sound.acid(MB::Sound::A1, MB::Sound::R).notes(transport: transport)
      env, = render([n.acid_env(decay: 0.4.constant)], 4800)
      expect(env[2400]).to be_within(0.02).of(0.875)
    end
  end
end
