require 'shellwords'

RSpec.describe('bin/plot_envelope.rb') do
  # Runs the script in a fork (see ForkScript), or as a real process with
  # +real+ (the first example).
  def run(*args, real: false)
    text, status = run_script('bin/plot_envelope.rb', *args, real: real)
    expect(status).to be_success, text
    text
  end

  it 'prints the stages of a one-shot at exact samples' do
    text = run('--print', '0.01', '0.02', '0.5', '0.03', real: true)
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

  it 'prints S-curve shapes with --shape and the :smooth preset' do
    text = run('--print', '--shape', 's,exp,exp', '--curve', '0', '--gate', '0.005', '0.01', '0.01', '0.5', '0.01')
    expect(text).to include('curve linear shape s/exp/exp')
    expect(text).to match(/^240 +0\.00500 +0\.496875  release$/) # smoothstep(239 / 480), the last attack sample

    text = run('--print', '--curve', 'smooth', '0.01', '0.02', '0.5', '0.03')
    expect(text).to include('curve smooth')
    expect(text).to match(/^480 +0\.01000 +1\.000000  decay$/)
    expect(text).to match(/^1440 +0\.03000 +0\.500000  sustain$/)
  end

  it 'plots every curve preset in one chart with a legend' do
    text = MB::U.remove_ansi(run('--compare', '0.05', '0.3', '0.4', '0.5'))
    MB::Sound::Envelope::CURVES.each_key.first(2).each do |name|
      expect(text).to include("━━ #{name}")
    end
    expect(text).to include('time (ms)')
  end

  it 'saves a plot in dB' do
    path = tmp_path('env.txt')
    text = run('--db', '60', '-S', path, '0.01', '0.1', '0.5', '0.2')
    expect(text).to include("Wrote #{path}")
    expect(File.read(path)).to include('level (dB)', '-60')
  end
end
