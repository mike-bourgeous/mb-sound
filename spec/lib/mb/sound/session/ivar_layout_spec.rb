RSpec.describe(MB::Sound::Session, 'instance variable layout') do
  # A Session that gains an instance variable while it plays changes its
  # object shape, and YJIT then compiles new versions of every Session
  # method the render thread runs, in the buffer where it happens
  # (dropouts-2: @ui_bus_meter, set by the first routed span, cost the
  # landing buffer of a new bus ~10 ms of compiling even after a
  # warm-up).  So every Session sets each of its instance variables in
  # the constructor (GraphNode::IvarPreset's rule for nodes).
  it 'keeps the same instance variables through buses, sends, master chains, tracks, knobs, mutes, and cues' do
    out = MB::Sound::NullOutput.new(channels: 2, sleep: false)
    s = MB::Sound::Session.new(output: out, transport: MB::Sound::Sequence::Transport.new(bpm: 120), channels: 2, buffer_size: 256, realtime: false, raise_errors: true, master_gain: 1)
    before = s.instance_variables
    MB::Sound::Session.with_context(session: s) do
      MB::Sound.knob(:cut, 800.0, range: 100.0..4000.0)
      MB::Sound.track(:keys) { |clip| clip.synth(voices: 2) { |v| v.hz.saw.lp4(MB::Sound.knob(:cut)) * v.amp_env(0.01, 0.1, 0.5, 0.05) * 0.2 } }
      MB::Sound.bg(:keys, MB::Sound.seq(MB::Sound::C3, MB::Sound::E3).n4.loop)
      MB::Sound.bg(:pad, 220.hz.triangle.at(0.05))
      MB::Sound.bus(:verb) { |sig| sig.reverb(:room, mix: 1) }
      MB::Sound.feed(:keys, :verb, -6.db)
      MB::Sound.master { |m| m.softclip(0, 0.9) }
      40.times { s.process_buffer }
      MB::Sound.turn(:cut, 2000.0, over: 1/4r)
      MB::Sound.mute(:pad)
      MB::Sound.solo(:keys)
      MB::Sound.cue(:lead, 330.hz.saw.at(0.05))
      MB::Sound.marker(:here, at: MB::Sound.bar(2))
      200.times { s.process_buffer }
      MB::Sound.launch(:lead)
      MB::Sound.unsolo
      MB::Sound.stop(:pad, fade: 0)
      400.times { s.process_buffer }
    end
    expect(s.instance_variables - before).to eq([])
  ensure
    s&.close
  end
end
