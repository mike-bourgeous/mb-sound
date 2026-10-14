RSpec.describe('flam marks', :aggregate_failures) do
  let(:s) { MB::Sound }

  it 'marks notes, steps, and grid hits' do
    expect(MB::Sound::D2.flam[:flam]).to eq(true)
    expect(MB::Sound::D2.flam(25.ms)[:flam]).to be_within(1e-12).of(0.025)
    expect(MB::Sound::D2.flam(0.01).accent[:flam]).to eq(0.01)
    expect((!MB::Sound::D2).flam[:flam]).to eq(true)
    expect { MB::Sound::D2.flam(0) }.to raise_error(ArgumentError, /flam/)
    expect { MB::Sound::D2.flam(1) }.to raise_error(ArgumentError, /flam/)

    g = s.grid(16, snare: 'xfF.')
    ev = g[:snare].events
    expect(ev.map(&:flam)).to eq([nil, true, true])
    expect(ev.map(&:accented)).to eq([nil, nil, true])
    expect(ev[1].to_s).to end_with(' flam')
    expect(s.seq(MB::Sound::D2.flam(0.02)).events[0].to_s).to end_with(' flam20.0ms')
  end

  it 'survives clip transforms' do
    c = s.seq(MB::Sound::D2, MB::Sound::D2.flam).n16.loop
    expect(c.swing(0.6).events.map(&:flam)).to eq([nil, true])
    expect(c.transpose(2).events.map(&:flam)).to eq([nil, true])
    expect(c.reverse.events.map(&:flam).compact).to eq([true])
    expect(c.permute([1, 0], seed: 1).events.map(&:flam).compact).to eq([true])
  end

  it 'prints and loads back in steps, events rows, and graph documents' do
    c = s.seq(MB::Sound::D2, MB::Sound::D2.flam, MB::Sound::D2.flam(0.03), !MB::Sound::D2.flam).n8
    expect(c.to_ruby).to eq('seq(D2, D2.flam, D2.flam(0.03), !D2.flam).n8')
    ev = s.events([0, 1/8r, 38, 0.75, { flam: 0.02 }], [1/8r, 1/8r, 38, 0.75, { flam: true }], length: 1/2r)
    expect(ev.events.map(&:flam)).to eq([0.02, true])
    expect(ev.to_ruby).to include('{ flam: 0.02 }', '{ flam: true }')
    loaded = MB::Sound::GraphIO.load(MB::Sound::GraphIO.dump(s.tr909(c.loop, seed: 1), name: :f))
    expect(loaded).to be_a(MB::Sound::Drums::Kit)
    expect(MB::Sound::GraphIO.load('graph 2, name: "x"' + "\n" + 'tr909(seq(D2.flam(0.02)).loop)')).to be_a(MB::Sound::Drums::Kit)
  end

  it 'travels on MIDI streams as an Event field, not as MIDI 1.0 bytes' do
    e = MB::Sound::MIDI::Event.note_on(38, 0.8, flam: true)
    expect(e.flam).to eq(true)
    expect(e.bytes.bytes).to eq(MB::Sound::MIDI::Event.note_on(38, 0.8).bytes.bytes)
    expect(MB::Sound::MIDI::Event.note_on(38, 0.8, flam: 0.02).flam).to eq(0.02)

    notes = s.seq(MB::Sound::D2, MB::Sound::D2.flam, MB::Sound::D2.flam(0.03)).n4.notes
    m = []
    t = []
    # (the trigger first, as Drums::Flams reads them)
    80.times { t << notes.trigger.sample(800).dup; m << notes.flam_mark.sample(800).dup }
    m = Numo::SFloat.hstack(m)
    t = Numo::SFloat.hstack(t)
    hits = t.ne(0).where.to_a
    expect(hits.length).to eq(3)
    expect(hits.map { |i| m[i] }).to eq([0, MB::Sound::Notes::FlamMark::DEFAULT, Numo::SFloat[0.03][0]])
  end

  it 'plays on tr808 kits too, and kits only take swapped clips with flams if built for them' do
    plain = s.tr808(s.grid(16, snare: 'x...').loop)
    expect(plain.plays_clip?(s.seq(MB::Sound::D2.flam).n4)).to eq(false)
    flammy = s.tr808(s.seq(MB::Sound::D2, MB::Sound::D2.flam).n4.loop)
    expect(flammy.plays_clip?(s.seq(MB::Sound::D2.flam).n4)).to eq(true)
    x = []
    40.times { x << flammy.sample(800).dup }
    x = Numo::SFloat.hstack(x)
    step = (MB::Sound::Length.seconds(1.n4) * 48000).round
    flam = (MB::Sound::Drums::Machine::DEFAULT_FLAM * 48000).round
    # The second hit's grace stroke 16 ms early, then the full hit on the beat
    expect(x[(step - flam - 200)...(step - flam)].abs.max).to be < 1e-5 # the first hit's tail
    expect(x[(step - flam)...step].abs.max).to be > 0.05
    expect(x[step...(step + 2000)].abs.max).to be > x[(step - flam)...step].abs.max
  end
end
