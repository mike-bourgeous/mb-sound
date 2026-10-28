# Did-you-mean errors and the few supports that fit the API, from the
# maintainer's take of 2026-10-27 (workbench
# research/api-guesses/take_20261027_193645.md; omnibus15): each guess he
# typed, at a console-like binding (MB::Sound's own scope, as bin/sound.rb
# evaluates lines), gives one line saying what to type, or does the
# obvious thing.
RSpec.describe('API guesses from the 2026-10-27 take', :aggregate_failures) do
  let(:session) { MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), realtime: false, buffer_size: 800) }
  let(:console) { MB::Sound.module_eval('binding') }

  after do
    session.close
    MB::Sound.rewind
  end

  # Runs console +code+ in the session, then a few buffers.
  def run(code)
    r = MB::Sound::Session.with_context(session: session) { console.eval(code) }
    4.times { session.process_buffer }
    r
  end

  def error_of(code)
    run(code)
    nil
  rescue StandardError => e
    e
  end

  it 'says to use it in master, bus, and patch blocks written without a receiver' do
    expect(error_of('master { reverb }').message).to include('reverb is a method of the signal: use it, `master { it.reverb }`, or name it: `master { |mix| mix.reverb }`')
    expect(error_of('master { softclip(0, 1) }').message).to include('`master { it.softclip(0, 1) }`')
    expect(error_of('bus(:verb) { reverb }').message).to include('`bus(:verb) { it.reverb }`', '`bus(:verb) { |sig| sig.reverb }`')
    e = error_of('track(:bad) { preset :dnb_reese, midi: clip }')
    expect(e).to be_a(MB::Sound::Arrangement::PatchError)
    expect(e.message).to include("clip isn't defined in the block: name the block's parameter, `track(:bad) { |clip| ... }`, or use `it`")
    expect(error_of('master { it.softclip(0, 1) }')).to be_nil # (the spelling the hint gives)
  end

  it 'launches the one cued part, ends a pre-listen, and suggests names for typos' do
    run('track(:pad) { |c| c.synth { |v| v.hz.saw * v.env } * 0.1 }')
    expect(error_of('launch').message).to include('launch: nothing is cued')
    run('bg :pad, seq(C3, E3).n4.loop')
    run('cue :pad') # (a playing part: a pre-listen)
    expect(session.cue_info).to eq({ pad: 'pfl' })
    expect(error_of('launch :pd').message).to include('Nothing cued as :pd (did you mean :pad?)')
    entry = run('launch')
    expect(entry.kind).to eq(:uncue) # (already on MAIN: the pre-listen ends)
    expect(session.cue_info).to eq({})

    run('cue :pad, seq(G3).n4.loop')
    run('cue :lead, 440.hz.sine.at(0.1)')
    expect(error_of('launch').message).to include('launch which? :pad, :lead are cued')
    run('uncue :lead')
    4.times { session.process_buffer }
    expect(run('launch').kind).to eq(:launch)
  end

  it 'plays a track again with bg and its name alone' do
    run('track(:pad) { |c| c.synth { |v| v.hz.saw * v.env } * 0.1 }')
    expect(error_of('bg :pad').message).to include('the track has no clip yet')
    run('bg :pad, seq(C3).n4.loop')
    expect(run('bg :pad')).to be_nil # (already playing)
    run('stop :pad, fade: 0')
    200.times { session.process_buffer }
    expect(run('bg :pad').to_s).to start_with('bg :pad lands')
  end

  it 'takes tempo as bpm, and points drifting tempos at clocks with speed:' do
    expect(run('tempo 180')).to eq(180)
    expect(session.transport.bpm).to eq(180)
    expect(error_of('bpm 0.1.hz.lfo.at(90..180)').message).to match(/bpm takes a number.*clock :woozy, 1\/1r, speed: 4\.bars\.lfo/)
    expect(error_of('bpm 90..180').message).to include('bpm takes a number')
    expect(run('bpm 120.bpm')).to eq(120.0) # (a Tempo value reads as its number)

    expect(error_of('clock :woozy, 0.1.hz.lfo.at(0.5..2)').message).to include('a moving speed goes in speed:', '`clock :woozy, 1/1r, speed: 4.bars.lfo.at(0.5..2)`')
    c = run('clock :woozy, 1/1r, speed: 4.bars.lfo.at(0.5..2)')
    expect(c.to_s).to include('speed 4.bars.hz.lfo.at(0.5..2)')
    expect(error_of('clock :wob, 1/1r, speed: 0.1.hz.lfo.at(0.5..2)').message).to include('write 5.bars.lfo.at(...) for 0.1.hz.lfo') # (10 s at 120 BPM)
    expect((0.5.bpm..2.bpm).cover?(1.bpm)).to eq(true) # (Tempo compares)
  end

  it 'names the family of an effect setting asked for as a preset, and gives bus a usage line' do
    expect(error_of('preset :lush').message).to include(':lush is a chorus setting: `it.chorus(:lush)`')
    expect(error_of('bus(:chorus) { preset :lush }').message).to include('`it.chorus(:lush)`')
    expect(error_of('preset :chorus').message).to match(/:chorus is a family of effect settings \(.*lush.*\): `it.chorus\(/)
    expect(error_of('bus').message).to include('bus needs a name: `bus(:verb) { |sig| sig.reverb(:hall, mix: 1) }`')
    expect(error_of('preset :dnb_reesee').message).to include('did you mean') # (documents keep their suggestion)
  end
end
