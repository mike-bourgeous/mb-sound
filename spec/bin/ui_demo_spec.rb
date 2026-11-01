require 'shellwords'

RSpec.describe('bin/ui_demo.rb') do
  it 'plays the song with the band drawn to /dev/null and prints the wake delays' do
    cap = File.dirname(tmp_path('cap/x'))
    notes = File.dirname(tmp_path('notes/x'))
    text = `OUTPUT_TYPE=null MB_SOUND_UI_NOTES=#{notes.shellescape} bin/ui_demo.rb -s 2.5 --compare -q --notes 1 --capture #{cap.shellescape} 2>&1`
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
    # --notes (audio-safety-2): what a ui.note costs the audio
    expect(text).to match(/^ui\.note \(1, to #{Regexp.escape(notes)}\)/)
    expect(text).to match(/^  note 1 at +[\d.]+ s: +[\d.]+ ms on the REPL thread \(with the first lookup\), largest buffer gap around it +[\d.]+ ms, underruns n\/a/)
    expect(Dir.glob(File.join(notes, '*.md')).length).to eq(1)
  end
end
