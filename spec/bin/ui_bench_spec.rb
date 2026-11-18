require 'json'

# bin/ui_bench.rb (ui-perf-1): a scenario on a pty read by a model
# terminal, reporting the frame instruments and the sink's view.
RSpec.describe('bin/ui_bench.rb') do
  it 'runs the tiles with the song against a model terminal and reports frames, panes, the sink, and the audio' do
    json = tmp_path('bench.json')
    text = `OUTPUT_TYPE=null timeout 120 bin/ui_bench.rb -S tiles -s 1.5 --warm 0.5 --sink konsole --holders -j #{json} 2>&1`
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
  it 'plays a demo with no screen through a modelled device queue and reports its lag and underruns' do
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

  it 'opens ui :wall at the asked frame rate and types --during lines into its REPL' do
    json = tmp_path('bench.json')
    text = `OUTPUT_TYPE=null timeout 180 bin/ui_bench.rb -S wall --size 63x236 --fps 122 -s 1.5 --warm 0.5 --during 'level :drums, -1.db' -j #{json} 2>&1`
    expect($?).to be_success, text
    expect(text).to include('== wall', 'ui_bench --during at')
    r = JSON.parse(File.read(json))[0]
    expect(r['fps']).to eq(122)
    expect(r['sink_report']['panes'].keys).to include('keyboard', 'spectrum', 'messages')
    expect(r['cpu_share_pct']['painter']).to be > 0
  end
end
