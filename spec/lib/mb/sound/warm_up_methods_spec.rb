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

  it 'plays notes and moves the mod wheel through the fake MIDI input' do
    input = MB::Sound::WarmUpMethods::WarmUpMIDI.new
    batches = Array.new(8) { input.read[0] }
    events = batches.flatten(1).map { |_, bytes| bytes.bytes }
    expect(batches.map(&:length)).to eq([0, 2] * 4) # one batch per Manager#update
    expect(events.map(&:first).uniq.sort).to eq([0x80, 0x90, 0xb0])
  end
end
