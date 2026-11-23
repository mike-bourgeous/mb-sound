require_relative '../../../../support/recipe_helpers'

# The console's `ruby :name` (replay-save-1, the maintainer, 2026-11-23:
# "print graph for 475"): a name of the Session prints what it names.
RSpec.describe(MB::Sound::RecipeMethods) do
  let(:transport) { MB::Sound::Sequence::Transport.new(bpm: 120) }
  let(:session) { MB::Sound::Session.new(transport: transport, output: MB::Sound::NullOutput.new(channels: 2, sleep: false), channels: 2, buffer_size: 800, realtime: false, raise_errors: true) }
  let(:console) { MB::Sound.module_eval('binding') }

  after { session.close }

  # Runs console +code+ in the session (with a buffer after it, so changes
  # land), returning what it printed.
  def run(code)
    out = nil
    MB::Sound::Session.with_context(session: session) do
      out = capture_stdout { console.eval(code) }
    end
    session.process_buffer(800)
    out
  end

  def capture_stdout
    old = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = old
  end

  it 'prints a player\'s graph for its name, and for its players table entry, as Ruby that builds the same graph' do
    run('bg :a, 220.hz.saw.lp4(800)')
    text = run('ruby :a')
    expect(text).to eq("220.hz.saw.lp4(800)\n")
    expect(run('ruby players[:a]')).to eq(text)

    MB::Sound.seed(1)
    rebuilt = RecipeHelpers.render(RecipeHelpers.eval_recipe(text), buffers: 10)
    MB::Sound.seed(1)
    fresh = RecipeHelpers.render(220.hz.saw.lp4(800), buffers: 10)
    expect(RecipeHelpers.max_diff(rebuilt, fresh)).to eq(0)
  end

  it 'prints a track (its clip line first), a stopped track, a bus, and a knob as the set document prints them' do
    run('knob :cut, 900, range: 100..4000, curve: :exp, unit: "Hz"')
    run('bus(:hall) { |sig| sig.reverb(:hall, mix: 1) }')
    run('beat = grid(kick: "x...x...", snare: "....x...")')
    run('track :drums, beat, :tr909, fx: :hall, send: { hall: -12.db }')
    run('track(:bass) { |c| c.tone.saw.lp4(knob(:cut)) * c.amp_env }')

    doc = MB::Sound::GraphIO.dump(session.arrangement)
    drums = run('ruby :drums')
    expect(drums).to eq(%(drums = grid(kick: "x...x...", snare: "....x...")\ntrack :drums, drums, :tr909, fx: :hall, send: { hall: -12.db }\n))
    bass = run('ruby :bass')
    expect(bass.lines.first).to start_with('knob :cut, (100..4000).at(900)')
    expect(bass).to include('track(:bass) { |c|')
    hall = run('ruby :hall')
    expect(hall).to start_with('bus(:hall) { |sig|')
    expect(run('ruby :cut')).to start_with('knob :cut, ')
    [drums, bass, hall].each { |t| t.lines.each { |l| expect(doc).to include(l) } }

    run('bg :drums')
    expect(session.players.keys).to include(:drums)
    run('stop :drums')
    expect(run('ruby :drums')).to eq(drums)
  end

  it 'says what it found nearby for a name that names nothing, and prints a String naming nothing as itself' do
    run('bg :a, 220.hz.saw')
    expect { run('ruby :aa') }.to raise_error(ArgumentError, /no player, track, bus, knob, or rack is named :aa \(did you mean :a\?\)/)
    expect(run('ruby "x.flac"')).to eq(%("x.flac"\n))
  end

  it 'completes player and track names after `ruby :`' do
    run('bg :alpha, 220.hz.saw')
    run('track :drums, grid(kick: "x..."), :tr909')
    run('scene :intro, drums: :on')
    names = MB::Sound::UI::Completion.names_for(':', 'ruby :', session)
    expect(names).to include(':alpha', ':drums')
    expect(names).not_to include(':intro') # (scene names complete after go and scene)
  end

  it 'replays a take line `ruby :a` harmlessly' do
    r = MB::Sound::Take::Replay.new(bpm: 120, bar_length: 1, master_gain: 0.5, fade_in: 0, fade_out: 0, rng: nil, ends: 1/4r) do |rr|
      rr.line(0r, [0r], "bg :a, 220.hz.saw.lp4(800)\n")
      rr.line(0r, [], "ruby :a\n")
    end
    printed = capture_stdout { r.render(MB::Sound::NullOutput.new(channels: 2, sleep: false), tail: 0) }
    expect(printed).to include("220.hz.saw.lp4(800)\n")
  end
end
