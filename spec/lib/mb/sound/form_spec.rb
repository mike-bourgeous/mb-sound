RSpec.describe(MB::Sound::Form) do
  # 120 BPM at 48kHz: one bar (a whole note) is 96000 frames
  let(:transport) { MB::Sound::Sequence::Transport.new(bpm: 120) }
  let(:null_output) { MB::Sound::NullOutput.new(channels: 1, sleep: false) }
  let(:session) { MB::Sound::Session.new(master_gain: 1, output: null_output, transport: transport, channels: 1, buffer_size: 800, realtime: false, raise_errors: true) }
  let(:set) { session.arrangement }
  let(:bar) { 96000 }

  after { session.close }

  # Runs the block with +session+ as the current session.
  def within(&block)
    MB::Sound::Session.with_context(session: session, &block)
  end

  def run(frames)
    Array.new(frames / 800) { session.process_buffer[0].dup }.reduce(:concatenate)
  end

  def run_bars(n)
    run(n * bar)
  end

  # Runs until timeline position +pos+ (whole notes).
  def run_to(pos)
    session.process_buffer while transport.position < pos
  end

  # [sample index, value] where +data+ changes.
  def changes(data)
    data.to_a.each_with_index.select { |v, i| i == 0 || v != data[i - 1] }.map { |v, i| [i, v.round(3)] }
  end

  # A one-note-per-bar looping clip of note number +n+.
  def note(n)
    MB::Sound.seq(n).n1.loop
  end

  # Tracks whose output is the note number playing, and a scene per section.
  def setup_scenes(*names, numbers: nil)
    set.track(:x) { |c| c.notes.number }
    names.each_with_index do |n, i|
      set.scene(n, x: note((numbers || [])[i] || 48 + 2 * i))
    end
  end

  def flow(seed: 1, **opts, &block)
    within { MB::Sound.flow(seed: seed, on: :now, **opts, &block) }
  end

  describe 'builder' do
    let(:form) {
      described_class.build do
        fill :big, every: 16
        fill :small, every: 4, length: 1.beat, layer: true
        intro  4.bars
        label  :top
        verse  8.bars, times: 2
        chorus 8, fill: :roll
        repeat 2 do
          verse
          chorus times: 2
        end
        drop   16.bars, fill: [:riser, 4.bars], scene: :peak, fade: 1/4r
        pick   chorus: 3, drop: 1
        goto   :top, times: 1
        outro  6.beats
      end
    }

    it 'declares sections on their first call and plays them again with bare calls' do
      expect(form.sections.keys).to eq([:intro, :verse, :chorus, :drop, :outro])
      # Straight through: gotos not taken, the first option of each pick
      expect(form.steps.map(&:first)).to eq([:intro, :verse, :chorus, :verse, :chorus, :verse, :chorus, :drop, :chorus, :outro])
      expect(form.steps.map(&:last)).to eq([1, 2, 1, 2, 2, 2, 2, 1, 1, 1])
      expect(form.labels.keys).to eq([:top])
      expect(form.order.map(&:class).last(4)).to eq([MB::Sound::Form::Play, MB::Sound::Form::Pick, MB::Sound::Form::Goto, MB::Sound::Form::Play])
      expect(form.sections[:drop].fill.names).to eq([:riser])
      expect(form.sections[:drop].fill.length).to eq(4.bars)
      expect(form.sections[:drop].scene).to eq(:peak)
      expect(form.phrase_fills.map(&:name)).to eq([:big, :small])
    end

    it 'prints itself back as Ruby that builds an equal form' do
      code = form.to_ruby
      expect(code).to start_with("flow do\n  fill :big, every: 16\n  fill :small, every: 4, length: 1.beat, layer: true\n  intro 4.bars\n")
      expect(code).to include("  label :top\n  verse 8.bars, times: 2\n")
      expect(code).to include("  repeat 2 do\n    verse\n    chorus times: 2\n  end")
      expect(code).to include('drop 16.bars, fill: [:riser, 4.bars], scene: :peak, fade: 1/4r')
      expect(code).to end_with("  pick chorus: 3, drop: 1\n  goto :top, times: 1\n  outro 6.beats\nend")

      rebuilt = eval(code.sub(/\Aflow /, 'MB::Sound::Form.build '), binding, __FILE__, __LINE__) # rubocop:disable Security/Eval
      expect(rebuilt).to eq(form)
      expect(rebuilt.to_ruby).to eq(code)
      expect(form.inspect).to include(code)
    end

    it 'suggests section names for typos (did_you_mean style)' do
      expect {
        described_class.build do
          verse 8.bars
          vrese
        end
      }.to raise_error(NoMethodError, /undefined section 'vrese'.*Did you mean\?\s+verse/m)
    end

    it 'raises for a bare unknown name, a second declaration, and bad options' do
      expect { described_class.build { verse } }.to raise_error(NoMethodError, /give its length the first time/)
      expect { described_class.build { verse 8.bars; verse 4.bars } }.to raise_error(ArgumentError, /already declared/)
      expect { described_class.build { verse 8.bars; verse fill: :x } }.to raise_error(ArgumentError, /only takes times:/)
      expect { described_class.build { verse 8.bars, then: :end } }.to raise_error(ArgumentError, /unknown options :then/)
      expect { described_class.build { verse 8.bars, fil: :x } }.to raise_error(ArgumentError, /unknown options :fil.*Did you mean\?\s+:fill/m)
      expect { described_class.build { verse 8.bars, next: :chorus } }.to raise_error(ArgumentError, /no longer take next:.*goto :label.*pick/)
      expect { described_class.build { verse 'x' } }.to raise_error(NoMethodError, /must be a length/)
    end

    it 'treats verse 8.bars * 2 as one 16-bar verse (the documented trap)' do
      f = described_class.build { verse 8.bars * 2 }
      expect(f.steps).to eq([[:verse, 1]])
      expect(f.sections[:verse].length).to eq(16.bars)
    end

    it 'plays sections declared outside the flow with bare calls' do
      set.section(:verse, 8.bars, fill: :roll)
      set.section(:bridge, 2)
      f = set.build_form do
        verse
        chorus 4
        pick :bridge, :chorus
      end
      expect(f.steps.map(&:first)).to eq([:verse, :chorus, :bridge])
      expect(f.sections[:verse].fill.names).to eq([:roll])
      expect { set.section(:x, 1, next: :y) }.to raise_error(ArgumentError, /no longer take next:/)
      expect { set.section(:x, 1, fade_in: 1) }.to raise_error(ArgumentError, /unknown options :fade_in.*Did you mean\?\s+:fade/m)
    end

    it 'builds picks from names, weights, and blocks of options, and prints each back' do
      f = described_class.build do
        a 1
        b 2
        pick :a, :b
        pick a: 2, b: 1/2r
        pick do |p|
          p.option(3) { }
          p.option { c 4, times: 2; a }
          p.option(1/3r) { b times: 3 }
        end
        pick d: 1, a: 1 # d is declared later: printed as a block that declares it
        d 1
      end
      code = f.to_ruby
      expect(code).to include("  pick :a, :b\n  pick a: 2, b: 1/2r\n")
      expect(code).to include("  pick do |p|\n    p.option(3) { }\n    p.option(1) do\n      c 4, times: 2\n      a\n    end\n    p.option(1/3r) { b times: 3 }\n  end\n")
      expect(code).to include("    p.option(1) { d 1 }\n    p.option(1) { a }\n  end\n  d\nend")
      expect(eval(code.sub(/\Aflow /, 'MB::Sound::Form.build '))).to eq(f) # rubocop:disable Security/Eval
      expect(f.steps.map(&:first)).to eq([:a, :b, :a, :a, :d, :d])
    end

    it 'builds labels and gotos (a label, weighted labels, a Proc) and checks them' do
      f = described_class.build do
        label :top
        a 1
        goto :top, times: 2
        goto top: 3, out: 1
        label :out
        goto ->(st) { st.plays(:a) > 1 ? nil : :top }
        b 1
      end
      code = f.to_ruby
      expect(code).to include("  goto :top, times: 2\n  goto top: 3, out: 1\n  label :out\n  goto ->(f) { nil } # a Proc from #{__FILE__}:")
      expect(f.labels).to eq({ top: 0, out: 4 })

      expect { described_class.build { a 1; label :x; label :x } }.to raise_error(ArgumentError, /label :x appears more than once/)
      expect { described_class.build { repeat(2) { label :x; a 1 } } }.to raise_error(ArgumentError, /inside repeat/)
      expect { described_class.build { a 1; label :a } }.to raise_error(ArgumentError, /also a section name/)
      expect { described_class.build { label :top; a 1; goto :tpo } }.to raise_error(ArgumentError, /no label :tpo/)
      expect { described_class.build { label :top; a 1; goto :a } }.to raise_error(ArgumentError, /:a is a section; put `label :a_top`/)
      expect { described_class.build { a 1; label :top; goto :top } }.to raise_error(ArgumentError, /loop forever/)
      expect { described_class.build { label :top; a 1; goto :top, times: 0 } }.to raise_error(ArgumentError, /times: must be a positive Integer/)
      expect { described_class.build { label :top; a 1; goto } }.to raise_error(ArgumentError, /goto needs a label/)
      expect { described_class.build { a 1; pick chrous: 1 } }.to raise_error(ArgumentError, /No section :chrous.*declare it/m)
      expect { described_class.build { a 1; lable :x } }.to raise_error(NoMethodError, /Did you mean\?\s+label/)
    end

    it 'keeps section names away from console methods' do
      f = described_class.build do
        play 4      # a Pry command and an MB::Sound method
        stop 4
        go 2
        bar 1
      end
      expect(f.sections.keys).to eq([:play, :stop, :go, :bar])
    end

    it 'sums its length' do
      expect(form.bars).to eq(4 + 16 + 8 + 2 * (16 + 16) + 16 + 8 + 6/4r)
    end
  end

  describe 'playback' do
    it 'launches each section\'s scene on its exact first sample, then rings out at the end' do
      setup_scenes(:intro, :verse, :outro)
      flow do
        intro 2
        verse 1.bar, times: 2
        outro 1
      end
      data = run_bars(6)
      expect(changes(data)).to eq([[0, 48], [2 * bar, 50], [4 * bar, 52]])
      expect(set.playback.history).to eq([:intro, :verse, :verse, :outro])
      expect(set.playback.ended?).to eq(true)
      landed = session.journal.changes.select { |e| e.kind == :stop }.map { |e| e.lands.pos }
      expect(landed).to eq([5r])
      expect(session.journal.changes.find { |e| e.kind == :stop }.data).to eq({ ring: true })
    end

    it 'registers a :section marker for each section' do
      setup_scenes(:intro, :verse)
      flow do
        intro 2
        verse 3
      end
      run_bars(3)
      expect(session.markers[:intro].pos).to eq(0)
      expect(session.markers[:verse].pos).to eq(2)
      expect(session.markers[:verse].kind).to eq(:section)
      expect(within { MB::Sound.markers }).to eq({ intro: '1:1 (section)', verse: '3:1 (section)' })
    end

    it 'chooses weighted gotos and picks repeatably from the seed' do
      setup_scenes(:a, :b, :c)
      histories = (1..12).map { |seed|
        h = 2.times.map {
          s2 = MB::Sound::Session.new(master_gain: 1, output: MB::Sound::NullOutput.new(channels: 1, sleep: false), transport: MB::Sound::Sequence::Transport.new(bpm: 120), channels: 1, buffer_size: 800, realtime: false, raise_errors: true)
          s2.arrangement.track(:x) { |c| c.notes.number }
          [:a, :b, :c].each_with_index { |n, i| s2.arrangement.scene(n, x: note(48 + i)) }
          MB::Sound::Session.with_context(session: s2) {
            MB::Sound.flow(seed: seed, on: :now) do
              label :top
              a 1
              b 1
              c 1
              pick :b, :c
              goto top: 1, more: 1
              label :more
              a
            end
          }
          8.times { 120.times { s2.process_buffer } }
          s2.arrangement.playback.history.tap { s2.close }
        }
        expect(h[0]).to eq(h[1]) # same seed, same choices
        h[0]
      }
      expect(histories.uniq.length).to be > 1
      expect(histories.flatten.uniq).to contain_exactly(:a, :b, :c)
    end

    it 'gives goto Procs the form state' do
      setup_scenes(:drop, :outro)
      seen = []
      flow do
        label :top
        drop 1
        goto ->(f) { seen << f.to_s; f.plays(:drop) >= 3 ? nil : :top }
        outro 1
      end
      run_bars(5)
      expect(set.playback.history).to eq([:drop, :drop, :drop, :outro])
      expect(seen.first).to eq('drop pass 1, 1 bars in (drop)')
    end

    it 'loops a section with loop! until onward' do
      setup_scenes(:a, :b)
      flow do
        a 2
        b 2
      end
      run(800)
      within { MB::Sound.loop! }
      run_bars(5)
      expect(set.playback.history).to eq([:a, :a, :a])
      d = within { MB::Sound.onward }
      expect(d.to_s).to eq('next :b at 7:1 (open)') # decided at the boundary
      run_bars(3)
      expect(set.playback.history).to eq([:a, :a, :a, :b])
    end

    it 'applies goto before the commit point to this boundary, after it to the following one' do
      setup_scenes(:a, :b, :c)
      flow do
        a 4, fill: :x # (no scene :x; the fill's start is the commit point)
        b 2
        c 2
      end
      run_bars(2)
      d = within { MB::Sound.goto(:c) }
      expect(d.to_s).to eq('next :c at 5:1 (open)')
      run_to(3 + 1/8r) # past the commit point (the fill's start)
      d = within { MB::Sound.goto(:a) } # waits for the following boundary
      expect(d.to_s).to eq('next :c at 5:1')
      run_bars(4)
      expect(set.playback.history).to eq([:a, :c, :a])
    end

    it 're-decides a commit that ran early when a control arrives before the commit point' do
      setup_scenes(:a, :b, :c)
      set.scene(:roll, x: note(70), others: :keep)
      flow do
        a 4, fill: :roll
        b 2
        c 2
      end
      run_to(3 - 1/4r) # the scheduler ran the commit block (it looks half a bar ahead)
      pb = set.playback
      expect(pb.upcoming.committed).to eq(true)
      expect(pb.upcoming.section).to eq(:b)
      expect(session.queued.map(&:kind)).to include(:scene)

      within { MB::Sound.goto(:c) }
      expect(pb.upcoming.section).to eq(:c)
      expect(transport.fills.entries.count { |e| e.name == :roll }).to eq(1)

      data = run_bars(3)
      start = (3 - 1/4r - 0) # data starts there
      expect(set.playback.history).to eq([:a, :c])
      expect(session.journal.changes.count { |e| e.kind == :scene && e.subject == :roll && e.status == :landed }).to eq(1)
      expect(data[((3 - start) * bar).to_i + 10]).to eq(70) # the roll from bar 4
      expect(data[((4 - start) * bar).to_i + 10]).to eq(52) # then c
    end

    it 'finishes with the last section, skips at the next bar line, seeks, and practices' do
      setup_scenes(:a, :b, :c, :d)
      flow do
        a 8
        b 8
        c 8
        d 1
      end
      run(800)
      within { MB::Sound.finish }
      run(bar)
      within { MB::Sound.skip }
      data = run_bars(2)
      expect(set.playback.history).to eq([:a, :d])
      expect(changes(data)).to eq([[0, 48], [bar - 800, 54]])
    end

    it 'skips to the next section at the next bar line' do
      setup_scenes(:a, :b, :c)
      flow do
        a 8
        b 8
        c 8
      end
      run(bar + 1600)
      d = within { MB::Sound.skip }
      expect(d.section).to eq(:b)
      expect(d.at.pos).to eq(2)
      data = run(bar)
      expect(changes(data)).to eq([[0, 48], [bar - 1600, 50]])

      d = within { MB::Sound.seek(:a) } # the timeline back to a (bar 1)
      expect(d.to_s).to eq('next :a at 1:1')
      expect(transport.position).to eq(0)
      data = run_bars(2)
      expect(set.playback.history).to eq([:a, :b, :a])
      expect(changes(data)).to eq([[0, 48]])
    end

    it 'practices a section (goto and loop!)' do
      setup_scenes(:a, :b, :c)
      flow do
        a 1
        b 1
        c 1
      end
      run(800)
      within { MB::Sound.practice(:c) }
      run_bars(4)
      expect(set.playback.history).to eq([:a, :c, :c, :c, :c])
      expect(set.playback.looping?).to eq(true)
    end

    it 'jumps to labels: times: n jumps n times, then falls through and counts again' do
      setup_scenes(:a, :b, :c, :d)
      flow do
        label :top
        a 1
        label :inner
        b 1
        goto :inner, times: 1
        c 1
        goto :top, times: 1
        d 1
      end
      run_bars(3)
      ran = []
      within { MB::Sound.at_marker(:inner) { ran << session.now } } # passed; waits for the next time
      run_bars(6)
      expect(set.playback.history).to eq([:a, :b, :b, :c, :a, :b, :b, :c, :d])
      expect(ran).to eq([5r])
      expect(session.markers[:inner].kind).to eq(:label)
      expect(session.markers[:inner].pos).to eq(6)
      expect(session.markers[:top].pos).to eq(4)
      expect(within { MB::Sound.markers }).to include(top: '5:1 (label)')
    end

    it 'goes to labels live: goto, skip, and practice take labels as well as sections' do
      setup_scenes(:a, :b, :c)
      flow do
        a 2
        b 2
        label :tail
        c 2
      end
      run(800)
      d = within { MB::Sound.goto(:tail) }
      expect(d.to_s).to eq('next :c at 3:1 (open)')
      run_bars(2)
      within { MB::Sound.skip(:tail) } # c again from the next bar line
      run_bars(1)
      within { MB::Sound.practice(:tail) }
      run_bars(4)
      expect(set.playback.history).to eq([:a, :c, :c, :c, :c]) # bars 3, 4, 6, 8
      expect(set.playback.looping?).to eq(true)
    end

    it 'seeks the timeline to a label or section: where it last played or will, else its place in the form' do
      setup_scenes(:a, :b, :c)
      flow do
        a 2
        label :mid
        b 1
        c 2
      end
      run(800)
      d = within { MB::Sound.seek(:mid) } # not reached yet: its place in the form (bar 3)
      expect(d.to_s).to eq('next :b at 3:1')
      expect(transport.position).to eq(2)
      data = run_bars(1)
      expect(changes(data)).to eq([[0, 50]])
      expect(session.markers[:mid].kind).to eq(:label)

      # c's launch at bar 4 is already queued (the scheduler looks ahead):
      # seeking cancels it
      expect(session.queued.map(&:subject)).to include(:c)
      d = within { MB::Sound.seek(:a) }
      expect(d.to_s).to eq('next :a at 1:1')
      expect(transport.position).to eq(0)
      data = run_bars(5)
      expect(changes(data)).to eq([[0, 48], [2 * bar, 50], [3 * bar, 52]])
      expect(set.playback.history).to eq([:a, :b, :a, :b, :c])
    end

    it 'previews decisions that depend on chance as open, and checks what goto Procs return' do
      setup_scenes(:a, :b, :c)
      flow do
        a 1
        pick do |p|
          p.option { b 1 }
          p.option { c 1 }
        end
      end
      run(800)
      expect(set.playback.upcoming.to_s).to eq('next ? at 2:1 (open)')
      run_to(1 + 1/8r)
      expect(set.playback.history.length).to eq(2)
      expect([:b, :c]).to include(set.playback.history.last)

      flow do
        label :top
        a 1
        goto ->(_f) { :nope }
      end
      expect { run_bars(2) }.to raise_error(ArgumentError, /A goto Proc returned :nope; return a label of the form \(:top\) or nil/)
    end

    it 'raises for undefined scenes and unknown control targets' do
      setup_scenes(:a)
      expect { flow { a 1; b 1 } }.to raise_error(ArgumentError, /launches scene :b, which isn't defined/)
      expect { flow { a 1; b 1, scene: false; label :top } }.not_to raise_error
      expect { within { MB::Sound.goto(:topp) } }.to raise_error(ArgumentError, /No section or label :topp.*labels: :top.*Did you mean\?\s+:top/m)
      expect { within { MB::Sound.seek(:bb) } }.to raise_error(ArgumentError, /No section, label, or marker :bb.*Did you mean\?\s+:b/m)
    end

    it 'shows where it is' do
      setup_scenes(:a, :b)
      flow do
        a 4
        b 4
      end
      run(bar + 800)
      expect(set.playback.to_s).to eq('▶ a pass 1/1 (bar 2 of 4), next :b at 5:1 (open)')
      expect(within { MB::Sound.flow }).to equal(set.playback)
    end
  end

  describe 'fills' do
    it 'plays a section\'s fill in its last bar: the fill scene and fill-marked notes' do
      set.track(:x) { |c| c.notes.number }
      groove = (MB::Sound.seq(48).n1 & MB::Sound.seq(60).n2.fill.loop).loop
      set.scene(:verse, x: groove)
      set.scene(:end_scene, x: note(40))
      set.track(:lift, 0.5.constant)
      set.scene(:lift, lift: :on, others: :keep)
      flow do
        verse 2, fill: :lift
        end_scene 1
      end
      data = run_bars(3)
      # Bar 1 plays only the 48; bar 2 (the fill) also the 60 (same start: the
      # number follows the later note-on) and the lift scene's player
      expect(data[10]).to eq(48)
      expect(data[bar + 10]).to be_within(0.001).of(60.5)
      expect(data[2 * bar + 10]).to be_within(0.01).of(40.5) # the end scene stops the lift: a drone fades
      expect(data[2 * bar + bar / 3]).to eq(40)
      expect(transport.fills.entries.map { |e| [e.name, e.from, e.to] }).to include([:lift, 1r, 2r])
    end

    it 'alternates fill names per pass and can play only when leaving' do
      setup_scenes(:a, :b)
      flow do
        a 1, times: 3, fill: [:x, :y]
        b 1, times: 2, fill: { names: [:z], on: :leave }
        a times: 1
      end
      seen = []
      6.times {
        run_bars(1)
        seen |= transport.fills.entries.map { |e| [e.name, e.from] } # (old fills are pruned)
      }
      expect(seen.sort_by(&:last)).to eq([[:x, 0r], [:y, 1r], [:x, 2r], [:z, 4r], [:x, 5r]]) # the last a is pass 1 again
    end

    it 'adds phrase fills every N bars from each section start; longest period wins, layers stack' do
      setup_scenes(:a)
      flow do
        fill :big, every: 4
        fill :small, every: 2
        fill :hat, every: 1, length: 1.beat, layer: true
        a 8
      end
      run(800)
      names = ->(bar_pos) { transport.fills.names_at(bar_pos - 1) }
      expect(names.(1.5r)).to eq([])
      expect(names.(2.5r)).to eq([:small])
      expect(names.(4.5r)).to eq([:big])
      expect(names.(4 + 7/8r)).to eq([:big, :hat])
      expect(names.(8.5r)).to eq([:big])
    end

    it 'marks steps, notes, Seqs, clips, and Kit rows' do
      s = MB::Sound.seq(MB::Sound::C4, MB::Sound::E4.fill, MB::Sound::G4.fill(:big), MB::Sound::C5.nofill).n4
      expect(s.events.map(&:fill_mark)).to eq([nil, [:fill, nil], [:fill, :big], [:nofill, nil]])
      expect(s.fill.events.map(&:fill_mark).uniq).to eq([[:fill, nil]])
      expect(s.fill(:a).nofill.events.map(&:fill_mark).uniq).to eq([[:nofill, nil]])
      expect(s.fill(2r).events.length).to eq(8) # fill(span) still repeats to a span
      clip = MB::Sound.seq(MB::Sound::C4).n4.to_clip rescue MB::Sound.seq(MB::Sound::C4).n4
      expect(clip.events.first.to_s).not_to include('fill')
      expect(s.events[1].to_s).to include('fill')

      kit = MB::Sound.grid(4, kick: 'x...', hat: 'xxxx')
        .fill(clap: MB::Sound.grid(4, '...x', value: 39))
        .fill(:big) { MB::Sound.grid(4, kick: '..x.') }
        .nofill(:hat)
        .loop
      expect(kit.rows.keys).to eq([:kick, :hat, :clap])
      expect(kit[:kick].events.map(&:fill_mark)).to eq([nil, [:fill, :big]])
      expect(kit[:hat].events.map(&:fill_mark).uniq).to eq([[:nofill, nil]])
      expect(kit[:clap].events.map(&:fill_mark)).to eq([[:fill, nil]])
      expect(kit[:kick].looping?).to eq(true)
    end

    it 'keeps or drops fill-marked notes by the fills playing' do
      clip = MB::Sound.seq(MB::Sound::C4, MB::Sound::D4.fill, MB::Sound::E4.fill(:big), MB::Sound::F4.nofill).n4
      notes = ->(fills) { clip.edges(0, 1, fills: ->(_pos) { fills }).select { |_, t| t == :on }.map { |_, _, e| e.value } }
      c4, d4, e4, f4 = [MB::Sound::C4, MB::Sound::D4, MB::Sound::E4, MB::Sound::F4].map(&:number)
      expect(notes.([])).to eq([c4, f4])
      expect(notes.([:small])).to eq([c4, d4])
      expect(notes.([:big])).to eq([c4, d4, e4])
      expect(clip.edges(0, 1).count { |_, t| t == :on }).to eq(2) # no fill map: no fills
    end
  end

  describe 'markers' do
    it 'sets position and time markers, and at_marker runs at the next section start' do
      setup_scenes(:a, :b)
      within do
        MB::Sound.marker(:vo, at: MB::Sound.bar(2, beat: 3))
        MB::Sound.marker(:hit, at: 3.seconds)
      end
      expect(session.markers[:vo].pos).to eq(1 + 1/2r)
      expect(session.markers[:hit].kind).to eq(:time)
      expect(session.markers.position(:hit)).to eq(3/2r) # 3 s at 120 BPM

      ran = []
      within { MB::Sound.at_marker(:b) { ran << session.now } }
      flow do
        a 2
        b 2
        a 2
        b 2
      end
      run_bars(3)
      expect(ran).to eq([2r]) # once, at the first b
      expect(within { MB::Sound.at_marker(:b) { ran << session.now } }).to eq(false) # waits for the next b
      run_bars(4)
      expect(ran).to eq([2r, 6r])
    end

    it 'seeks the timeline to a marker that is not a section' do
      setup_scenes(:a)
      within { MB::Sound.marker(:vo, at: MB::Sound.bar(5)) }
      within { MB::Sound.seek(:vo) }
      expect(transport.position).to eq(4)
      expect { within { MB::Sound.seek(:nope) } }.to raise_error(ArgumentError, /No section, label, or marker :nope/)
    end
  end

  describe 'console names' do
    names = %i[
      flow form play_form section loop! loop_section onward unloop! continue_form goto goto_section
      skip skip_section finish finish_form practice rehearse marker markers at_marker meter time_signature
    ]

    it 'are FormMethods, not Kernel or Object methods, and not Pry commands' do
      require 'pry'
      pry_commands = Pry::Commands.keys.map(&:to_s)
      names.each do |n|
        expect(MB::Sound.method(n).owner).to eq(MB::Sound::FormMethods), "#{n} is defined by #{MB::Sound.method(n).owner}"
        expect(Object.new.respond_to?(n, true)).to eq(false), "#{n} is an Object method"
        expect(pry_commands).not_to include(n.to_s)
      end
      expect(pry_commands).not_to include('seek')
      expect(MB::Sound.method(:seek).owner).to eq(MB::Sound::SequenceMethods)
    end
  end

  describe 'takes' do
    it 'turns what was played back into a form' do
      setup_scenes(:a, :b)
      t = MB::Sound::Take.new(session: session)
      flow do
        label :top
        a 1, times: 2
        b 1
        goto :top
      end
      run_bars(5)
      f = t.form
      expect(f).to be_a(described_class)
      expect(f.to_ruby).to eq("flow do\n  a 1, times: 2\n  b 1\n  a\n  b\nend")
    end
  end
end
