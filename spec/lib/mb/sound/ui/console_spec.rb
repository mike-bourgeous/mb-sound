require_relative '../../../../support/ui_helpers'

# Console commands (ui, off, pane, layout), the prompt status, and Tab
# completion of session names.
RSpec.describe(MB::Sound::UI::UIMethods, :aggregate_failures) do
  let(:ui) { MB::Sound::UI }

  describe '#ui' do
    around do |example|
      old = $stdout
      $stdout = StringIO.new
      example.run
    ensure
      MB::Sound::UI.off
      $stdout = old
    end

    it 'shows the default band, switches layouts in place, and turns off' do
      band = MB::Sound.ui.screen
      band.refresh
      expect(band).to be_a(MB::Sound::UI::Band)
      expect(band).to be_active
      expect(band.layout.name).to eq(:band)
      expect(band.position).to eq(:bottom) # the default (scrolled lines reach the terminal's scrollback)
      expect(MB::Sound.ui.screen).to equal(band) # `ui` again: the band on screen (through the facade)
      expect(MB::Sound.ui).to equal(MB::Sound::UI.facade)

      expect(MB::Sound.ui(:deck).screen).to equal(band)
      expect(band.layout.name).to eq(:deck)

      top = MB::Sound.ui(:mini, at: :top).screen
      expect(top).not_to equal(band)
      expect(band).not_to be_active
      expect(top.position).to eq(:top)

      expect(MB::Sound.ui(MB::Sound.off)).to be_nil
      expect(top).not_to be_active
      expect($stdout.string).to include("\e[?2026h\e7").and end_with("\e8")
    end

    it 'defines panes and layouts that the band picks up' do
      MB::Sound.ui(:mini)
      p = MB::Sound.pane(:hello, height: 1, rate: 20) { |c, s| c.puts ['hello ', :dim], [s&.stamp.to_s, :key] }
      expect(MB::Sound.pane(:hello)).to equal(p)
      l = MB::Sound.layout(:hi) { cols { pane :transport; pane :hello } }
      expect(MB::Sound.layout(:hi)).to equal(l)
      band = MB::Sound.ui(:hi).screen
      band.refresh
      expect(band.to_text).to include('hello')
    ensure
      ui.panes.delete(:hello)
      ui.layouts.delete(:hi)
    end
  end

  describe 'prompt status' do
    let(:output) { MB::Sound::NullOutput.new(channels: 2, sleep: false, buffer_size: 800) }
    let(:session) { MB::Sound::Session.new(output: output, realtime: false) }

    after do
      session.close
      MB::Sound.rewind
    end

    it 'shows recording and armed tracks and the scene, never the position or load (ux-1 item 5)' do
      MB::Sound::Session.with_context(session: session) do
        expect(ui.prompt_status).to be_nil
        session.add(220.hz.sine, name: :s)
        130.times { session.process_buffer }
        expect(ui.prompt_status).to be_nil # playing, but nothing a command set

        arr = session.arrangement
        arr.track(:lead) { |c| c.tone.saw * c.amp_env }
        arr.scene(:drop, s: :keep)
        arr.go(:drop, at: :now) rescue nil
        session.process_buffer
        allow(arr).to receive(:armed).and_return({ lead: true })
        allow(arr).to receive(:current_scene).and_return(:drop)
        expect(ui.prompt_status(color: false)).to eq('arm:lead drop')
        expect(ui.prompt_status).to eq("\1\e[33m\2arm:lead\1\e[0m\2 \1\e[36m\2drop\1\e[0m\2")
      end
    end
  end

  describe MB::Sound::UI::Completion do
    let(:output) { MB::Sound::NullOutput.new(channels: 2, sleep: false, buffer_size: 800) }
    let(:session) { MB::Sound::Session.new(output: output, realtime: false) }

    after do
      session.close
      MB::Sound.rewind
    end

    it 'completes the names a command takes' do
      session.knob(:cut, 800, range: 100..8000)
      session.knob(:crush, 0.5)
      arr = session.arrangement
      arr.track(:bass) { |c| c.tone.saw * c.amp_env }
      arr.scene(:drop, bass: MB::Sound.seq(MB::Sound::A2).n4.loop)
      arr.scene(:dub, bass: nil)

      c = described_class
      expect(c.names_for(':d', 'go :d', session)).to eq([':drop', ':dub'])
      expect(c.names_for('', 'go ', session)).to eq([':drop', ':dub'])
      expect(c.names_for(':c', 'turn :c', session)).to eq([':crush', ':cut'])
      expect(c.names_for(':c', 'turn(:c', session)).to eq([':crush', ':cut'])
      expect(c.names_for(':b', 'mute :pad, :b', session)).to eq([':bass'])
      expect(c.names_for(':d', 'ui :d', session)).to eq([':deck'])
      # Any other Symbol: session names first
      expect(c.names_for(':d', 'x = :d', session)).to eq([':deck', ':drop', ':dub'])
      expect(c.names_for('', 'x = ', session)).to be_nil
      expect(c.names_for('fo', 'fo', session)).to be_nil
    end

    # (session-2: pane_keys_spec's random keys, seed 55214, typed
    # `seq(Tie).n8` and Tab; Reline's word `Tie).n8` sent Pry's completer
    # to evaluate `Tie).methods`, and Ruby's parser warned about the
    # half expression before raising)
    it "doesn't hand Pry a receiver that isn't Ruby on its own" do
      c = described_class
      expect(%w[Tie).n8 a).b foo(1,.x].map { |w| c.receiver_parses?(w) }).to all(eq(false))
      expect(%w[foo.ba Foo::Bar.x 1..2 x .x :sym seq(Tie).n8 L.inst.dn].map { |w| c.receiver_parses?(w) }).to all(eq(true))

      c.install_pry
      completer = Pry::InputCompleter.new(Reline, Pry.new(target: binding))
      expect(completer.call('Tie).n8')).to eq([]) # (and no warning: WarningGuard fails the example on one)
      expect(completer.call('MB::Soun')).to include('MB::Sound') # (Pry's completion still runs)
    end
  end
end
