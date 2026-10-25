require 'shellwords'

RSpec.describe('bin/ui_demo.rb') do
  it 'plays the song with the band drawn to /dev/null and prints the wake delays' do
    cap = File.dirname(tmp_path('cap/x'))
    text = `OUTPUT_TYPE=null bin/ui_demo.rb -s 2.5 --compare -q --capture #{cap.shellescape} 2>&1`
    expect($?).to be_success, text
    expect(text).to match(/^  band on +n=\d+ +p50 [\d.]+ +p99 [\d.]+/)
    expect(text).to match(/^Painter per refresh: \d+ refreshes, CPU p50/)
    expect(text).to include('Underruns: n/a (NullOutput output)')
    # Captures land on 1 s ticks of a 2.5 s run, so under load a slow first
    # refresh can push the second past the end (seen twice on 2026-10-25)
    expect(text).to match(/^Captures: [12] in /)
    ans = File.read(File.join(cap, 'band_000.ans'))
    expect(ans).to include('TRACKS').and include('MASTER')
    expect(File.read(File.join(cap, 'band_000.html'))).to include('<html')
  end
end
