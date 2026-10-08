require 'json'
require 'shellwords'

RSpec.describe('bin/loudness.rb') do
  # Runs the script in a fork (see ForkScript), or as a real process with
  # +real+ (the table example, so load-order problems still show).
  def run(*args, real: false)
    if real
      text = `bin/loudness.rb #{args.shelljoin} 2>&1`
      status = $?
    else
      text, status = fork_script('bin/loudness.rb', *args)
    end
    expect(status).to be_success, text
    MB::U.remove_ansi(text)
  end

  # A stereo 1 kHz sine at +db+ dBFS (reads +db+ LUFS).
  def tone(name, db, seconds: 4)
    path = tmp_path(name)
    data = 1000.hz.at(db.db).sample((seconds * 48000).round)
    MB::Sound.write(path, [data, data], sample_rate: 48000)
    path
  end

  it 'prints its header with --help' do
    text = run('--help')
    expect(text).to include('Measures the loudness of audio files', '--normalize', '--json')
  end

  it 'prints a table for files and directories' do
    a = tone('a.flac', -23)
    tone('b.flac', -18)
    text = run(File.dirname(a), real: true)
    expect(text).to include('Integrated LUFS', 'True peak dBTP')
    # LRA 2.2: Tech 3342's 1.5 s of silence after the end counts
    expect(text.lines.grep(/a\.flac/).first).to match(/\A\s*-23\.0\s+-23\.0\s+-23\.0\s+2\.2\s+-23\.0\s+4\.0  /)
    expect(text.lines.grep(/b\.flac/).first).to match(/\A\s*-18\.0\s/)
  end

  it 'prints JSON with --json (and series with --series)' do
    a = tone('a.flac', -20)
    h = JSON.parse(run('--json', a))
    expect(h['file']).to eq(a)
    expect(h['integrated']).to be_within(0.05).of(-20)
    expect(h['true_peak']).to be_within(0.05).of(-20)
    expect(h).not_to include('momentary')

    list = JSON.parse(run('--json', '--series', a, a))
    expect(list.length).to eq(2)
    expect(list[0]['short_term'].length).to eq(40) # every 100 ms from 0.1 s
  end

  it 'prints a Markdown table with --markdown' do
    a = tone('a.flac', -20)
    lines = run('--markdown', a).lines
    expect(lines[0]).to start_with('| Integrated LUFS |')
    expect(lines[1]).to start_with('| ---: |')
    expect(lines[2]).to start_with('| -20.0 | -20.0 |')
  end

  it 'writes normalized copies, keeping existing files unless forced' do
    a = tone('a.flac', -20)
    text = run('-n', '-14', a)
    out = File.join(File.dirname(a), 'a_-14lufs.flac')
    expect(text).to include("#{out}: +6.0 dB -> -14.0 LUFS, true peak -14.0 dBTP")
    expect(MB::Sound.loudness(out).integrated).to be_within(0.05).of(-14)

    expect(run('-n', '-14', a)).to include('exists; use -f')
    named = tmp_path('named.flac')
    run('-n', '-30', '-o', named, a)
    expect(MB::Sound.loudness(named).integrated).to be_within(0.05).of(-30)
    run('-n', '-16', '-f', '-o', named, a)
    expect(MB::Sound.loudness(named).integrated).to be_within(0.05).of(-16)
  end

  it 'warns when a normalized copy peaks above -1 dBTP' do
    a = tone('a.flac', -6)
    text = run('-n', '1', '-o', tmp_path('loud.flac'), a)
    expect(text).to include("is above 1 LUFS's -1.0 dBTP (clips in integer formats)")

    text = run('-n', '1', '--reduce', '-f', '-o', tmp_path('loud.flac'), a)
    expect(text).to include('gain reduced from +7.0 to +5.0 dB')
  end

  it 'normalizes to named targets' do
    a = tone('a.flac', -20)
    text = run('-n', 'ebu', a)
    out = File.join(File.dirname(a), 'a_ebu_r128.flac')
    expect(text).to include("#{out}: -3.0 dB -> -23.0 LUFS")
    expect(MB::Sound.loudness(out).integrated).to be_within(0.05).of(-23)
  end

  it 'shows the gain to targets, marking gains past the true-peak ceiling' do
    a = tone('a.flac', -6)
    text = run('-t', 'spotify,atsc,-0.5', a)
    expect(text).to include('Gain to spotify', 'Gain to atsc_a85', 'Gain to -0.5lufs')
    expect(text.lines.grep(/a\.flac/).first).to match(/-8\.0\s+-18\.0\s+\+5\.5!\s+\S+a\.flac/)

    h = JSON.parse(run('--json', '-t', 'spotify', a))
    expect(h['gain_to']['spotify']).to be_within(0.02).of(-8)
  end

  it 'lists the targets with their sources' do
    text = run('--targets')
    expect(text).to include('ebu_r128: EBU R 128 (-23.0 LUFS, -1.0 dBTP)', 'Source: EBU R 128-2023', 'youtube: YouTube (-14.0 LUFS, -1.0 dBTP; reported, unverified)')
  end

  it 'fails for missing files' do
    text, status = fork_script('bin/loudness.rb', '/nonexistent.flac')
    expect(status).not_to be_success
    expect(text).to include('Not found')
  end
end
