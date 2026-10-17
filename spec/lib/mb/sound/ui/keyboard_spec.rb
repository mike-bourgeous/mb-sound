require_relative '../../../../support/ui_helpers'

# The virtual keyboard's model (UI::Keyboard): rows, note-off modes with a
# fake clock (legacy autorepeats, kitty releases), no stuck notes, and step
# entry.
RSpec.describe(MB::Sound::UI::Keyboard, :aggregate_failures) do
  # Records what the keyboard sends (as a MIDI::VirtualInput would get it).
  class KeyboardRecorder
    attr_reader :log

    def initialize = @log = []
    def note_on(n, v, channel: 0, time: nil) = @log << [:on, n, (v * 127).round, channel, time&.round(4)]
    def note_off(n, _v = nil, channel: 0, time: nil) = @log << [:off, n, channel, time&.round(4)]
    def cc(i, v, channel: 0, time: nil) = @log << [:cc, i, v, channel, time&.round(4)]

    # Notes sounding after everything logged.
    def sounding
      @log.each_with_object({}) { |(kind, n, *), h| kind == :on ? h[n] = true : kind == :off ? h.delete(n) : nil }.keys
    end
  end

  let(:key) { MB::Sound::UI::Input::Key }
  let(:out) { KeyboardRecorder.new }
  let(:kb) { MB::Sound::UI::Keyboard.new(out: out, clock: -> { 0.0 }, tempo: -> { 2.0 }) }

  def press(ch, t, *mods, type: :press) = kb.key(key.of(ch, *mods, type: type), t)

  # Holds +ch+ from +t+ to +up+ as a legacy terminal sends it: a press,
  # then after +delay+ a press every +interval+ while held.
  def hold(ch, t, up, delay: 0.5, interval: 0.035)
    press(ch, t)
    r = t + delay
    while r < up
      press(ch, r)
      kb.tick(r)
      r += interval
    end
  end

  describe 'rows' do
    it 'plays jack-keyboard rows from C3 (z) and C4 (q), with octave, velocity, and channel keys' do
      kb.releases = true
      %w[z s / q 2 \\].each { |c| press(c, 0.0); press(c, 0.0, type: :release) }
      expect(out.log.select { |e| e[0] == :on }.map { |e| e[1] }).to eq([48, 49, 64, 60, 61, 81])

      out.log.clear
      press('+', 0.0)
      press(:right, 0.0)
      press(:up, 0.0)
      press(:end, 0.0)
      press('z', 0.0)
      press('Z', 0.0) # Shift: accent
      press('<', 0.0) # Shift-, on a US layout
      press('c', 0.0, :ctrl) # soft (legacy Ctrl-letters decode the same)
      expect(out.log.select { |e| e[0] == :on }.map { |e| e[1..3] }).to eq([[72, 104, 1], [72, 127, 1], [84, 127, 1], [76, 40, 1]])
      expect(kb.view.base).to eq(72)
      expect(kb.view.channel).to eq(1)
      press('-', 0.0)
      expect(kb.base).to eq(60)
      expect(out.sounding).to be_empty # moving the octave ended the notes
    end

    it 'says which keys are not its own' do
      expect(press('k', 0.0)).to eq(false)
      expect(press(:f5, 0.0)).to eq(false)
      expect(out.log).to be_empty
    end
  end

  describe 'with key releases (kitty protocol)' do
    before { kb.releases = true }

    it 'ends notes on release, ignores repeats, and strikes again on a press without a release' do
      expect(kb.resolved_mode).to eq(:release)
      press('z', 0.0)
      press('z', 0.5, type: :repeat)
      press('z', 0.6, type: :repeat)
      press('z', 0.7, type: :release)
      press('x', 1.0)
      press('x', 1.2) # a lost release
      press('x', 1.3, type: :release)
      expect(out.log).to eq([[:on, 48, 96, 0, 0.0], [:off, 48, 0, 0.7], [:on, 50, 96, 0, 1.0], [:off, 50, 0, 1.2], [:on, 50, 96, 0, 1.2], [:off, 50, 0, 1.3]])
    end

    it 'holds the sustain pedal while Space is down' do
      press(' ', 0.0)
      press(' ', 0.4, type: :repeat)
      press(' ', 1.0, type: :release)
      expect(out.log).to eq([[:cc, 64, 1.0, 0, 0.0], [:cc, 64, 0.0, 0, 1.0]])
    end
  end

  describe 'without key releases (legacy terminals)' do
    it 'plays fixed-length notes by default (maintainer, 2026-10-16)' do
      expect(kb.off_mode).to eq(:auto)
      expect(kb.resolved_mode).to eq(:tap)
      press('z', 0.0)
      kb.tick(0.25)
      expect(out.log).to eq([[:on, 48, 96, 0, 0.0], [:off, 48, 0, 0.25]])
    end

    it 'holds a key while it autorepeats and ends it 2.5 intervals after the last repeat' do
      kb.off_mode = :hold
      expect(kb.resolved_mode).to eq(:hold)
      hold('z', 1.0, 2.0)
      last = 1.0 + 0.5 + 0.035 * 14 # the last repeat before 2.0
      expect(kb.wait(last)).to be_within(1e-9).of(0.035 * 2.5 + 0.03)
      kb.tick(last + 0.035 * 2.5 + 0.03 - 1e-6)
      expect(out.sounding).to eq([48])
      kb.tick(last + 0.035 * 2.5 + 0.03)
      expect(out.log).to eq([[:on, 48, 96, 0, 1.0], [:off, 48, 0, (last + 0.035 * 2.5 + 0.03).round(4)]])
    end

    it 'ends a tap after the repeat delay and a little more, and strikes again when tapped quickly' do
      kb.off_mode = :hold
      press('z', 0.0)
      press('z', 0.2) # faster than any autorepeat delay: a new strike
      kb.tick(0.81)
      kb.tick(0.83)
      expect(out.log).to eq([[:on, 48, 96, 0, 0.0], [:off, 48, 0, 0.2], [:on, 48, 96, 0, 0.2], [:off, 48, 0, 0.82]])
    end

    it 'learns the repeat delay and interval' do
      kb.off_mode = :hold
      hold('z', 0.0, 1.5, delay: 0.3, interval: 0.03)
      kb.tick(5)
      tracker = kb.instance_variable_get(:@tracker)
      expect(tracker.delay).to be_within(0.001).of(0.4) # halfway from 0.5 after one hold
      expect(tracker.interval).to be_within(0.002).of(0.03)
    end

    it 'holds a chord as long as its last key repeats (the OS repeats only that one)' do
      kb.off_mode = :hold
      press('z', 0.0)
      press('c', 0.02)
      hold('b', 0.04, 2.0)
      expect(out.sounding.sort).to eq([48, 52, 55])
      kb.tick(2.2)
      expect(out.sounding).to be_empty
      offs = out.log.select { |e| e[0] == :off }.map(&:last).uniq
      expect(offs.length).to eq(1) # all three at once
    end

    it 'plays fixed lengths in :tap mode without retriggering on autorepeat' do
      kb.off_mode = :tap
      kb.tap = 0.2
      hold('z', 0.0, 1.0)
      kb.tick(2)
      expect(out.log).to eq([[:on, 48, 96, 0, 0.0], [:off, 48, 0, 0.2]])
    end

    it 'holds each note until the next one in :legato mode, the new note first' do
      kb.off_mode = :legato
      press('z', 0.0)
      press('x', 0.3)
      press('x', 0.8) # an autorepeat
      kb.tick(5)
      expect(out.log).to eq([[:on, 48, 96, 0, 0.0], [:on, 50, 96, 0, 0.3], [:off, 48, 0, 0.3]])
      expect(out.sounding).to eq([50])
      kb.all_off(6.0)
      expect(out.sounding).to be_empty
    end

    it 'toggles the sustain pedal with Space, and Esc turns everything off' do
      press(' ', 0.0)
      press('z', 0.1)
      press(:escape, 0.2)
      expect(out.log).to eq([[:cc, 64, 1.0, 0, 0.0], [:on, 48, 96, 0, 0.1], [:off, 48, 0, 0.2], [:cc, 64, 0.0, 0, 0.2], [:cc, 123, 0.0, 0, 0.2]])
      expect(kb.view.sustain).to eq(false)
    end
  end

  it 'never leaves notes sounding: all_off in every mode' do
    %i[release hold tap legato].each do |mode|
      kb.off_mode = mode
      kb.releases = mode == :release
      %w[z c b q].each_with_index { |c, i| press(c, 10 + i * 0.01) }
      kb.all_off(11)
      expect(out.sounding).to be_empty, mode.to_s
      expect(kb.held).to be_empty
    end
  end

  describe 'step entry' do
    before { kb.entry = :step }

    def type(keys, t = 0.0)
      keys.each { |k| press(k, t += 1) }
      t
    end

    it 'builds a Seq from notes, lengths, rests, ties, dots, triplets, and marks, which prints itself back as Ruby' do
      type(%w[z x 3 c r 4 8 v 8 t 9 5 b 9 Z a ` 1 n])
      clip = kb.step.clip
      text = clip.to_ruby
      expect(text).to eq('seq(C3, D3, E3.n4, Rest.n4, F3.n8.d, Tie, G3.n16.t, C3.n16.slide, A3.n1).n8')
      expect(MB::Sound.module_eval(text).events).to eq(clip.events)
      expect(kb.view.step.count).to eq(9)

      press(:backspace, 20)
      expect(kb.step.clip.to_ruby).to eq('seq(C3, D3, E3.n4, Rest.n4, F3.n8.d, Tie, G3.n16.t, C3.n16.slide).n8')
    end

    it 'joins notes played together into a chord, by time or (with releases) while a key is held' do
      press('z', 1.0)
      press('c', 1.05)
      press('b', 1.07)
      press('x', 3.0)
      expect(kb.step.clip.to_ruby).to eq('seq(C3.n8 & E3.n8 & G3.n8, D3).n8')

      kb.step.clear
      kb.releases = true
      press('z', 5.0)
      press('c', 5.5) # z still down
      press('z', 5.6, type: :release)
      press('c', 5.7, type: :release)
      press('v', 6.0)
      expect(kb.step.clip.to_ruby).to eq('seq(C3.n8 & E3.n8, F3).n8')
    end

    it 'sounds each note for its length, plays the clip with p, and hands the clip over on Enter' do
      finished = nil
      kb.on_finish = ->(c) { finished = c }
      press('2', 0.0) # half notes: 1 s at 2 s per whole note
      press('z', 1.0)
      expect(out.log).to eq([[:on, 48, 96, 0, 1.0]])
      expect(kb.wait(1.0)).to eq(1.0)
      kb.tick(2.0)
      expect(out.sounding).to be_empty

      press('x', 3.0)
      kb.tick(4.0)
      out.log.clear
      press('p', 10.0)
      [10.0, 11.0, 12.0].each { |t| kb.tick(t) }
      expect(out.log).to eq([[:on, 48, 95, 0, 10.0], [:off, 48, 0, 11.0], [:on, 50, 95, 0, 11.0], [:off, 50, 0, 12.0]])

      press(:enter, 13.0)
      expect(finished.to_ruby).to eq('seq(C3, D3).n2')
      expect(kb.clip).to equal(finished)
      expect(kb.step.clip).to be_nil
    end

    it 'swaps the clip so far, looping, with w or Shift-Enter, keeping the steps' do
      swapped = []
      kb.on_swap = ->(c) { swapped << c }
      type(%w[z x])
      press('w', 10)
      press(:enter, 11, :shift)
      expect(swapped.map(&:to_ruby)).to eq(['seq(C3, D3).n8.loop'] * 2)
      expect(swapped.first.looping?).to eq(true)
      expect(kb.view.step.count).to eq(2)
      expect(kb.step.clip).not_to be_nil
      expect(kb.clips.length).to eq(2)
    end

    it 'leaves the upper row quiet and goes back to playing with Tab' do
      press('w', 1.0)
      expect(out.log).to be_empty
      expect(kb.message).to match(/lower row/)
      press(:tab, 2.0)
      expect(kb.entry).to eq(:play)
      press('w', 3.0)
      expect(out.log.first[1]).to eq(62)
    end
  end

  describe MB::Sound::UI::Panes::Keyboard do
    it 'draws the strip with the held keys, the octave, the mode, and the step clip' do
      kb.releases = true
      press('z', 0.0)
      press('e', 0.0)
      grid = MB::Sound::Plot::Text::Cells.new(60, 8)
      c = MB::Sound::UI::Canvas.new(grid, 0, 0, 60, 8)
      pane = MB::Sound::UI::Panes::Keyboard.new(kb)
      pane.draw(c, nil, {})
      lines = grid.to_text(:none).lines.map(&:rstrip)
      expect(lines[0]).to eq('KEYBOARD C3-A5  vel 96  ch 1  release')
      # Scaled (3 columns per white key at 60 wide, 5 rows): letters in the
      # keys, black keys' on their lowest row, C names above the white ones
      expect(lines[3]).to eq(' s  d     g  h  j     l2 ;3    5  6  7     9  0     =')
      expect(lines[4]).to eq('C3                   C4                   C5')
      expect(lines[5]).to eq('z  x  c  v  b  n  m  ,q .w /e r  t  y  u  i  o  p  [  ]  \\')
      expect(lines[6]).to eq('played C3 E4')
      # Held keys fill from the bottom by velocity (96 of 127: 4 of 5 rows)
      armed = "38;2;#{MB::Sound::UI::Themes.rgb(:armed).join(';')}"
      colored = grid.lines(:truecolor).map { |l| l.include?(armed) }
      expect(colored[1..5]).to eq([false, true, true, true, true])
      # A narrow pane falls back to the compact strip
      small = MB::Sound::Plot::Text::Cells.new(36, 8)
      pane.draw(MB::Sound::UI::Canvas.new(small, 0, 0, 36, 8), nil, {})
      expect(small.to_text(:none).lines.map(&:rstrip)[4]).to eq('zsxdc vgbhnjm ,l.;/')

      kb.entry = :step
      %w[z x].each_with_index { |k, i| press(k, 1.0 + i); press(k, 1.0 + i, type: :release) }
      pane.draw(c, nil, {})
      lines = grid.to_text(:none).lines.map(&:rstrip)
      expect(lines[5]).to eq('len n8  steps 2  0.25 whole notes')
      expect(lines[6]).to eq('seq(C3, D3).n8')
    end
  end
end
