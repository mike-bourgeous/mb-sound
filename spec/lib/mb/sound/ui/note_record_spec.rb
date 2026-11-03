require_relative '../../../../support/ui_helpers'

# Listening notes tied to what was on screen (hand-tune-1): every ui.note
# also writes a JSON record (UI::NoteLog.record) with the sound it is
# about (the inspected fit patch, its knobs and params, its reference), the
# RENDER pane's view, markers, and data, and the take position; the
# RENDER pane's , . < > place the markers a note points at; records read
# back as plain data and draw as images offline.  Synthetic sounds only.
RSpec.describe('UI notes with the sound they are about', :aggregate_failures) do
  let(:ui) { MB::Sound::UI }

  NOTE_SPEC_CODE = 'synth(CLIP, voices: 1) { |v| v.hz.saw.lp4(1234.5, resonance: 0.25) * v.amp_env(0.01, 0.2, 0.5, 0.1) }'.freeze

  before do
    @dir = tmp_path('ui-notes')
    @env = ENV['MB_SOUND_UI_NOTES']
    ENV['MB_SOUND_UI_NOTES'] = @dir
  end

  after do
    ENV['MB_SOUND_UI_NOTES'] = @env
    @tiles&.stop
    @term&.close
    @session&.close
    ui::Inspect.target = nil
    MB::Sound.rewind
  end

  def fit_session
    @session = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), realtime: false)
    fit = MB::Sound::FitPatch.save(:note_fit, NOTE_SPEC_CODE, { cutoff: (100.0..8000.0).at(1234.5), resonance: (0.0..1.0).at(0.25) })
    ref = MB::Sound::Sample.new([MB::Sound::HandTune.render(fit.path, { cutoff: 600.0 }, note: 45, hold: 0.4, seconds: 0.5)[0] * 0.5], name: 'darker')
    MB::Sound::Session.with_context(session: @session) do
      MB::Sound.track(:lead, fit)
      MB::Sound.bg(:lead, MB::Sound.seq(MB::Sound::A2).n4.loop)
      MB::Sound.ab(:lead, ref)
      MB::Sound.turn(:"lead/cutoff", 2000.0)
    end
    10.times { @session.process_buffer }
    fit
  end

  it 'keeps the sound a note is about and the spot it names as a JSON record that reads back' do
    fit = fit_session
    ui::Inspect.target = { track: :lead }.freeze
    n = ui::NoteLog.save('the attack is too soft', session: @session, at: 0.012, freq: 3000.hz)
    rec = ui::NoteLog.read(n.data)
    expect(rec).to include(version: 1, text: 'the attack is too soft', pointed: { seconds: 0.012, hz: 3000.0 })
    expect(rec[:sound]).to include(track: 'lead', params: { cutoff: 2000.0, resonance: 0.25 })
    expect(rec[:sound][:instrument]).to include(name: 'note_fit', path: fit.version) # (the version it played: hand-tune-2)
    expect(rec[:sound][:knobs]).to include("lead/cutoff": 2000.0)
    expect(rec[:sound][:reference]).to include(source: 'darker', track: 'lead_ref', hearing: 'patch')
    expect(rec[:sound][:note]).to include(number: 45)
    expect(rec[:take]).to include(:lines, :position, :frame)
    # (the dashboard band's capture keeps the sound too: a script's ui.note)
    band = instance_double(MB::Sound::UI::Band, to_text: 'band', layout: double(name: :mini))
    allow(band).to receive(:is_a?) { |k| k == MB::Sound::UI::Band }
    expect(ui::NoteLog.capture(band, session: @session)[:sound]).to include(track: :lead)
    expect(ui::NoteLog.records).to eq([n.data])
    md = File.read(n.path)
    expect(md).to include('- **about**: track :lead, note_fit, reference darker (hearing the patch), at 12 ms 3.00 kHz', "- **data**: #{n.data}")
    expect(n.to_s).to include('at 12 ms 3.00 kHz')
    # (the patch and its reference as an image, offline, from the record)
    png = MB::Sound::HandTune.note_look(n.data, seconds: 0.3)
    expect(File.size(png)).to be > 10_000
  end

  it 'places markers in the RENDER pane with , . < > and a NAV # note keeps them, the view, and what it drew' do
    fit_session
    ui::Inspect.target = { track: :lead }.freeze
    @tiles, @term = ui_tiles(:sound, rows: 40, cols: 120, session: @session)
    stop = false
    pump = Thread.new { until stop; @session.process_buffer; sleep 0.005; end }
    expect(@term.wait_for('LUFS')).to eq(true), @term.text
    @term.write("\x1d")
    expect(@term.wait_for(' NAV ')).to eq(true)
    @term.type('w')
    expect(wait_until { @tiles.router.mode == :pane && @tiles.tiler.focus == :render }).to eq(true)
    st = @tiles.pane_state(:render)
    # (the first press shows a marker where it starts: a tenth of the view, 1 kHz)
    @term.type('..')
    expect(wait_until { st[:cursor_time] }).to be_within(1e-9).of(0.06)
    @term.type('>>')
    expect(wait_until { st[:cursor_freq] }).to be_within(1e-6).of(1000 * 2**(1 / 6.0))
    expect(@term.wait_for('@ 60 ms 1.12 kHz')).to eq(true), @term.text
    @term.write("\x1d")
    expect(@term.wait_for(' NAV ')).to eq(true)
    @term.type('#')
    expect(@term.wait_for('ui note: ')).to eq(true)
    @term.type("the bump at the marker\r")
    expect(wait_until { !ui::NoteLog.records.empty? }).to eq(true), @term.text
    rec = ui::NoteLog.read(ui::NoteLog.records.last)
    expect(rec[:pointed][:seconds]).to be_within(1e-9).of(0.06)
    expect(rec[:pointed][:hz]).to be_within(1e-6).of(1000 * 2**(1 / 6.0))
    expect(rec[:view]).to include(pane: 'render', mode: 'all', seconds: MB::Sound::UI::PatchRender.seconds.to_f)
    expect(rec[:view][:freq_range][0]).to eq(20.0)
    expect(rec[:render][:envelope][:hi].length).to eq(rec[:render][:envelope][:columns])
    expect(rec[:render][:spectrum][:hz].length).to eq(rec[:render][:spectrum][:db].length)
    expect(rec[:screen][:text]).to include('RENDER')
    png = MB::Sound::HandTune.note_image(ui::NoteLog.records.last)
    expect(File.size(png)).to be > 5_000
    expect(@tiles.mode_problems).to eq([])
  ensure
    stop = true
    pump&.join
  end
end
