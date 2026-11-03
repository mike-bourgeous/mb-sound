# The take reader (hand-tune-1): a synthetic tuning session's take (a fit
# patch on a track, typed turns, a held-key gesture, A/B flips, an undo)
# read back as knob rows, from the take object and from its saved file
# (Prism, no eval), with renders of the patch at the start and the end.
RSpec.describe(MB::Sound::Take::Reader, :aggregate_failures) do
  let(:session) { MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), transport: MB::Sound::Sequence::Transport.new(bpm: 120), realtime: false) }
  let(:take) { MB::Sound::Take.new(session: session) }

  after {
    session.close
    MB::Sound.rewind
  }

  FIT_LINE = 'lead = fit_patch :reader_fit, "synth(CLIP, voices: 1) { |v| v.hz.saw.lp4(1234.5, resonance: 0.25) * v.amp_env(0.01, 0.2, 0.5, 0.1) }", ' \
             'cutoff: (100.0..8000.0).at(1234.5), reso: (0.0..1.0).at(0.25)'.freeze

  # Plays the session: lines typed before the given buffers, a held-key
  # gesture on the cutoff over buffers 25-31 (committed at 33).
  def perform(lines)
    b = MB::Sound::Take.console_binding
    40.times do |i|
      lines.fetch(i, []).each { |code| MB::Sound::Session.with_context(session: session) { take.line(code, b) } }
      session.preview_turn(:"lead/cutoff", 2000 + (i - 24) * 100) if i.between?(25, 31)
      MB::Sound::Session.with_context(session: session) { take.line(session.gesture_line(:"lead/cutoff"), b) } if i == 33
      session.process_buffer
    end
  end

  let(:lines) {
    {
      0 => [FIT_LINE, 'track :lead, lead', 'bg :lead, seq(A2).n4.loop', "ab :lead, MB::Sound::Sample.new([Numo::SFloat.new(4800).rand(-0.1, 0.1)], name: 'ref')"],
      10 => ['turn :"lead/cutoff", 2000.hz'],
      15 => ['ab'],
      18 => ['ab'],
      20 => ['turn :"lead/resonance", 0.4'],
      22 => ['level :lead, -6.db'],
    }
  }

  it 'reads the live take: each turn from where the knob was to where it went, in order' do
    perform(lines)
    t = take.turns
    expect(t.rows.map { |r| [r.knob, r.from, r.to, r.kind] }).to eq([
      [:"lead/cutoff", 1234.5, 2000.0, :turn],
      [:"lead/resonance", 0.25, 0.4, :turn],
      [:"lead/level", 1.0, 10**(-6 / 20.0), :level],
      [:"lead/cutoff", 2000.0, 2700.0, :gesture],
    ])
    g = t.rows.last
    expect(g.steps.length).to eq(7) # (the raw steps the take kept: replays play those)
    expect(g.steps.last).to eq([4800, 2700.0])
    expect(t.rows.first.pos).to eq(1/12r)
    expect(t.rows.first.seconds).to eq(1/6r)
    expect(t.flips.map(&:hearing)).to eq(%i[ref patch])
    expect(t.start).to include("lead/cutoff": 1234.5, "lead/resonance": 0.25)
    expect(t.finish).to include("lead/cutoff": 2700.0, "lead/resonance": 0.4)
    expect(t.changed).to include(:"lead/cutoff", :"lead/resonance")
    expect(t.reversals).to eq([])
    expect(t.to_s).to include('take: 4 turns of 3 knobs, 2 A/B flips', ':"lead/cutoff"  1234.5 -> 2000  (turn)')
  end

  it 'reads the saved take the same way without running it, and an undo puts the knob back' do
    perform(lines.merge(36 => ['undo']))
    path = File.join(Dir.mktmpdir('reader', SpecTmp::ROOT), 'take.rb')
    File.write(path, take.to_ruby)
    expect(MB::Sound::Take::Reader).not_to receive(:eval)
    t = MB::Sound::Take.read(path)
    expect(t.rows.map { |r| [r.knob, r.from, r.to, r.kind] }.first(4)).to eq(take.turns.rows.map { |r| [r.knob, r.from, r.to, r.kind] }.first(4))
    expect(t.rows.last).to have_attributes(knob: :"lead/cutoff", from: 2700.0, to: 2000.0, kind: :undo)
    # (the version of the document the take's line wrote; hand-tune-2)
    expect(t.tracks.keys).to eq([:lead])
    expect(t.tracks[:lead]).to match(%r{\A#{Regexp.escape(MB::Sound::FitPatch.dir)}/versions/reader_fit-\h{12}\.mbg\.rb\z})
    expect(MB::Sound::FitPatch.body_of(File.read(t.tracks[:lead]))).to eq(MB::Sound::FitPatch.body_of(File.read(File.join(MB::Sound::FitPatch.dir, 'reader_fit.mbg.rb'))))
    expect(t.values(:lead, :start)).to eq(cutoff: 1234.5, reso: 0.25)
    expect(t.values(:lead)).to eq(cutoff: 2000.0, reso: 0.4)
    expect(t.reversals.map { |b, a| [a.kind, b.kind] }).to eq([%i[gesture undo]])
  end

  it 'renders the patch at the start and at the end, the same values the same samples' do
    perform(lines)
    r = take.turns.renders(:lead, note: 45, hold: 0.2, seconds: 0.3)
    again = MB::Sound::HandTune.render(take.turns.tracks[:lead], { cutoff: 1234.5, reso: 0.25 }, note: 45, hold: 0.2, seconds: 0.3)
    expect(r[:start]).to eq(again)
    expect(r[:start][0].length).to eq(14400)
    expect((r[:finish][0] - r[:start][0]).abs.max).to be > 0.01
  end

  it 'reads values it can and leaves the rest nil, starting knobs from start: and knob lines' do
    text = <<~RUBY
      MB::Sound::Take::Replay.new(bpm: 100, ends: 2r) do |r|
        r.line 0r, [], <<~'X'
          knob :cut, (100..8000).at(400), curve: :exp
        X
        r.line 1/4r, [1/4r], <<~'X'
          turn :cut, 3.khz; turn :mix, 0.5; turn :cut, rand(9)
        X
        r.line 1/2r, [1/2r], <<~'X'
          turn :space, 0 => 0.3, 1.n8 => 0.5, 1.n4 => -1/2r
        X
        r.line 1r, [1r], <<~'X'
          turn :cut, 900, over: 2.bars
        X
      end.main(ARGV, __FILE__)
    RUBY
    t = MB::Sound::Take.read(text, start: { mix: 0.25 })
    expect(t.bpm).to eq(100.0)
    expect(t.rows.map { |r| [r.knob, r.from, r.to, r.kind] }).to eq([
      [:cut, 400, 3000.0, :turn], [:mix, 0.25, 0.5, :turn], [:cut, 3000.0, nil, :turn],
      [:space, nil, -1/2r, :gesture], [:cut, nil, 900, :ramp],
    ])
    expect(t.rows[3].steps).to eq([[0r, 0.3], [0.3, 0.5], [0.6, -1/2r]])
    expect(t.rows[1].seconds).to eq(0.6)
  end

  it "reads a tune line of several lines: its fit patch and where its knobs start" do
    text = <<~RUBY
      MB::Sound::Take::Replay.new(bpm: 120, ends: 2r) do |r|
        r.line 0r, [0r, 0r], <<~'X'
          tune :kick, "kit(grid(16, kick: 'X...')) { voice(:kick) { |h| h.body(51.3, decay: 0.47) } }",
            ref: "kick.wav", play: seq(C2).n4.loop,
            tune: [(30.0..110.0).at(51.3), "the body pitch"],
            decay: (0.1..2.0).at(0.47)
          level :kick, -2.0.db
        X
        r.line 1/4r, [1/4r], <<~'X'
          turn :"kick/decay", 0.3
        X
      end.main(ARGV, __FILE__)
    RUBY
    t = MB::Sound::Take.read(text)
    expect(t.tracks[:kick]).to match(%r{/versions/kick_fit-\h{12}\.mbg\.rb\z})
    expect(t.versions[:kick].map(&:line)).to eq([0])
    expect(t.rows.map { |r| [r.knob, r.from, r.to] }).to eq([[:"kick/level", 1.0, 10**(-2 / 20.0)], [:"kick/decay", 0.47, 0.3]])
  end

  it 'refuses what is not a take' do
    expect { MB::Sound::Take.read("puts 1\n") }.to raise_error(MB::Sound::Take::Reader::Error, /not a take script/)
    expect { MB::Sound::Take.read(42) }.to raise_error(MB::Sound::Take::Reader::Error)
  end
end
