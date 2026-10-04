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
end
