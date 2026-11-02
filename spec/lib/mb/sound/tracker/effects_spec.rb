# The trackers' per-tick pitch effect units (tracker-2): each keeps its
# state and gives one tick's value.
RSpec.describe(MB::Sound::Tracker::Effects, :aggregate_failures) do
  let(:fx) { MB::Sound::Tracker::Effects }

  describe 'Waveform' do
    it 'has ProTracker sine, ramp, and square cycles of 64 steps' do
      sine = fx::Waveform::TABLES[:protracker][0]
      expect(sine.length).to eq(64)
      expect(sine[16]).to eq(255)
      expect(sine[48]).to eq(-255)
      ramp = fx::Waveform::TABLES[:protracker][1]
      expect(ramp.values_at(0, 1, 31, 32, 63)).to eq([0, 8, 248, -256, -8])
      expect(fx::Waveform.value(:protracker, 2, 5)).to eq(256)
      expect(fx::Waveform.value(:protracker, 6, 40)).to eq(-256)
    end

    it 'mirrors the ramp for ST3 and gives IT its own tables (upward first, a half-cycle square)' do
      expect(fx::Waveform::TABLES[:st3][1].values_at(0, 1, 32, 63)).to eq([0, -8, 256, 8])
      it = fx::Waveform::TABLES[:it]
      expect(it[0].values_at(0, 4, 16, 32, 48)).to eq([0, -24, -64, 0, 64])
      expect(it[1].values_at(0, 32, 63)).to eq([-64, 0, 62])
      expect(it[2].values_at(0, 31, 32, 63)).to eq([-64, -64, 0, 0])
    end

    it 'plays waveform 3 (random) as the sine' do
      expect(fx::Waveform.value(:protracker, 3, 10)).to eq(fx::Waveform.value(:protracker, 0, 10))
    end
  end

  describe 'Oscillator' do
    def run(timing, ticks: 6, speed: 4)
      o = fx::Oscillator.new(kind: :protracker, timing: timing)
      Array.new(ticks) { |t| o.tick(t, speed) }.then { |v| [v, o.pos] }
    end

    it 'leaves the first tick alone in ProTracker timing, then reads and moves on' do
      v, pos = run(:protracker)
      expect(v).to eq([nil, 0, 97, 180, 235, 255])
      expect(pos).to eq(20)
    end

    it 'reads without moving on at the first tick in FastTracker timing' do
      v, pos = run(:fasttracker)
      expect(v).to eq([0, 0, 97, 180, 235, 255])
      expect(pos).to eq(20)
    end

    it 'moves on, then reads, on every tick in Impulse timing' do
      v, pos = run(:impulse)
      expect(v).to eq([97, 180, 235, 255, 235, 180])
      expect(pos).to eq(24)
    end

    it 'retriggers unless the waveform is 4-7' do
      o = fx::Oscillator.new
      o.pos = 30
      o.retrigger
      expect(o.pos).to eq(0)
      o.pos = 30
      o.wave = 4
      o.retrigger
      expect(o.pos).to eq(30)
    end

    it 'checks its timing' do
      expect { fx::Oscillator.new(timing: :amiga) }.to raise_error(ArgumentError, /timing/)
    end
  end

  describe 'Arpeggio' do
    it 'steps 0, x, y, or FT2\'s 0, y, x counted down from the speed' do
      expect(Array.new(6) { |t| fx::Arpeggio.semitones(0x47, t) }).to eq([0, 4, 7, 0, 4, 7])
      expect(Array.new(6) { |t| fx::Arpeggio.semitones(0x47, t, speed: 6, order: :fasttracker) }).to eq([0, 7, 4, 0, 7, 4])
      expect(Array.new(5) { |t| fx::Arpeggio.semitones(0x47, t, speed: 5, order: :fasttracker) }).to eq([7, 4, 0, 7, 4])
    end
  end

  describe 'Slide' do
    it 'moves toward a target and stops there' do
      expect(fx::Slide.toward(428, 214, 100)).to eq(328)
      expect(fx::Slide.toward(250, 214, 100)).to eq(214)
      expect(fx::Slide.toward(200, 214, 100)).to eq(214)
    end

    it 'keeps limits, or with none keeps above the floor' do
      expect(fx::Slide.by(850, 16, [113, 856])).to eq(856)
      expect(fx::Slide.by(850, 16, nil)).to eq(866)
      expect(fx::Slide.by(10, -16, nil)).to eq(1)
    end
  end

  it 'steps IT linear slides by 1/64 semitone below 16, by 1/16 semitone above' do
    expect([5, 15, 16, 19, 22, -22, 33].map { |u| fx.it_linear_units(u) }).to eq([5, 15, 16, 16, 20, -20, 32])
  end
end
