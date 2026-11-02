require_relative '../../../../support/ui_helpers'

# The audibility guard (inspector-nav-1; the maintainer, 2026-11-02:
# "Pressing left/right on env release seems to have no effect though the
# numbers change.  Decay changes I can hear, but release seems to do
# nothing"): every param the inspector turns (a knob, or a literal its
# Left/Right binds) changes the sound when turned a long way (0.3 of the
# knob's travel), measured as a render after the turn against one without,
# or the inspector marks it not heard here with a reason
# (NodeInfo#masked, Inspect.masked_of), and a marked one is quiet.
RSpec.describe('UI inspector: every turn is heard or says why not', :aggregate_failures) do
  let(:ui) { MB::Sound::UI }

  before do
    allow(ui).to receive(:show) { nil }
    allow(ui::Design).to receive(:terminal?).and_return(false)
  end

  after do
    ui::Inspect.target = nil
    ui::Design.instance_variable_set(:@open, false)
    ui::Design.instance_variable_set(:@last, nil)
    MB::Sound.rewind
  end

  # Under this (dB re the mix) a turn isn't heard; over MASKED_LOUD a
  # marked one is.
  QUIET = -40
  MASKED_LOUD = -20

  # A session playing his line with +instrument+, 20 buffers in.
  def fresh(instrument)
    MB::Sound.rewind # (each session from bar 1 on the shared transport)
    s = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), realtime: false)
    MB::Sound::Session.with_context(session: s) do
      MB::Sound.module_eval("design :bass, #{instrument}, seq(E1, E1, G1, A1).n8.loop.legato(0.5)")
    end
    20.times { s.process_buffer }
    s
  end

  # 1.5 s of the mix's first channel after +line+ (a console line or nil).
  def render(s, line = nil)
    MB::Sound::Session.with_context(session: s) { MB::Sound.module_eval(line) } if line
    SpecBuffers.join(Array.new(90) { m = s.process_buffer; (m.is_a?(Array) ? m[0] : m).dup })
  end

  def db(x) = 20 * Math.log10(Math.sqrt((x**2).mean) + 1e-12)

  # The line turning param +name+ of row +n+ 0.3 of its knob's travel (a
  # knob's `turn`, or a literal's `bind ..., on: :now; turn`), or nil
  # when it doesn't turn.
  def turn_line(s, n, name, v)
    kn = n.knob_of(name)
    if kn
      k = s.knobs[kn] or return nil
      spec = k.spec
      pos = spec.position(k.value.to_f).to_f
      return "turn #{kn.inspect}, #{spec.value(pos > 0.7 ? pos - 0.3 : pos + 0.3).to_f}"
    end
    b = n.binds[name]
    return nil unless b&.line && v.value.is_a?(Numeric)
    spec = MB::Sound::GraphNode::Knob::Spec.new(name: b.knob, default: MB::Sound::Arrangement::LiteralBinding.knob_default(name, v.value))
    pos = spec.position(v.value.to_f).to_f
    "#{b.line}, on: :now; turn #{b.knob.inspect}, #{spec.value(pos > 0.7 ? pos - 0.3 : pos + 0.3).to_f}"
  end

  ['L.inst.acid', *SlowTier.slow_tier(['L.inst.house_bass', ':dnb_reese', ':init'], keep: 0)].each do |instrument|
    it "hears every turn of #{instrument} on his line, or marks it" do
      s = fresh(instrument)
      base = render(s)
      g = ui::Inspect::Gatherer.new
      info = g.call(s, { track: :bass })
      rows = info.shown.map { |i| g.call(s, { track: :bass, node: i }).nodes[i] }
      cases = rows.flat_map { |n| n.params.values.filter_map { |name, v| (line = turn_line(s, n, name, v)) && [n, name, line] } }
      s.close
      expect(cases.length).to be >= 8
      results = cases.map do |n, name, line|
        t = fresh(instrument)
        x = render(t, line)
        t.close
        m = [x.size, base.size].min
        [n, name, db(x[0...m] - base[0...m]) - db(base[0...m]), line]
      end
      results.each do |n, name, diff, line|
        what = "#{instrument} #{n.label} #{name} (#{diff.round(1)} dB: #{line})"
        if n.masked[name]
          expect(diff).to be < MASKED_LOUD, "#{what} is marked #{n.masked[name].inspect} but heard"
        else
          expect(diff).to be > QUIET, "#{what} turns but isn't heard, and isn't marked"
        end
      end
      if instrument == 'L.inst.acid'
        # (his case: the glide, which never slides on legato(0.5) eighths,
        # and the filter env's release under the amp env's 8 ms are marked)
        marked = results.select { |n, name, _, _| n.masked[name] }.map { |n, name, _, _| "#{n.label} #{name}" }
        expect(marked).to contain_exactly('glide time', 'acid_env release')
      end
    ensure
      s&.close
    end
  end

  it 'unmarks the glide when the clip slides, and the filter env release when the amp env releases slowly' do
    clip = MB::Sound.seq(MB::Sound::E1, MB::Sound::G1).n8.loop
    expect(ui::Inspect.legato_notes?(clip.legato(0.5))).to eq(false)
    expect(ui::Inspect.legato_notes?(clip.legato(1.2))).to eq(true)
    expect(ui::Inspect.legato_notes?(Object.new)).to eq(true) # (can't tell: not marked)
    s = fresh('L.inst.acid')
    g = ui::Inspect::Gatherer.new
    info = g.call(s, { track: :bass })
    env = info.nodes.index { |n| n.what == 'filter env' }
    amp = info.nodes.index { |n| n.what == 'amp env' }
    expect(g.call(s, { track: :bass, node: env }).selected.masked).to include(:release)
    # Turning the amp env's release (Left/Right's lines) up past the mask: the filter env's release counts again,
    # and the amp env's preview draws the new release
    amp_info = g.call(s, { track: :bass, node: amp })
    before = amp_info.selected.params.values[:release].value
    MB::Sound::Session.with_context(session: s) { MB::Sound.module_eval('bind :bass, env: :release, on: :now; turn :"bass/release", 0.3') }
    4.times { s.process_buffer }
    after = g.call(s, { track: :bass, node: amp })
    expect(after.selected.params.values[:release].value).to eq(0.3)
    expect(before).to eq(0.008)
    chart = lambda do |n|
      b = MB::Sound::Plot::ChartBuilder.new(title: nil, x: nil, y: nil, legend: false, grid: true)
      MB::Sound::Plot::Panels.preview(n.params.node_class, n.params, b)
      b.build.title
    end
    expect(chart.(after.selected)).to include('R 300ms')
    expect(chart.(amp_info.selected)).to include('R 8ms')
    expect(g.call(s, { track: :bass, node: env }).selected.masked).not_to include(:release)
  ensure
    s&.close
  end
end
