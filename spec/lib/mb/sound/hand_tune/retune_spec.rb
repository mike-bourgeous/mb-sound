# Redefining a fit patch's graph while tuning it (hand-tune-2; the
# maintainer, 2026-11-03: "The tuning process should be able to handle me
# redefining the graph to add missing oscillators or noise elements etc."):
# retune keeps turned knobs, makes the new block's numbers knobs, lists
# removed ones, rematches the reference, and is one take line that replays
# to the same samples; the take reader shows it as a structure row, and
# infer scores the structure change as a step.  Synthetic fits only.
RSpec.describe(MB::Sound::HandTune, :aggregate_failures) do
  RT_CODE = 'synth(CLIP, voices: 1) { |v| v.hz.saw.lp4(1234.5, resonance: 0.25) * v.amp_env(0.01, 0.2, 0.5, 0.1) }'.freeze
  RT_FIT = "fit = fit_patch :rt_fit, #{RT_CODE.inspect}, cutoff: (100.0..8000.0).at(1234.5), resonance: (0.0..1.0).at(0.25)".freeze
  # The document's body with a noise layer (its level and cutoff new
  # params, its quality a number).
  RT_NOISE = 'synth(midi, voices: 1) { |v| (v.hz.saw + noise.filter(:lowpass, cutoff: 3000.0, quality: 0.7) * 0.125).lp4(cutoff, resonance: resonance) * ' \
             'v.amp_env(0.01, 0.2, 0.5, 0.1) }'.freeze
  RT_RETUNE = "retune :lead, #{RT_NOISE.inspect}, noise_level: (0.0..1.0).at(0.125), noise_cut: (200.0..10000.0).at(3000.0)".freeze

  let(:session) {
    MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 1, sleep: false), transport: MB::Sound::Sequence::Transport.new(bpm: 120), channels: 1,
                           buffer_size: 800, realtime: false, raise_errors: true)
  }

  after {
    session.close
    MB::Sound.rewind
  }

  # Plays +lines+ ({ buffer => [console lines] }) live for +buffers+
  # 800-frame buffers, calling +edits+ ({ buffer => proc }) first.
  # Returns [the mix, the take].
  def perform(lines, buffers:, edits: {})
    b = MB::Sound::Take.console_binding
    MB::Sound.seed(5)
    t = MB::Sound::Take.new(session: session)
    out = []
    buffers.times do |i|
      edits[i]&.call
      lines.fetch(i, []).each { |code| MB::Sound::Session.with_context(session: session) { t.line(code, b) } }
      out << session.process_buffer[0].dup
    end
    [SpecBuffers.join(out), t]
  end

  def knob(name) = session.knobs[name]&.value

  # His session: a fit, a turn, a noise layer added (lands at bar 1), the
  # new knob turned, the file edited (a softclip on the noise; the
  # resonance's range widened, its knob untouched) and retuned from it
  # (lands at bar 2), a last turn.
  let(:lines) {
    {
      0 => [RT_FIT, 'track :lead, fit', 'bg :lead, seq(A2).n4.loop'],
      30 => ['turn :"lead/cutoff", 700'],
      60 => [RT_RETUNE],
      130 => ['turn :"lead/noise_level", 0.3'],
      150 => ['retune :lead'],
      250 => ['turn :"lead/cutoff", 900'],
    }
  }
  let(:edits) {
    {
      140 => -> {
        f = MB::Sound::FitPatch.path_of(:rt_fit)
        text = File.read(f).sub('noise.filter(:lowpass, cutoff: noise_cut, quality: 0.7) * noise_level', '(noise.filter(:lowpass, cutoff: noise_cut, quality: 0.7) * noise_level).softclip(0.5, 1.0)')
        File.write(f, text.sub(/^param :resonance.*\n/, "param :resonance, (0.0..2.0).at(0.5)\n"))
      },
    }
  }

  it 'keeps turned knobs, makes the new numbers knobs, and replays a take with redefinitions to the same samples' do
    expect {
      @live, @take = perform(lines, buffers: 300, edits: edits)
    }.to output(/retune :lead: rt_fit now has 4 knobs: added noise_level, noise_cut; kept 2 \(turned values carry\).*\n.*retune :lead: rt_fit now has 4 knobs: kept 4 \(turned values carry\); changed resonance/m).to_stdout
    expect(@live.abs.max).to be > 0.05
    expect(knob(:"lead/cutoff")).to eq(900.0)
    expect(knob(:"lead/noise_level")).to eq(0.3) # (turned, kept through the file's retune)
    expect(knob(:"lead/noise_cut")).to eq(3000.0)
    expect(knob(:"lead/resonance")).to eq(0.5) # (untouched: the edited param's value)
    expect(session.knobs[:"lead/resonance"].spec.range).to eq(0.0..2.0)
    playing = MB::Sound::Reference.document_path(session, :lead)
    expect(File.read(playing)).to include('softclip(0.5, 1.0)')
    expect(playing).to include('/versions/rt_fit-')

    # (the file's retune is kept as what it read)
    text = @take.to_ruby
    expect(text).to include('retune :lead, document: "# mb-sound graph document')
    expect(text).not_to match(/^\s*retune :lead\s*$/)

    path = tmp_path('take.rb')
    expect { @take.save(path) }.to output(/Saved/).to_stdout
    load path
    replay = MB::Sound::Take::Replay.last
    MB::Sound.seed(5)
    out = []
    expect {
      replay.render(MB::Sound::NullOutput.new(channels: 1, sleep: false), channels: 1, buffer_sizes: [800], tail: 0) { |mix| out << mix[0].dup }
    }.to output(/retune :lead/).to_stdout
    data = SpecBuffers.join(out)
    expect(data.length).to be >= @live.length
    expect((data[0...@live.length] - @live).abs.max).to eq(0)
  end

  it 'reads the take with each redefinition as a structure row between the turns, and renders its start and end exactly' do
    expect { @live, @take = perform(lines, buffers: 300, edits: edits) }.to output.to_stdout
    t = @take.turns
    expect(t.structures.map { |st| [st.added, st.removed, st.kept, st.changed] }).to eq([
      [%i[noise_level noise_cut], [], %i[cutoff resonance], []],
      [[], [], %i[cutoff resonance noise_level noise_cut], [:resonance]],
    ])
    expect(t.events.map { |e| e.is_a?(MB::Sound::Take::Reader::Structure) ? :structure : e.knob }).to eq(
      [:"lead/cutoff", :structure, :"lead/noise_level", :structure, :"lead/cutoff"]
    )
    expect(t.structures.map(&:pos)).to eq([1r, 2r])
    expect(t.versions[:lead].length).to eq(3)
    expect(t.to_s).to include('2 redefinitions', ':lead  structure: +noise_level, +noise_cut, kept 2  (retune)', ':lead  structure: kept 4, changed resonance')
    expect(t.values(:lead, :start)).to eq(cutoff: 1234.5, resonance: 0.25)
    expect(t.values(:lead, :finish)).to eq(cutoff: 900.0, resonance: 0.5, noise_level: 0.3, noise_cut: 3000.0)

    # (each end renders from its own version: the start without the noise,
    # the end with the softclipped noise)
    r = t.renders(:lead, note: 45, seconds: 0.3)
    expect(r[:start]).to eq(described_class.render(t.versions[:lead].first.path, { cutoff: 1234.5, resonance: 0.25 }, note: 45, seconds: 0.3))
    expect(r[:finish]).to eq(described_class.render(MB::Sound::Reference.document_path(session, :lead), t.values(:lead, :finish), note: 45, seconds: 0.3))
    expect(r[:finish]).not_to eq(described_class.render(t.versions[:lead][1].path, t.values(:lead, :finish), note: 45, seconds: 0.3))

    # (the saved take reads the same, rebuilding each version from its line)
    saved = MB::Sound::Take.read(@take.to_ruby)
    expect(saved.structures.map(&:added)).to eq(t.structures.map(&:added))
    expect(saved.values(:lead, :finish)).to eq(t.values(:lead, :finish))
    expect(MB::Sound::FitPatch.body_of(File.read(saved.document(:lead, :start)))).to eq(MB::Sound::FitPatch.body_of(File.read(t.document(:lead, :start))))
  end

  it 'scores a path across a redefinition, the structure change as a step of its own' do
    expect { @live, @take = perform(lines.slice(0, 30, 60, 130), buffers: 160) }.to output.to_stdout
    t = @take.turns
    noisy = t.versions[:lead].last.path
    reference = described_class.render(noisy, { cutoff: 700.0, resonance: 0.25, noise_level: 0.3, noise_cut: 3000.0 }, note: 45, hold: 0.3, seconds: 0.4)[0]
    inf = described_class.infer(t, track: :lead, reference: reference, note: 45, hold: 0.3, seconds: 0.4, line: [0.5])
    expect(inf.steps.map { |st| st.structure? ? :structure : st.row.knob }).to eq([:"lead/cutoff", :structure, :"lead/noise_level"])
    st = inf.structures.first
    # (the structure's own effect: the noise layer at his knobs)
    want = described_class.compare(reference, described_class.render(noisy, { cutoff: 700.0, resonance: 0.25, noise_level: 0.125, noise_cut: 3000.0 },
                                                                       note: 45, hold: 0.3, seconds: 0.4)[0], seconds: 0.4)
    expect(st.after).to be_within(1e-12).of(want.total)
    expect(st.before).to eq(inf.steps.first.after)
    expect(inf.finish.total).to be < 1e-6 # (his end is the reference)
    expect(inf.segments.length).to eq(2)
    expect(inf.segments.map { |sg| File.basename(sg.document) }.uniq.length).to eq(2)
    expect(inf.segments.first.finish.total).to eq(st.before)
    expect(inf.segments.last.start.total).to eq(st.after)
    expect(inf.to_s).to include('structure +noise_level +noise_cut', 'segment 2')
  end

  it 'says what it would take when the file is the document playing, and refuses numbers the code lacks' do
    expect { perform(lines.slice(0), buffers: 2) }.to output.to_stdout
    MB::Sound::Session.with_context(session: session) do
      r = nil
      expect { r = MB::Sound.retune(:lead) }.to output(/is the document playing .*retune :lead, "synth\(midi, voices: 1\) \{ \|v\| v\.hz\.saw\.lp4\(cutoff, resonance: resonance\)/).to_stdout
      expect(r.unchanged).to eq(true)
      # (a take keeps that line as typed: the reader sees no redefinition)
      expect(MB::Sound::Take.read("MB::Sound::Take::Replay.new(bpm: 120) do |r|\n  r.line 0r, [], 'retune :lead'\nend\n").structures).to eq([])
      expect { MB::Sound.retune(:lead, RT_NOISE, noise_level: (0.0..1.0).at(0.6)) }.to raise_error(MB::Sound::FitPatch::Error, /noise_level \(0\.6 is none of the code's numbers\)/)
      expect { MB::Sound.retune(:lead, RT_NOISE, noise: (0.0..1.0).at(0.125)) }.to raise_error(MB::Sound::FitPatch::Error, /noise can't name a param: it is a function documents call/)
      expect { MB::Sound.retune(:nope, RT_NOISE) }.to raise_error(ArgumentError, /no track :nope/)
    end
  end

  it 'lists removed params, matches the reference again, and is undone as one step back to the old version' do
    ref = MB::Sound::Sample.new([Numo::SFloat.new(9600).rand(-0.1, 0.1)], name: 'ref')
    expect { perform(lines.slice(0, 30), buffers: 40) }.to output.to_stdout
    MB::Sound::Session.with_context(session: session) do
      pair = nil
      expect { pair = MB::Sound.ab(:lead, ref) }.not_to raise_error
      before = pair.patch_lufs
      old = MB::Sound::Reference.document_path(session, :lead)
      code = 'synth(midi, voices: 1) { |v| (v.hz.saw.lp4(cutoff, resonance: 0.25) + v.hz.square * 0.5) * v.amp_env(0.01, 0.2, 0.5, 0.1) }'
      r = nil
      expect { r = MB::Sound.retune(:lead, code, square: (0.0..1.0).at(0.5)) }.to output(/added square; removed resonance \(their knobs stay, unread\); kept 1/).to_stdout
      expect(r.removed).to eq([:resonance])
      expect(r.pair).to equal(pair)
      expect(pair.values).to eq(cutoff: 700.0, square: 0.5)
      expect(pair.patch_lufs).not_to be_within(0.1).of(before)
      expect(knob(:"lead/square")).to eq(0.5)
      MB::Sound.undo(on: :now)
      expect(MB::Sound::Reference.document_path(session, :lead)).to eq(old)
      expect(knob(:"lead/cutoff")).to eq(700.0)
    end
  end
end
