RSpec.describe(MB::Sound::WarmUpMethods) do
  it 'does nothing without YJIT' do
    skip 'YJIT is on in this process' if RubyVM::YJIT.enabled?
    expect(MB::Sound.warm_up).to be_nil
  end

  it 'runs its graph quickly with YJIT, without starting any playback' do
    code = <<~RUBY
      require 'mb-sound'
      t = MB::Sound.warm_up
      puts [t.class, t < 2, MB::Sound::Session.instance_variable_get(:@current).nil?].inspect
    RUBY
    out = `#{RbConfig.ruby} --yjit -I#{File.expand_path('../../../../lib', __dir__)} -e #{Shellwords.escape(code)} 2>&1`
    expect(out.lines.last.strip).to eq('[Float, true, true]')
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
