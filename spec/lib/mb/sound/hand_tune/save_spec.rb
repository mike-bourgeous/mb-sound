# Saving a tuned fit patch (tuner-fixes-1; the maintainer's 2026-11-07
# take "I hope my tunings were saved when I pressed E": E reloaded the fit
# from its file and nothing wrote his knobs anywhere but the take).
# save_fit writes the track's knobs into the fit's file (bound numbers of
# the code becoming params), the track plays the saved version, tune
# starts from it afterwards instead of writing the fit's numbers over it,
# and a take keeps the save as the document it wrote.  Synthetic fits only.
RSpec.describe('MB::Sound::HandTune.save_fit', :aggregate_failures) do
  SV_CODE = 'synth(CLIP, voices: 1) { |v| v.hz.saw.lp4(1234.5, resonance: 0.25) * v.amp_env(0.01, 0.2, 0.5, 0.1) }'.freeze
  SV_PARAMS = 'cutoff: (100.0..8000.0).at(1234.5), resonance: (0.0..1.0).at(0.25)'.freeze
  SV_TUNE = "tune :lead, #{SV_CODE.inspect}, play: seq(A2).n4.loop, #{SV_PARAMS}".freeze

  let(:session) {
    MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 1, sleep: false), transport: MB::Sound::Sequence::Transport.new(bpm: 120), channels: 1,
                           buffer_size: 800, realtime: false, raise_errors: true)
  }

  before {
    @fits = ENV['MB_SOUND_FITS']
    ENV['MB_SOUND_FITS'] = File.join(File.dirname(tmp_path('x')), 'fits')
    allow(MB::Sound::UI::Design).to receive(:open) { |track, patch, *clip|
      MB::Sound.track(track, patch)
      MB::Sound.bg(track, clip.first || MB::Sound.seq(45).n4.loop)
      nil
    }
  }

  after {
    ENV['MB_SOUND_FITS'] = @fits
    session.close
    MB::Sound.rewind
  }

  def new_session
    MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 1, sleep: false), transport: MB::Sound::Sequence::Transport.new(bpm: 120), channels: 1,
                           buffer_size: 800, realtime: false, raise_errors: true)
  end

  def perform(lines, buffers:, s: session, take: MB::Sound::Take.new(session: s))
    b = MB::Sound::Take.console_binding
    MB::Sound.seed(5)
    out = []
    buffers.times do |i|
      lines.fetch(i, []).each { |code| MB::Sound::Session.with_context(session: s) { take.line(code, b) } }
      out << s.process_buffer[0].dup
    end
    [SpecBuffers.join(out), take]
  end

  def knob(name) = session.knobs[name]&.value
  def fit_file = MB::Sound::FitPatch.path_of(:lead_fit)
  def param_of(text, name) = MB::Sound::GraphIO.parse(text).declarations[name].default

  it 'writes the knobs into the fit file, plays the saved version with the same sound, and tune starts from it again' do
    lines = { 0 => [SV_TUNE], 20 => ['turn :"lead/cutoff", 700'], 40 => ['save_fit :lead'] }
    expect { @live, @take = perform(lines, buffers: 80) }.to output(%r{saved lead: 1 knob into .*fits/lead_fit\.mbg\.rb \(cutoff 1234\.5 -> 700\)}).to_stdout
    text = File.read(fit_file)
    expect(param_of(text, :cutoff)).to eq(700.0)
    expect(param_of(text, :resonance)).to eq(0.25)
    expect(MB::Sound::FitPatch.tuned_at(text)).to match(/\A\d{4}-\d\d-\d\dT/)
    expect(File.read(MB::Sound::Reference.document_path(session, :lead))).to eq(text) # (the track plays the saved version)
    expect(knob(:"lead/cutoff")).to eq(700.0)
    expect(MB::Sound::HandTune.unsaved(session, :lead)).to eq({})

    # (the same sound as without the save: the rebuild carries the voice)
    other = new_session
    mine = ENV['MB_SOUND_FITS']
    begin
      ENV['MB_SOUND_FITS'] = File.join(File.dirname(tmp_path('y')), 'fits2')
      plain, = perform(lines.slice(0, 20), buffers: 80, s: other)
    ensure
      other.close
      MB::Sound.rewind
      ENV['MB_SOUND_FITS'] = mine
    end
    expect(plain.length).to eq(@live.length)
    d = (plain - @live).abs
    expect(d.max).to eq(0)

    # (nothing to save twice)
    expect { MB::Sound::Session.with_context(session: session) { MB::Sound.save_fit(:lead) } }.to output(/nothing to save/).to_stdout

    # (tune again from the code: the saved tuning, not the code's numbers)
    expect { perform({ 0 => [SV_TUNE] }, buffers: 2, take: @take) }.to output(/your tuning saved .* in lead_fit\.mbg\.rb plays/).to_stdout
    expect(knob(:"lead/cutoff")).to eq(700.0)
    expect(File.read(fit_file)).to eq(text)
    expect(@take.lines.last.code).to match(%r{\Atune :lead, ".*versions/lead_fit-\h{12}\.mbg\.rb", play: seq\(A2\)\.n4\.loop, as: :lead_fit\z})

    # (fresh: the fit's numbers again; the saved file stays a version)
    expect { perform({ 0 => ["#{SV_TUNE}, fresh: true"] }, buffers: 2, take: @take) }.to output(/fit patch lead_fit/).to_stdout
    expect(param_of(File.read(fit_file), :cutoff)).to eq(1234.5)
    expect(knob(:"lead/cutoff")).to eq(1234.5)
    expect(Dir[File.join(MB::Sound::FitPatch.dir, 'versions', 'lead_fit-*')].map { |f| File.read(f) }).to include(text)
  end

  it 'makes a turned bound number of the code a param where the code writes it' do
    lines = { 0 => [SV_TUNE], 10 => ['bind :lead, amp_env: :decay'], 20 => ['turn :"lead/decay", 0.45'], 30 => ['save_fit :lead'] }
    expect { perform(lines, buffers: 40) }.to output(/new params from bound numbers: decay/).to_stdout
    text = File.read(fit_file)
    expect(param_of(text, :decay)).to eq(0.45)
    expect(MB::Sound::FitPatch.body_of(text)).to include('v.amp_env(0.01, decay, 0.5, 0.1)')
    expect(knob(:"lead/decay")).to eq(0.45)
    expect(MB::Sound::HandTune.unsaved(session, :lead)).to eq({})
  end

  it 'lists unsaved turns: tune again carries them and says so, fresh: names the line that puts them back' do
    expect { perform({ 0 => [SV_TUNE], 10 => ['turn :"lead/cutoff", 900', 'turn :"lead/resonance", 0.5'] }, buffers: 12) }.to output.to_stdout
    expect(MB::Sound::HandTune.unsaved(session, :lead)).to eq(cutoff: [1234.5, 900.0], resonance: [0.25, 0.5])
    expect { perform({ 0 => [SV_TUNE] }, buffers: 1) }.to output(/2 turned knobs of lead carried, not saved in the file yet \(S or save_fit :lead saves\)/).to_stdout
    expect(knob(:"lead/cutoff")).to eq(900.0)
    expect { perform({ 0 => ["#{SV_TUNE}, fresh: true"] }, buffers: 1) }.to output(
      /lead's turns that weren't saved are gone from the track \(turn :lead, cutoff: 900, resonance: 0\.5 puts them back\)/
    ).to_stdout
    expect(knob(:"lead/cutoff")).to eq(1234.5)
  end

  it 'keeps the save in the take as the document it wrote, which replays to the same samples without writing the file' do
    lines = { 0 => [SV_TUNE], 20 => ['turn :"lead/cutoff", 700'], 40 => ['save_fit :lead'], 60 => ['turn :"lead/resonance", 0.4'] }
    expect { @live, @take = perform(lines, buffers: 100) }.to output.to_stdout
    text = @take.to_ruby
    expect(text).to include('save_fit :lead, document: "# mb-sound graph document')
    t = @take.turns
    expect(t.structures.length).to eq(1)
    expect(t.values(:lead, :finish)).to eq(cutoff: 700.0, resonance: 0.4)
    saved = File.read(fit_file)

    File.write(fit_file, saved.sub('at(700.0)', 'at(800.0)')) # (edited since: the replay must not write it)
    path = tmp_path('take.rb')
    expect { @take.save(path) }.to output(/Saved/).to_stdout
    load path
    MB::Sound.seed(5)
    out = []
    expect {
      MB::Sound::Take::Replay.last.render(MB::Sound::NullOutput.new(channels: 1, sleep: false), channels: 1, buffer_sizes: [800], tail: 0) { |mix| out << mix[0].dup }
    }.to output(/replay: its version only/).to_stdout
    data = SpecBuffers.join(out)
    expect((data[0...@live.length] - @live).abs.max).to eq(0)
    expect(File.read(fit_file)).to include('at(800.0)')
  end
end
