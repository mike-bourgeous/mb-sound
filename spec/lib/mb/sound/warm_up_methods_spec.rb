RSpec.describe(MB::Sound::WarmUpMethods) do
  it 'does nothing without YJIT' do
    skip 'YJIT is on in this process' if RubyVM::YJIT.enabled?
    expect(MB::Sound.warm_up).to be_nil
  end

  it 'runs its graph quickly with YJIT, without starting any playback' do
    code = <<~RUBY
      require 'mb-sound'
      t = MB::Sound.warm_up
      # (3 s since racks-r3's slot swaps: ~0.8 -> ~1.4 s alone on the Mac
      # container, over 2 s under spec:quick's 8 processes)
      # (no default Session made, and the shared transport stays at rest: a
      # moved one delayed a song's first bar; fix-script-ui-meters.  The
      # Session check read an @current that Session never set until then.)
      tr = MB::Sound::Sequence.transport
      puts [t.class, t < 3, MB::Sound::Session.existing.nil?, tr.position, tr.generation].inspect
    RUBY
    out = `#{RbConfig.ruby} --yjit -I#{File.expand_path('../../../../lib', __dir__)} -e #{Shellwords.escape(code)} 2>&1`
    expect(out.lines.last.strip).to eq('[Float, true, true, (0/1), 0]')
  end

  # Every warm-up step, run here without YJIT (warm_up itself runs them
  # only under YJIT, so before this a step's side effects showed only in
  # live scripts): each leaves the shared transport and the Sessions as it
  # found them.  fix-script-ui-meters: warm_up_slots' sandbox Session ran
  # on the shared transport, moving it to 4/125 before the song started,
  # so a song's loops waited for bar 2 and a one-bar `--ui` run was
  # silent.  A new private warm_up_* step joins this sweep by its name.
  it 'leaves the shared transport and the Sessions as they were after each warm-up step' do
    steps = MB::Sound::WarmUpMethods.private_instance_methods(false).grep(/\Awarm_up_/).sort
    expect(steps).to include(:warm_up_plans, :warm_up_slots, :warm_up_notes)
    t = MB::Sound::Sequence.transport
    before = [t.position, t.generation, t.bpm, t.bar_length(0)]
    session = MB::Sound::Session.existing # (spec_helper may keep an idle default Session between examples)
    steps.each do |step|
      keywords = MB::Sound::WarmUpMethods.instance_method(step).parameters.any? { |kind, _| kind == :keyreq }
      keywords ? MB::Sound.send(step, calls: 10, buffer: 128) : MB::Sound.send(step, 128)
      expect([t.position, t.generation, t.bpm, t.bar_length(0)]).to eq(before), "#{step} moved the shared transport"
      expect(MB::Sound::Session.existing).to equal(session), "#{step} changed Session.existing"
      expect(MB::Sound::Session.context&.session).to be_nil, "#{step} left a Session in the thread's context"
    end
  end

  it 'warms up MIDI synth voices with midi: true, with a fake MIDI input' do
    code = <<~RUBY
      require 'mb-sound'
      t = MB::Sound.warm_up(midi: true)
      puts [t.class, t < 5].inspect
    RUBY
    out = `#{RbConfig.ruby} --yjit -I#{File.expand_path('../../../../lib', __dir__)} -e #{Shellwords.escape(code)} 2>&1`
    expect(out.lines.last.strip).to eq('[Float, true]')
  end

  it 'feeds the MIDI path (LiveSource, Synth of Notes voices) from the fake input' do
    input = MB::Sound::WarmUpMethods::WarmUpMIDI.new
    events = MB::Sound::MIDI::LiveSource.new(input, latency: 0).then { |src|
      (0...20).flat_map { |n| src.read(Rational(n * 128, 48000), Rational((n + 1) * 128, 48000)) }
    }
    expect(events.map(&:type).uniq).to contain_exactly(:note_on, :note_off, :cc)

    # #warm_up_notes runs without YJIT too (the spec process has none)
    synths = []
    allow(MB::Sound::Synth).to receive(:new).and_wrap_original { |m, *a, **k, &b|
      m.call(*a, **k, &b).tap { |s| synths << s }
    }
    MB::Sound.send(:warm_up_notes, calls: 30, buffer: 128)
    expect(synths.length).to eq(1)
    expect(synths[0].lanes.length).to eq(3)
  end
end
