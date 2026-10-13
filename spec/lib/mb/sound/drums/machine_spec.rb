RSpec.describe(MB::Sound::Drums::Machine, :aggregate_failures) do
  def collect(node, seconds = 1, buffer = 800)
    out = []
    total = 0
    while total < seconds * 48000 && (buf = node.sample(buffer))
      out << buf.dup
      total += buf.length
    end
    # Pads kits that ended (finite grids) with zeros
    n = (seconds * 48000).round
    x = Numo::SFloat.zeros(n)
    d = Numo::SFloat.hstack(out)
    x[0...MB::M.min(n, d.length)] = d[0...MB::M.min(n, d.length)]
    x
  end

  # The sample indices of the hits of a voice whose block returns its
  # trigger.
  def hits(node, seconds = 1)
    collect(node, seconds).ne(0).where.to_a
  end

  # One 16th note in samples at the transport's tempo.
  let(:step) { (MB::Sound::Length.seconds(1.n16) * 48000).round }

  let(:trigger_kit) {
    MB::Sound.kit {
      voice(:kick) { |h| h.t }
      voice(:snare) { t }
    }
  }

  describe 'MB::Sound.kit' do
    it 'returns a Machine without a source and a Kit with one' do
      expect(trigger_kit).to be_a(MB::Sound::Drums::Machine)
      expect(trigger_kit.names).to eq([:kick, :snare])
      kit = trigger_kit.kit(MB::Sound.grid(16, kick: 'x...', sd: '..x.'))
      expect(kit).to be_a(MB::Sound::Drums::Kit)
      expect(kit.names).to eq([:kick, :snare])
      expect(kit.machine).to eq(:kit)
      expect(trigger_kit.(MB::Sound.grid(16, kick: 'x...'))).to be_a(MB::Sound::Drums::Kit)
      expect(MB::Sound.kit(MB::Sound.grid(16, kick: 'x...')) { voice(:kick) { t } }).to be_a(MB::Sound::Drums::Kit)
    end

    it 'runs blocks with a parameter on the builder and hit, and without on them' do
      a = MB::Sound.kit(MB::Sound.grid(16, kick: 'x.x.'), seed: 1) { |k| k.voice(:kick, tune: 50) { |h| h.body(h.tune, decay: 0.2) } }
      b = MB::Sound.kit(MB::Sound.grid(16, kick: 'x.x.'), seed: 1) { voice(:kick, tune: 50) { body(tune, decay: 0.2) } }
      x = collect(a, 0.5)
      expect(x.abs.max).to be > 0.3
      expect(collect(b, 0.5)).to eq(x)
    end

    it 'plays hits on exact samples at the grid times' do
      expect(hits(trigger_kit.kit(MB::Sound.grid(16, kick: 'x...x...')))).to eq([0, 4 * step])
      expect(hits(trigger_kit.kit(MB::Sound.grid(16, snare: '..x.')))).to eq([2 * step])
    end

    it 'routes grid rows by voice name, alias, and GM name' do
      m = MB::Sound.kit { voice(:kick, as: :boom) { t }; voice(:closed_hat) { t } }
      expect(m.kit(m.grid(16, boom: 'x...', hh: '..x.')).names).to eq([:kick, :closed_hat])
      expect(m.kit(MB::Sound.grid(16, kick: 'x...', hh: '..x.')).names).to eq([:kick, :closed_hat])
      expect(m.voice_name(:bd)).to eq(:kick)
      expect(m.voice_name(36)).to eq(:kick)
      expect(m.voice_name(:hat)).to eq(:closed_hat)
      expect { m.kit(MB::Sound.grid(16, snare: 'x...')) }.to raise_error(ArgumentError, /snare.*voice/)
    end

    it 'routes MIDI by GM notes, gm:, and map:' do
      m = MB::Sound.kit { voice(:kick) { t }; voice(:zap, gm: 60) { t }; voice(:quiet) { t } }
      expect(m.voices[:kick].gm).to eq([36])
      expect(m.voices[:quiet].gm).to eq([])
      clip = MB::Sound.seq(36, 60, 36, 60).n16
      kit = m.kit(clip)
      expect(kit.names).to eq([:kick, :zap])
      expect(hits(kit[:zap], 0.6)).to eq([step, 3 * step])
      expect(m.kit(clip, map: { kick: 60 }, only: :kick).names).to eq([:kick])
      expect(hits(m.kit(clip, map: { kick: 60 }, only: :kick), 0.6)).to eq([step, 3 * step])
    end

    it 'checks knobs, names, and blocks' do
      m = MB::Sound.kit { voice(:kick, tune: 50) { t } }
      expect { m.kit(MB::Sound.grid(16, kick: 'x'), kick: { tun: 4 }) }.to raise_error(ArgumentError, /Unknown kick knob :tun.*:tune/)
      expect { m.kit(MB::Sound.grid(16, kick: 'x'), snare: {}) }.to raise_error(ArgumentError, /Unknown kit voice :snare/)
      expect { MB::Sound.kit { voice(:kick, noise: 1) { t } } }.to raise_error(ArgumentError, /noise.*Hit method/)
      expect { MB::Sound.kit { voice(:kick, accent: 1) { t } } }.to raise_error(ArgumentError, /accent/)
      expect { MB::Sound.kit { voice(:kick) } }.to raise_error(ArgumentError, /needs a block/)
      expect { MB::Sound.kit { voice(:kick) { t }; voice(:kick) { t } } }.to raise_error(ArgumentError, /already/)
      expect { MB::Sound.kit { voice(:kick) { 5 } }.kit(MB::Sound.grid(16, kick: 'x')) }.to raise_error(ArgumentError, /not a graph node/)
      expect { MB::Sound.kit { } }.to raise_error(ArgumentError, /at least one voice/)
      expect { MB::Sound.kit { voice(:kick) { bdy(50) } }.kit(MB::Sound.grid(16, kick: 'x')) }.to raise_error(NoMethodError, /bdy/)
    end

    it 'applies level, accent, and the velocity curve per voice' do
      m = MB::Sound.kit { voice(:kick, level: 0.5) { t } }
      g = MB::Sound.grid(16, kick: 'X.x.')
      x = collect(m.kit(g), 0.5)
      expect(x[0]).to be_within(1e-6).of(0.5)
      expect(20 * Math.log10(x[0] / x[2 * step])).to be_within(1e-3).of(6)
      y = collect(m.kit(g, kick: { accent: 12, level: 1 }), 0.5)
      expect(20 * Math.log10(y[0] / y[2 * step])).to be_within(1e-3).of(12)
    end

    it 'takes nodes as knobs' do
      m = MB::Sound.kit { voice(:kick, tune: 50) { |h| h.body(h.tune, decay: 0.3) } }
      x = collect(m.kit(MB::Sound.grid(16, kick: 'x...'), kick: { tune: 80.constant }), 0.2)
      expect(x.abs.max).to be > 0.3
    end

    describe 'chokes' do
      let(:m) {
        MB::Sound.kit {
          voice(:closed_hat) { |h| h.velocity }
          voice(:open_hat) { |h| h.velocity }
          choke :open_hat, by: :closed_hat
        }
      }

      it 'cuts a voice off over 3 ms at a hit of its choker, back on at its own hit' do
        kit = m.kit(MB::Sound.grid(16, oh: 'x...x...', ch: '..x.....'))
        x = collect(kit[:open_hat], 0.7)
        c = 2 * step
        expect(x[c - 1]).to be > 0.4
        expect(x[c + 1]).to be < x[c - 1]
        expect(x[c + 144...(4 * step)].abs.max).to eq(0)
        expect(x[4 * step]).to be > 0.4
        expect(collect(kit[:closed_hat], 0.7)[c]).to be > 0.4
      end

      it 'makes groups whose hits cut off each other' do
        m2 = MB::Sound.kit { voice(:a, gm: 60) { |h| h.velocity }; voice(:b, gm: 61) { |h| h.velocity }; choke :a, :b }
        expect(m2.chokes).to eq(a: [:b], b: [:a])
        kit = m2.kit(m2.grid(16, a: 'x...', b: '..x.'))
        a = collect(kit[:a], 0.6)
        expect(a[2 * step + 200]).to eq(0)
        expect { MB::Sound.kit { voice(:a) { t }; choke :a } }.to raise_error(ArgumentError, /two or more/)
        expect { MB::Sound.kit { voice(:a) { t }; choke :a, :zz } }.to raise_error(ArgumentError, /Unknown kit voice :zz/)
      end

      it 'lets a hit win over a choke on the same sample' do
        kit = m.kit(MB::Sound.grid(16, oh: 'x...', ch: 'x...'))
        expect(collect(kit[:open_hat], 0.1)[100]).to be > 0.4
      end
    end

    describe 'shuffle and flams' do
      it 'delays every second 16th by shuffle / 48 beat (909 steps) or by a swing amount' do
        g = MB::Sound.grid(16, kick: 'xxxx')
        beat = 4 * step
        expect(hits(trigger_kit.kit(g, shuffle: 0), 0.6)).to eq([0, step, 2 * step, 3 * step])
        expect(hits(trigger_kit.kit(g, shuffle: 2), 0.6)).to eq([0, step + (beat * 2 / 48r).floor, 2 * step, 3 * step + (beat * 2 / 48r).floor])
        expect(hits(trigger_kit.kit(g, shuffle: 2 / 3r), 0.6)).to eq([0, (step * 4 / 3r).floor, 2 * step, 2 * step + (step * 4 / 3r).floor])
        expect { trigger_kit.kit(g, shuffle: 1.5) }.to raise_error(ArgumentError, /Shuffle/)
        expect { trigger_kit.kit(MB::Sound.midi_file('spec/test_data/c2_sustain.mid'), shuffle: 2) }.to raise_error(ArgumentError, /grids and clips/)
      end

      it 'plays flams as a grace stroke and the hit flam: later' do
        kit = trigger_kit.kit(MB::Sound.grid(16, kick: 'x...'), flams: MB::Sound.grid(16, kick: '..X.'), flam: 10.ms)
        x = collect(kit, 0.6)
        expect(x.ne(0).where.to_a).to eq([0, 2 * step, 2 * step + 480])
        grace = MB::Sound::Drums::Machine::FLAM_GRACE**(MB::Sound::Drums::DEFAULT_ACCENT / -(20 * Math.log10(0.75)))
        expect(x[2 * step] / x[2 * step + 480]).to be_within(1e-5).of(grace)
        only = trigger_kit.kit(MB::Sound.grid(16, kick: 'x...'), flams: MB::Sound.grid(16, snare: 'x...'), kick: { flam: 0.001 })
        expect(only.names).to eq([:kick, :snare])
        expect(hits(only[:snare], 0.1)).to eq([0, (MB::Sound::Drums::Machine::DEFAULT_FLAM * 48000).round])
      end
    end

    it 'gives separate outputs that add up to the mix' do
      m = MB::Sound.kit {
        voice(:kick) { |h| h.body(50, decay: 0.2) }
        voice(:snare) { |h| h.noise(decay: 0.1) }
      }
      g = MB::Sound.grid(16, kick: 'x.x.', snare: '.x.x').loop
      outs = m.kit(g, outputs: :separate, seed: 3)
      expect(outs.names).to eq([:kick, :snare])
      expect(outs.graph_node_name).to eq('kit outputs')
      mix = collect(m.kit(g, seed: 3), 0.5)
      sum = Array.new(30) { b = outs.map { |o| o.sample(800).dup }; b[0] + b[1] }
      expect(Numo::SFloat.hstack(sum)[0...24000]).to eq(mix)
    end

    it 'plays samples as voices' do
      smp = MB::Sound::Sample.new(Numo::SFloat.new(2400).seq(1, -1 / 2400.0))
      kit = MB::Sound.kit(MB::Sound.grid(16, kick: 'X...')) { voice :kick, smp }
      x = collect(kit, 0.2)
      expect(x[0..1000].abs.max).to be > 0.9
      expect(x[3000..].abs.max).to eq(0)
      up = collect(MB::Sound.kit(MB::Sound.grid(16, kick: 'X...'), kick: { tune: 12 }) { voice :kick, smp }, 0.2)
      expect(up[1250..].abs.max).to be < 1e-3
      expect { MB::Sound.kit { voice(:kick, smp) { t } } }.to raise_error(ArgumentError, /not both/)
    end

    it 'borrows voices from the TR-808 and TR-909' do
      m = MB::Sound.kit {
        tr909 :kick, :closed_hat, :open_hat, kick: { decay: 0.3 }
        tr808 :cowbell, :cb
      }
      expect(m.names).to eq([:kick, :closed_hat, :open_hat, :cowbell])
      expect(m.voices[:kick].defaults[:decay]).to eq(0.3)
      expect(m.chokes).to eq(open_hat: [:closed_hat])
      expect(m.voice_name(:bell)).to eq(:cowbell)
      expect(m.voices[:cowbell].gm).to eq([56])
      x = collect(m.kit(MB::Sound.grid(16, kick: 'x...', cb: '..x.')), 0.5)
      expect(x[0...step].abs.max).to be > 0.3
      expect(x[2 * step..].abs.max).to be > 0.05
      expect { MB::Sound.kit { tr808 :zz } }.to raise_error(ArgumentError, /Unknown tr808 voice :zz/)
      expect { MB::Sound.kit { tr909 :kick, snare: {} } }.to raise_error(ArgumentError, /No :snare among/)
    end

    it 'has every layer working, the same at any buffer size' do
      smp = MB::Sound::Sample.new(Numo::SFloat.new(4800).rand(-1, 1))
      m = MB::Sound.kit {
        voice(:kick, tune: 50) { |h| h.body(h.tune, sweep: 3, drop: 0.3).softclip(0.6) + h.click(0.4) }
        voice(:snare) { |h| h.fm(200, ratio: 1.5, index: 1, index_decay: 0.05, sweep: 0.5) + h.noise(highpass: 1000, lowpass: 8000, bandpass: 3000) }
        voice(:clap) { |h| h.noise(decay: 0.02) * 0 + MB::Sound::Drums.decay_env(h.bursts(3, 0.01, falloff: 0.5), 0.005) }
        voice(:closed_hat, decay: 0.05) { metal.filter(:highpass, cutoff: 7000) * env(decay) }
        voice(:open_hat) { |h| h.sample(smp, tune: 3, decay: 0.2) + h.sample(smp, tune: 0.5.hz.lfo.at(-2..2)) }
        choke :open_hat, :closed_hat
      }
      g = MB::Sound.grid(16, kick: 'X.x.x...', snare: '..x...X.', clap: 'x...', hh: 'x.x.x..x', oh: '.x...x..').loop
      ref = collect(m.kit(g, seed: 9), 1.2, 800)
      expect(ref.abs.max).to be > 0.5
      [7, 367, 2048].each do |bs|
        expect(collect(m.kit(g, seed: 9), 1.2, bs)).to eq(ref)
      end
    end
  end

  describe 'graph documents' do
    it 'saves kits as their blocks and loads them without running code' do
      g = MB::Sound.grid(16, kick: 'X...x...', snare: '....x...', hat: 'x.x.x.x.', oh: '..x...x.', cb: 'x..x..x.').loop
      k = MB::Sound.kit(g, seed: 4) {
        voice :kick, tune: 45 do
          body(tune, decay: 0.5, sweep: 4).softclip(0.6) + click(0.3)
        end
        voice(:snare, snappy: 0.5) { |h| h.fm(330, ratio: 2.3, index: 2, decay: 0.15) * 0.4 + h.noise(decay: 0.2, highpass: 2000) * h.snappy }
        tr909 :closed_hat, :open_hat, open_hat: { decay: 0.5 }
        tr808 :cowbell
      }
      text = MB::Sound::GraphIO.dump(k, name: :mine)
      expect(text).to include('kit(grid(16, kick: "X...x..."', 'voice :kick, tune: 45 do', 'tr808 :cowbell')
      loaded = MB::Sound::GraphIO.load(text)
      expect(collect(loaded, 0.5)).to eq(collect(k, 0.5))

      m = MB::Sound.kit { |b| b.voice(:kick) { |h| h.body(50) } }
      k2 = m.kit(MB::Sound.grid(16, kick: 'x...'), seed: 1)
      expect(k2.to_ruby).to be_a(String)
    end

    it 'refuses unknown methods and code in kit blocks' do
      expect { MB::Sound::GraphIO.load("kit(grid(16, kick: 'x...')) { voice(:kick) { bdy(50) } }") }.to raise_error(MB::Sound::GraphIO::LoadError, /bdy.*did you mean body/)
      expect { MB::Sound::GraphIO.load("kit(grid(16, kick: 'x...')) { voice(:kick) { |h| h.system('ls') } }") }.to raise_error(MB::Sound::GraphIO::LoadError, /system/)
      expect { MB::Sound::GraphIO.load("kit(grid(16, kick: 'x...')) { voice(:kick) { |h| h.instance_variable_get(:@knobs) } }") }.to raise_error(MB::Sound::GraphIO::LoadError)
      expect { MB::Sound::GraphIO.load("kit(grid(16, kick: 'x...')) { voice(:kick) { |h| h.bursts(10**7, 0.001) } }") }.to raise_error(MB::Sound::GraphIO::LoadError, /bursts/)
    end
  end

  describe MB::Sound::Drums::Repeats do
    it 'repeats each hit at exact delays and gains, at any buffer size' do
      t = MB::Sound.grid(16, 'x..x').loop.notes.trigger
      ref = nil
      [800, 1, 333].each do |bs|
        r = MB::Sound::Drums::Repeats.new(MB::Sound.grid(16, 'x..x').loop.notes.trigger, [[0, 1], [1.ms, 0.5], [3.samples, 0.25]])
        x = collect(r, 0.5, bs)
        ref ||= x
        expect(x).to eq(ref)
      end
      expect(ref.ne(0).where.to_a.first(3)).to eq([0, 3, 48])
      expect(ref[48]).to be_within(1e-6).of(ref[0] * 0.5)
      expect(ref[3]).to be_within(1e-6).of(ref[0] * 0.25)
      expect(t).to be_a(MB::Sound::GraphNode)
      expect { MB::Sound::Drums::Repeats.new(t, []) }.to raise_error(ArgumentError, /at least one/)
      expect { MB::Sound::Drums::Repeats.new(t, [[-1, 1]]) }.to raise_error(ArgumentError, /0 seconds or more/)
    end
  end

  describe MB::Sound::Drums::ChokeGate do
    it 'ramps to 0 after a choke and returns to 1 at a hit, at any buffer size' do
      ref = nil
      [800, 7, 1].each do |bs|
        g = MB::Sound::Drums::ChokeGate.new(MB::Sound.grid(16, 'x...').loop.notes.trigger, MB::Sound.grid(16, '..x.').loop.notes.trigger)
        x = collect(g, 0.6, bs)
        ref ||= x
        expect(x).to eq(ref)
      end
      c = 2 * step
      expect(ref[0...c].to_a.uniq).to eq([1.0])
      expect(ref[c]).to eq(1.0)
      expect(ref[c + 72]).to be_within(1e-6).of(0.5)
      expect(ref[(c + 144)...(4 * step)].to_a.uniq).to eq([0.0])
      expect(ref[4 * step]).to eq(1.0)
    end
  end
end
