require 'shellwords'
require_relative '../support/bar_stats_sounds'

# bin/bar_stats.rb: a report of one file, a sidecar, and a bar-by-bar
# comparison of two with --check's exit status.
RSpec.describe('bin/bar_stats.rb') do
  # Runs the script in a fork (see ForkScript), or as a real process with
  # +real+ (the report example, so load-order problems still show).
  def run(*args, real: false)
    if real
      text = `bin/bar_stats.rb #{args.shelljoin} 2>&1`
      status = $?
    else
      text, status = fork_script('bin/bar_stats.rb', *args)
    end
    [MB::U.remove_ansi(text), status]
  end

  def song(name, **options)
    path = tmp_path(name)
    MB::Sound.write(path, BarStatsSounds.song(bars: 2, **options))
    path
  end

  let(:grid) { ['-b', '120', '-o', BarStatsSounds::OFFSET.to_s, '--no-sections'] }

  it 'prints its header with --help' do
    text, status = run('--help')
    expect(status).to be_success, text
    expect(text).to include('Measures sound files beat by beat', '--bpm', '--check')
  end

  it 'reports one file with a bar table, and writes its sidecar' do
    a = song('a.flac')
    text, status = run(*grid, '--bars', '--save', a, real: true)
    expect(status).to be_success, text
    expect(text).to include('Integrated', 'Range (LRA)', 'True peak', 'EBU R 128:', 'bar   start  LUFS')
    expect(text.lines.grep(/\A  1    0\.25 /).length).to eq(1)
    expect(File.file?("#{a}.bar_stats.rb")).to be(true)
    expect(MB::Sound::BarStats.load(a).bars.length).to eq(3)
  end

  it 'compares two files, and exits 1 under --check when bars fail' do
    a = song('a.flac')
    b = song('b.flac', delay: { high: 480 })
    text, status = run(*grid, '--check', a, b)
    expect(status.exitstatus).to eq(1), text
    expect(text).to include('b.flac against a.flac', 'the high band of b.flac is 10.0 ms late', 'Worst bars:', 'lag_high in bars 1-2')

    text, status = run(*grid, '--check', '--timing', '20', a, b)
    expect(status).to be_success, text
  end
end
