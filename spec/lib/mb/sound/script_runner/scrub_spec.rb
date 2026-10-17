RSpec.describe(MB::Sound::ScriptRunner::Scrub) do
  let(:key) { MB::Sound::UI::Input::Key }

  describe 'the script screens\' key tables (UI::Keys)' do
    let(:keys) { MB::Sound::UI::Keys }

    it 'binds only actions live_ui acts on' do
      [keys::SONG_SCREEN, keys::SYNTH_SCREEN].each do |map|
        expect(map.entries.map(&:action).uniq - MB::Sound::ScriptRunner::SCREEN_ACTIONS).to eq([])
      end
    end

    it 'quits song screens with q or Esc, and makes Esc all notes off on synth and effect screens' do
      expect(keys::SONG_SCREEN[key.of(:escape)].name).to eq(:quit)
      expect(keys::SYNTH_SCREEN[key.of(:escape)].name).to eq(:panic)
      expect(keys::SONG_SCREEN[key.of(:left)].name).to eq(:bar_back)
      expect(keys::SONG_SCREEN[key.of(:page_down)].name).to eq(:scene_next)
    end
  end

  describe 'pressing Left and Right' do
    # A transport at 4/4 with a 2/4 bar at bar 5 (positions in whole notes)
    let(:transport) {
      MB::Sound::Sequence::Transport.new(bpm: 120).tap { |t| t.meter(1/2r, at: 4r); t.meter(1r, at: 4.5r) }
    }
    let(:now) { [100.0] }
    let(:seeks) { [] }
    let(:scrub) { MB::Sound::ScriptRunner::Scrub.new(transport, seek: ->(bar) { seeks << bar; transport.seek(transport.bar_position(bar)) }, clock: -> { now[0] }) }

    def at_bar(b) = transport.seek(transport.bar_position(b))

    it 'declares every (state, key) pair' do
      %i[idle back forward].each do |st|
        %i[left right].each { |k| expect(MB::Sound::ScriptRunner::Scrub::TABLE).to have_key([st, k]) }
      end
    end

    it 'goes to the start of the bar playing, then a bar back per press within the grace window, from the previous target' do
      at_bar(7.5r)
      expect(scrub.press(:left)).to eq(7)
      now[0] += 0.3
      transport.seek(transport.bar_position(7.1r)) # the playhead moved on after the seek
      expect(scrub.press(:left)).to eq(6)
      now[0] += 0.3
      expect(scrub.press(:left)).to eq(5) # (the 2/4 bar)
      now[0] += 0.3
      expect(scrub.press(:left)).to eq(4)
      expect(seeks).to eq([7, 6, 5, 4])
    end

    it 'counts from the playhead again after the grace window, going a bar back from a bar line' do
      at_bar(7.5r)
      scrub.press(:left)
      now[0] += MB::Sound::ScriptRunner::Scrub::GRACE + 0.01
      at_bar(7.25r)
      expect(scrub.press(:left)).to eq(7)
      now[0] += MB::Sound::ScriptRunner::Scrub::GRACE + 0.01
      at_bar(7)
      expect(scrub.press(:left)).to eq(6)
    end

    it 'steps a bar forward per Right press, from the target while chained' do
      at_bar(2.9r)
      expect(scrub.press(:right)).to eq(3)
      now[0] += 0.2
      expect(scrub.press(:right)).to eq(4)
      now[0] += 0.2
      at_bar(4.1r) # (playing on from the seek)
      expect(scrub.press(:left)).to eq(4) # direction change: the start of the bar playing
    end

    it 'accelerates while held (key repeats every 50 ms): 1 bar, then 2 after 1 s, 4 after 2 s' do
      at_bar(200)
      targets = [scrub.press(:left)]
      50.times { now[0] += 0.05; targets << scrub.press(:left) }
      steps = targets.each_cons(2).map { |a, b| a - b }
      expect(steps.first(19).uniq).to eq([1])
      expect(steps[20..38].uniq).to eq([2])
      expect(steps[40..].uniq).to eq([4])
    end

    it 'stops at bar 1' do
      at_bar(2.5r)
      scrub.press(:left)
      now[0] += 0.1
      expect(scrub.press(:left)).to eq(1)
      now[0] += 0.1
      expect(scrub.press(:left)).to eq(1)
    end
  end
end
