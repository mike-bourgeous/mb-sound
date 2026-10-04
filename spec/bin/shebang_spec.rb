RSpec.describe('bin/ script shebangs') do
  # Ruby's default 100 ms thread time slice lets any busy Ruby thread starve
  # the audio writer for longer than the sound card queue (measured with
  # bin/audio_check.rb --busy: 131 underruns in 10 s on macOS by default, 0
  # with 10 ms).  The variable is read when Ruby starts, so scripts set it
  # in the shebang (env -S works on Linux and macOS).
  SHEBANG = "#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 ruby\n"

  it 'sets a 10 ms thread time slice in every script' do
    scripts = Dir['bin/**/*.rb']
    expect(scripts.length).to be > 50

    wrong = scripts.reject { |f| File.open(f, &:gets) == SHEBANG }
    expect(wrong).to be_empty, "Scripts without #{SHEBANG.strip}:\n#{wrong.join("\n")}"
  end

  it 'passes the time slice to Ruby' do
    code = 'puts ENV.fetch("RUBY_THREAD_TIMESLICE", "unset")'
    path = tmp_path('shebang_check.rb')
    File.write(path, SHEBANG + code)
    File.chmod(0o755, path)
    expect(`#{path}`.strip).to eq('10')
  end
end
