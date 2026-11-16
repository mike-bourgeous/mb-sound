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
