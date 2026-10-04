require 'shellwords'

RSpec.describe('bin/plot_envelope.rb') do
  def run(*args)
    text = `bin/plot_envelope.rb #{args.shelljoin} 2>&1`
    expect($?).to be_success, text
    text
  end

  it 'prints the stages of a one-shot at exact samples' do
    text = run('--print', '0.01', '0.02', '0.5', '0.03')
    expect(text).to include('adsr(0.01, 0.02, 0.5, 0.03) curve analog')
    expect(text).to match(/^0 +0\.00000 +0\.000000  attack$/)
    expect(text).to match(/^480 +0\.01000 +1\.000000  decay$/)
    expect(text).to match(/^1440 +0\.03000 +0\.500000  sustain$/)
    expect(text).to match(/^4800 +0\.10000 +0\.500000  release$/) # hold 0.1 s from the start
    expect(text).to match(/^6240 +0\.13000 +0\.000000  ended$/)
    expect(text).to include('6241 samples, ended')
  end

  it 'prints a gated filter envelope with velocity' do
    text = run('--print', '--preset', 'filter_env', '--gate', '0.03', '--velocity', '0', '--curve', 'linear', '0.01', '0.01')
    expect(text).to match(/^480 +0\.01000 +2\.000000  decay$/) # 2 ** (0.5 * 2)
    expect(text).to match(/^960 +0\.02000 +1\.000000  sustain$/)
    expect(text).to match(/^1440 +0\.03000 +1\.000000  release$/)
    expect(text).to match(/^15840 +0\.33000 +1\.000000  idle$/)
  end
end
