# Scale lock for the virtual keyboard (ux-r3 item 44).
RSpec.describe(MB::Sound::UI::Keyboard::ScaleLock, :aggregate_failures) do
  let(:key) { MB::Sound::UI::Input::Key }
  let(:log) { [] }
  let(:out) {
    l = log
    Object.new.tap { |o|
      o.define_singleton_method(:note_on) { |n, _v, channel: 0, time: nil| l << n }
      o.define_singleton_method(:note_off) { |*_a, **_k| nil }
      o.define_singleton_method(:cc) { |*_a, **_k| nil }
    }
  }
  let(:kb) { MB::Sound::UI::Keyboard.new(out: out, clock: -> { 0.0 }, tempo: -> { 2.0 }, off_mode: :tap) }

  def play(keys)
    t = 0.0
    keys.each_char { |c| kb.key(key.of(c), t += 1) }
    log.dup.tap { log.clear }
  end

  it 'walks the scale on the white keys (degrees mode): D dorian from z' do
    kb.scale = MB::Sound.scale(:dorian, :d)
    # z is C3; the first D dorian note at or above it is C3 (D dorian has C)
    expect(play('zxcvbnm,')).to eq([48, 50, 52, 53, 55, 57, 59, 60].map { |n| MB::Sound.scale(:dorian, :d).snap(n, :up) })
    expect(play('zxcvbnm,').all? { |n| MB::Sound.scale(:dorian, :d).include?(n) }).to eq(true)
    # Every key, black ones too, is in the scale
    expect(play(MB::Sound::UI::Keyboard::KEYS.keys.join).all? { |n| MB::Sound.scale(:dorian, :d).include?(n) }).to eq(true)
    expect(kb.view.scale).to eq('D dorian')
  end

  it 'walks degrees of pentatonic scales too, one degree per white key' do
    sc = MB::Sound.scale(:minor_pentatonic, :a)
    kb.scale = sc
    notes = play('zxcvbnm')
    expect(notes).to eq(notes.sort)
    expect(notes.each_cons(2).map { |a, b| sc.degree(b)[0] - sc.degree(a)[0] }.uniq).to eq([1])
  end

  it 'snaps each key to the nearest scale note in snap mode, keeping the layout' do
    kb.scale = MB::Sound.scale(:major, :c)
    kb.scale_mode = :snap
    expect(play('zsxdc')).to eq([48, 48, 50, 50, 52]) # C, C#->C (ties go down), D, D#->D, E
    expect(kb.view.scale).to eq('C major (snap)')
  end

  it 'cycles scales and roots with PageUp and PageDown, and unlocks after the last scale' do
    kb.key(key.of(:page_up), 0.0)
    expect(kb.view.scale).to eq('C major')
    kb.key(key.of(:page_down), 0.0)
    expect(kb.view.scale).to eq('G major')
    kb.key(key.of(:page_up), 0.0)
    expect(kb.view.scale).to eq('G minor')
    (described_class::CYCLE.length - 2).times { kb.key(key.of(:page_up), 0.0) }
    expect(kb.scale_lock).to be_nil
    expect(play('zs')).to eq([48, 49])
  end

  it 'gives step entry the mapped notes (what a capture records is what was heard)' do
    kb.scale = MB::Sound.scale(:minor, :a)
    kb.entry = :step
    t = 0.0
    %w[z s x].each { |c| kb.key(key.of(c), t += 1) }
    notes = kb.step.clip.events.map(&:value)
    expect(notes.all? { |n| MB::Sound.scale(:minor, :a).include?(n) }).to eq(true)
  end

  it 'refuses what is not a Scale or a mode' do
    expect { kb.scale = :dorian }.to raise_error(ArgumentError, /needs a Scale/)
    expect { kb.scale_mode = :snap }.to raise_error(ArgumentError, /Lock a scale first/)
    kb.scale = MB::Sound.scale(:minor, :a)
    expect { kb.scale_mode = :wander }.to raise_error(ArgumentError, /modes are :degrees, :snap/)
  end
end
