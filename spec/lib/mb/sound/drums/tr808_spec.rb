RSpec.describe(MB::Sound::Drums::TR808, :aggregate_failures) do
  # One accented hit (X) at 0 s and a plain hit (x) at 1 s (quarter notes at
  # 120 BPM), not looping.
  let(:hits) { MB::Sound.grid(4, 'X.x.') }

  # Samples +node+ in 800-sample buffers until it ends or +seconds+ pass.
  def collect(node, seconds = 5)
    out = []
    total = 0
    while total < seconds * 48000 && (buf = node.sample(800))
      out << buf.dup
      total += buf.length
    end
    Numo::SFloat.hstack(out)
  end

  def peak(data, from, to)
    data[(from * 48000).round...(to * 48000).round].abs.max
  end

  # Frequency from zero crossings between +from+ and +to+ seconds.
  def frequency(data, from, to)
    d = data[(from * 48000).round...(to * 48000).round]
    crossings = ((d[0...-1] * d[1..]) < 0).count_true
    crossings / 2.0 / (to - from)
  end

  described_class::VOICES.each do |name, defaults|
    describe ".#{name}" do
      it 'rings at its level for an accent, 6 dB lower for a plain hit, and ends' do
        data = collect(described_class.public_send(name, hits, level: 1))
        accent = peak(data, 0, 0.5)
        plain = peak(data, 1, 1.5)

        expect(accent).to be_between(0.7, 1.1)
        expect((plain / accent).to_db).to be_between(-8.5, -3.5)
        expect(data.length).to be < 48000 * (2 + defaults[:decay] * 1.3 + 0.5)
        expect(data[-4800..].abs.max).to be < 1e-3
      end

      it 'scales with level' do
        a = collect(described_class.public_send(name, hits, level: 1), 0.5)
        MB::Sound.seed(0)
        b = collect(described_class.public_send(name, hits, level: 0.5), 0.5)
        MB::Sound.seed(0)
        expect(peak(b, 0, 0.5)).to be_within(0.15 * peak(a, 0, 0.5)).of(0.5 * peak(a, 0, 0.5))
      end
    end
  end

  it 'plays a trigger signal' do
    trig = MB::Sound::ArrayInput.new(data: [Numo::SFloat[1, *([0] * 9599)]])
    data = collect(described_class.kick(trig))
    expect(peak(data, 0, 0.1)).to be > 0.5
  end

  it 'takes every hit of a MIDI source' do
    data = collect(described_class.cowbell(MB::Sound::Notes.new(MB::Sound.grid(4, 'x.x.'))))
    expect(peak(data, 0, 0.3)).to be > 0.2
    expect(peak(data, 1, 1.3)).to be > 0.2
  end

  it 'tunes the kick, and takes Pitches and nodes as knobs' do
    low = collect(described_class.kick(hits, tune: 45), 1)
    high = collect(described_class.kick(hits, tune: 60), 1)
    note = collect(described_class.kick(hits, tune: MB::Sound::A1), 1)
    moving = collect(described_class.kick(hits, tune: 50.constant), 1)

    expect(frequency(low, 0.1, 0.9)).to be_within(1.5).of(45)
    expect(frequency(high, 0.1, 0.9)).to be_within(1.5).of(60)
    expect(frequency(note, 0.1, 0.9)).to be_within(1.5).of(55)
    expect(frequency(moving, 0.1, 0.9)).to be_within(1.5).of(50)
  end

  it 'sweeps the kick pitch up at the strike by sigh' do
    # The first half cycle (positive) ends sooner when the pitch starts high
    half = ->(d) { (d[10..] < 0).where.to_a.first + 10 }
    data = collect(described_class.kick(hits, sigh: 1.0, tone: 0), 0.1)
    flat = collect(described_class.kick(hits, sigh: 0, tone: 0), 0.1)
    expect(half.(flat)).to be_within(20).of(48000 / 52 / 2)
    expect(half.(data)).to be < 0.8 * half.(flat)
  end

  it 'makes longer decays ring longer' do
    short = collect(described_class.kick(hits, decay: 0.3), 1)
    long = collect(described_class.kick(hits, decay: 2), 1)
    expect(peak(short, 0.4, 0.5)).to be < 1e-3 * 2
    expect(peak(long, 0.4, 0.5)).to be > 0.1
  end

  it 'adds snare noise with snappy' do
    hf = ->(snappy) {
      MB::Sound.seed(0)
      d = collect(described_class.snare(hits, snappy: snappy), 0.3)
      (d[1..] - d[0...-1]).abs.sum # high-frequency content
    }
    expect(hf.(1.0)).to be > 3 * hf.(0.05)
  end

  it 'keeps the snare heads short and the noise longer by default (round 2)' do
    heads = collect(described_class.snare(hits, snappy: 0), 1)
    MB::Sound.seed(0)
    full = collect(described_class.snare(hits), 1)
    # Heads ring 0.25 s to -60 dB: under -40 dB of their peak by 0.2 s
    expect(peak(heads, 0.2, 0.5) / peak(heads, 0, 0.1)).to be < 0.01
    # The noise (snappy 0.6: 0.25 s to -60 dB) is most of the first 50 ms
    noise = full[0...2400] - heads[0...2400]
    expect(Math.sqrt((noise**2).mean)).to be > Math.sqrt((heads[0...2400]**2).mean)
  end

  it 'brightens the kick click with tone' do
    hf = ->(tone) {
      d = collect(described_class.kick(hits, tone: tone), 0.02)
      (d[1..] - d[0...-1]).abs.max
    }
    expect(hf.(1.0)).to be > 2 * hf.(0.0)
  end

  it 'chokes the open hat with the choke source' do
    open = MB::Sound.grid(4, 'x...')
    closed = MB::Sound.grid(16, '..x.')
    data = collect(described_class.open_hat(open, choke: closed, decay: 2), 0.4)
    free = collect(described_class.open_hat(MB::Sound.grid(4, 'x...'), decay: 2), 0.4)
    # The closed hat hits at 0.25 s; the choke releases over 3 ms
    expect(peak(data, 0.27, 0.35)).to be < 0.01 * peak(data, 0, 0.1)
    expect(peak(free, 0.27, 0.35)).to be > 0.1 * peak(free, 0, 0.1)
  end

  it 'makes every hit full level with accent: 0' do
    data = collect(described_class.claves(hits, accent: 0), 1.5)
    expect(peak(data, 1, 1.5)).to be_within(0.01).of(peak(data, 0, 0.5))
  end

  describe 'velocity curves' do
    # Impulses at full velocity, the grid's plain velocity, and MIDI 64
    let(:heights) { [1.0, MB::Sound::Sequence::Clip::DEFAULT_VELOCITY, 64 / 127.0, 16 / 127.0] }
    def impulses
      MB::Sound::ArrayInput.new(data: [Numo::SFloat[*heights.flat_map { |h| [h, 0, 0, 0] }]])
    end

    def levels(curve, accent = 6)
      out = MB::Sound::Drums.accented(impulses, accent, curve: curve).sample(16)
      heights.each_index.map { |i| (out[i * 4] / out[0]).to_db }
    end

    it 'puts a grid x (velocity 0.75) accent dB below an X with :grid' do
      l = levels(:grid)
      expect(l[1]).to be_within(1e-4).of(-6)
      expect(l[2]).to be_within(0.01).of(-14.3)
      expect(levels(:grid, 12)[1]).to be_within(1e-4).of(-12)
    end

    it 'puts MIDI velocity 64 accent dB below 127 with :midi, about linear at 6 dB' do
      l = levels(:midi)
      expect(l[1]).to be_within(0.05).of(-2.5)
      expect(l[2]).to be_within(1e-4).of(-6)
      expect(l[3]).to be_within(0.01).of(20 * Math.log10(16 / 127.0) * 1.008)
      expect(levels(:midi, 12)[2]).to be_within(1e-4).of(-12)
    end

    it 'raises for an unknown curve' do
      expect { MB::Sound::Drums.accented(impulses, 6, curve: :log) }.to raise_error(ArgumentError, /Unknown velocity curve :log/)
    end

    it 'picks :grid for clips and grids, :midi for MIDI files, or the given curve' do
      expect(described_class.kick(hits).knobs[:velocity_curve]).to eq(:grid)
      expect(described_class.kick(MB::Sound::Notes.new(hits)).knobs[:velocity_curve]).to eq(:grid)
      expect(described_class.kick(MB::Sound::Notes.new('spec/test_data/c2_sustain.mid')).knobs[:velocity_curve]).to eq(:midi)
      expect(described_class.kick(hits, velocity_curve: :midi).knobs[:velocity_curve]).to eq(:midi)
      expect(MB::Sound.tr808('spec/test_data/c2_sustain.mid')[:kick].knobs[:velocity_curve]).to eq(:midi)
      expect(MB::Sound.tr808(MB::Sound.grid(4, kick: 'x')).voices.values.map { |v| v.knobs[:velocity_curve] }).to eq([:grid])
      expect(MB::Sound.tr808(MB::Sound.seq(36, 38)).voices.values.map { |v| v.knobs[:velocity_curve] }).to eq([:grid, :grid])
    end

    it 'plays MIDI velocity 64 6 dB quieter than 127 with :midi (14.3 dB with :grid)' do
      notes = ->(curve) {
        clip = MB::Sound::Sequence::Clip.new([127, 64].each_with_index.map { |v, i| MB::Sound::Sequence::Event.new(start: i / 2r, length: 1 / 8r, value: 75, velocity: v / 127.0) })
        collect(described_class.claves(clip, velocity_curve: curve), 2)
      }
      d = notes.(:midi)
      expect((peak(d, 1, 1.15) / peak(d, 0, 0.5)).to_db).to be_within(0.1).of(-6)
      d = notes.(:grid)
      expect((peak(d, 1, 1.15) / peak(d, 0, 0.5)).to_db).to be_within(0.1).of(-14.3)
    end
  end

  it 'raises for unknown voices and knobs' do
    expect { described_class.voice(:tabla, hits) }.to raise_error(ArgumentError, /Unknown TR-808 voice/)
    expect { described_class.kick(hits, snappy: 1) }.to raise_error(ArgumentError, /Unknown kick knob :snappy.*tune/)
  end

  it 'finds voices by alias, GM name, and GM note' do
    expect(described_class.voice_name(:bd)).to eq(:kick)
    expect(described_class.voice_name(:hat)).to eq(:closed_hat)
    expect(described_class.voice_name(:pedal_hat)).to eq(:closed_hat)
    expect(described_class.voice_name(:ride)).to eq(:cymbal)
    expect(described_class.voice_name(56)).to eq(:cowbell)
    expect(described_class.voice_name(:tambourine)).to be_nil
  end

  it 'routes every GM note to one voice' do
    notes = described_class::GM_MAP.values.flatten
    expect(notes.uniq.length).to eq(notes.length)
    expect(described_class::GM_MAP.keys.sort).to eq(described_class::VOICES.keys.sort)
  end

  describe MB::Sound::Drums::Voice do
    let(:tr808) { MB::Sound::Drums::TR808 }

    it 'skips an idle graph and wakes for the next hit, close to rendering every buffer' do
      pattern = MB::Sound.grid(4, 'x...').loop
      skipping = tr808.kick(pattern, decay: 0.2)
      exact = tr808.kick(MB::Sound.grid(4, 'x...').loop, decay: 0.2, skip_idle: false)
      a = collect(skipping, 4.5)
      b = collect(exact, 4.5)
      expect(skipping.skippable?).to eq(true)
      expect(exact.skippable?).to eq(false)
      expect(peak(a, 2, 2.5)).to be > 0.3
      expect((a - b).abs.max).to be < 1e-5
      expect(skipping.sleeping?).to eq(true)
    end

    it 'keeps knobs that follow notes in step while skipped' do
      notes = MB::Sound.seq(MB::Sound::A1, MB::Sound::A1, MB::Sound::E2, MB::Sound::E2).n4.loop
      kick = tr808.kick(MB::Sound.grid(4, 'x.x.').loop, tune: notes.freq, decay: 0.15, sigh: 0)
      data = collect(kick, 2)
      expect(kick.skippable?).to eq(true)
      # Hits at 0 s (A1) and 1 s (E2), the voice skipped in between
      expect(frequency(data, 0.02, 0.12)).to be_within(6).of(55)
      expect(frequency(data, 1.02, 1.12)).to be_within(8).of(82.4)
      expect(kick.sleeping?).to eq(true)
    end

    it 'never skips graphs with delays' do
      clap = tr808.clap(MB::Sound.grid(4, 'x...').loop)
      collect(clap, 0.1)
      expect(clap.skippable?).to eq(false)
    end

    it 'describes itself' do
      v = tr808.kick(hits, tune: 48)
      expect(v.to_s).to include('kick', 'tune: 48')
      expect(v.name).to eq(:kick)
      expect(v.knobs[:tune]).to eq(48)
      expect(v.notes.length).to eq(1)
    end
  end
end
