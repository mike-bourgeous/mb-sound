RSpec.describe('bin/alloc_audit.rb') do
  it 'counts allocations per buffer by category and line' do
    json = tmp_path('audit.json')
    text = `bin/alloc_audit.rb -n 512 -W 0.1 -w 0.2 -t 5 --json #{json} 2>&1`
    expect($?).to be_success, text

    expect(text).to match(/^512-frame buffers, 19 traced \(0\.2 s\), YJIT (on|off)$/)
    expect(text).to match(/^total: [\d.]+ objects\/buffer$/)
    expect(text).to match(/^  render +[\d.]+ objects\/buffer +\d+ B\/buffer$/)
    expect(text).to match(/^  hidden +-?[\d.]+ objects\/buffer/)
    expect(text).to match(/^top 5 lines/)
    expect(text).to match(%r{^ +[\d.]+ +\d+  lib/mb/sound/\S+\.rb:\d+ })

    data = JSON.parse(File.read(json))
    expect(data['buffers']).to eq(19)
    expect(data['categories'].keys).to include('render', 'MIDI input', 'UI feed', 'hidden')
  end

  it 'measures time per buffer with --time' do
    json = tmp_path('time.json')
    text = `bin/alloc_audit.rb --time -n 512 -W 0.1 -w 0.2 --json #{json} 2>&1`
    expect($?).to be_success, text

    expect(text).to match(/^512-frame buffers, 19 timed \(0\.2 s\), YJIT (on|off)$/)
    expect(text).to match(%r{^us/buffer: mean [\d.]+  p50 [\d.]+  p90 [\d.]+  p99 [\d.]+  max [\d.]+  \(budget 10666\.7, mean [\d.]+%\)$})
    data = JSON.parse(File.read(json))
    expect(data.keys).to eq(%w[mean p50 p90 p99 max budget])
    expect(data['max']).to be >= data['p50']
  end
end
