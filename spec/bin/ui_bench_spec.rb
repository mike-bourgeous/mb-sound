require 'json'

# bin/ui_bench.rb (ui-perf-1): a scenario on a pty read by a model
# terminal, reporting the frame instruments and the sink's view.
RSpec.describe('bin/ui_bench.rb') do
  it 'runs the tiles with the song against a model terminal and reports frames, panes, the sink, and the audio' do
    json = tmp_path('bench.json')
    text = `OUTPUT_TYPE=null timeout 120 bin/ui_bench.rb -S tiles -s 1.0 --warm 0.3 --sink konsole --holders -j #{json} 2>&1`
    expect($?).to be_success, text
    expect(text).to include('harness numbers', '== tiles (konsole sink', 'worst stall:', 'stalest pane:', 'feed:', 'sink:', 'GVL holders', 'render buffers:') # (with --holders the probe reports holders, not the wake delay)
    rows = JSON.parse(File.read(json))
    expect(rows.length).to eq(1)
    r = rows[0]
    expect(r['perf']['frames']).to be > 20
    expect(r['sink_report']['frames']).to be > 5
    expect(r['sink_report']['shape']['esc']['p50']).to be > 0
    expect(r['sink_report']['panes'].keys).to include('scope', 'meters')
    expect(r['perf']['acks']['answered']).to be > 0
    expect(r['perf']['identity']['xtversion']).to eq('ui_bench sink(konsole)')
    expect(r['machine']['cores']).to be > 0
    expect(r['loadavg']).to be_an(Array)
    # Per render buffer from the output's writes (--holders): renders take
    # a fraction of their period here
    b = r['holders']['buffers']
    expect(b['n']).to be > 30
    expect(b['render_ms']['p50']).to be < b['period_ms']
    expect(b['worst'].first.keys).to include('render_ms', 'jit_ms', 'gc_ms', 'bar', 'write_ms')
  end
end

# The dropout round (2026-11-17): the maintainer's dropouts came with
# Tunnel Vision on ui :wall at a 122 fps target with small buffers; the
# bench models a sound card's queue so a late buffer shows as a dropout.
RSpec.describe('bin/ui_bench.rb, the dropout scenario') do
  it 'plays a demo with no screen through a modeled device queue and reports its lag and underruns' do
    json = tmp_path('bench.json')
    text = `OUTPUT_TYPE=null timeout 180 bin/ui_bench.rb -S none --demo tunnel_vision --buffer 256 --queue-ms 43 --device-period 1024 -s 1.5 --warm 0.5 --holders -j #{json} 2>&1`
    expect($?).to be_success, text
    expect(text).to include('== none', '256-frame buffers', 'device model: queue 43.0 ms, pulls of 1024 frames', 'lag behind the schedule', 'demo :tunnel_vision', 'CPU share: render thread')
    r = JSON.parse(File.read(json))[0]
    d = r['device']
    expect(d['queue_ms']).to eq(43.0)
    expect(d['underruns']).to be >= 0
    expect(d['lag_ms']['n']).to be > 20
    expect(r['buffer']).to eq(256)
    expect(r['holders']['buffers']['period_ms']).to be_within(0.01).of(5.333)
  end

  # (konsole-pacing, 2026-11-21: --present models when Konsole shows the
  # frames, --pace terminal spaces the writes for it)
  it 'opens ui :wall at the asked frame rate, types --during lines into its REPL, and models when Konsole shows frames paced for it' do
    json = tmp_path('bench.json')
    text = `OUTPUT_TYPE=null timeout 180 bin/ui_bench.rb -S wall --size 63x236 --fps 122 -s 1.0 --warm 0.3 --during 'level :drums, -1.db' --present konsole+konsole26 --vsync 120 --pace terminal -j #{json} 2>&1`
    expect($?).to be_success, text
    expect(text).to include('== wall', 'ui_bench --during at', 'terminal model Konsole:', 'terminal model Konsole on a 120 Hz display:')
    r = JSON.parse(File.read(json))[0]
    expect(r['fps']).to eq(122)
    expect(r['sink_report']['panes'].keys).to include('keyboard', 'spectrum', 'messages')
    expect(r['cpu_share_pct']['painter']).to be > 0
    expect(r['pace']).to eq('terminal')
    k, kv, k26, = r['presents']
    expect([k['model'], kv['vsync'], k26['model']]).to eq(['Konsole', 120.0, 'Konsole 26.04'])
    expect(k['written_per_s']).to be < 90 # (12 ms apart at least, though 122 was asked)
    # (the model terminal stamps its view updates after parsing the frames,
    # like its delay below, so a loaded machine moves them: 36.3 updates/s
    # of 40.4 written failed a 0.9 bound in two branches' quick runs at load
    # 22-46, 2026-11-21; only a range is checked)
    expect(k['updates_per_s']).to be_between(k['written_per_s'] * 0.5, k['written_per_s'] + 1)
    # (pace-default-1: no write closer than the 12 ms gap, from the
    # painter's own clock, which load can't make closer; the model
    # terminal's close_per_s stamps frames after parsing them, so a busy
    # machine made it 2.1-2.7 a second: reported, not checked)
    w = r['pacer_writes']
    expect(w['writes']).to be > 10
    expect(w['under_gap']).to eq(0)
    expect(w['min_ms']).to be >= 12.0
    expect(k['close_per_s']).to be_a(Numeric)
    # (the model terminal's delay stamps frames after parsing them too, so a
    # loaded machine moves it: 7.6 ms on the Mac i9 in a merge gate, 2026-11-22;
    # only its range is checked)
    expect(k['delay_ms']['p50']).to be_between(0.0, 20.0)
  end
end
