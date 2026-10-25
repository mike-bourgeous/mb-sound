require 'shellwords'

RSpec.describe('bin/latency_probe.rb') do
  # A real process: the probe thread, the Ruby ticker, the consumer, the
  # status lines into a pipe, and the report and plots at the end.
  it 'runs for a short time, writes its report, plots, and data, and compares runs' do
    dir = tmp_path('run')
    text = `OUTPUT_TYPE=null bin/latency_probe.rb -t 1.5s -o #{dir.shellescape} --memory 4MB --status 0.2 --with-session --formats svg,txt 2>&1`
    expect($?).to be_success, text
    expect(text).to include('Latency probe: ', "writing to #{dir} for 1.5s", 'Percentiles (ms)', 'Report and plots: ')
    expect(text).to match(/probe max [\d.]+ ms p99 [\d.]+ \| ruby max/)
    expect(text).to match(/Session: \d+ buffers/)
    %w[report.txt seconds.csv events.csv histograms.json meta.json time.svg time.txt histogram.svg].each do |f|
      expect(File.exist?(File.join(dir, f))).to eq(true), f
    end
    expect(File.readlines(File.join(dir, 'seconds.csv')).length).to be >= 2

    # (forked: the run above is the real process)
    text, status = fork_script('bin/latency_probe.rb', '--compare', "#{dir},#{dir}")
    expect(status).to be_success, text
    expect(text).to match(/^stall\s+run 1\s+[\d.]+/)
    expect(text).to match(/^stall\s+run 2\s+[\d.]+/)

    File.delete(File.join(dir, 'report.txt'))
    text, status = fork_script('bin/latency_probe.rb', '--report', dir, '--formats', 'txt')
    expect(status).to be_success, text
    expect(text).to include('Percentiles (ms)')
    expect(File.read(File.join(dir, 'report.txt'))).to match(/Session: \d+ buffers/)
  end

  it 'reads times and sizes with units, and explains bad ones' do
    text, status = fork_script('bin/latency_probe.rb', '-t', '2 fortnights')
    expect(status).not_to be_success
    expect(text).to include("Can't read \"2 fortnights\" as a time")
  end

  # Any live script, through ScriptRunner: a song played on the null output
  it 'probes a live song script with MB_SOUND_LATENCY_PROBE', :smoke do
    dir = tmp_path('song')
    text = `OUTPUT_TYPE=null MB_SOUND_LATENCY_PROBE=#{dir.shellescape} bin/songs/tempo_song.rb -q --bars 1 2>&1`
    expect($?).to be_success, text
    expect(text).to include("report in #{dir}", 'Latency report: ')
    expect(File.read(File.join(dir, 'report.txt'))).to match(/Session: \d+ buffers/)
  end
end
