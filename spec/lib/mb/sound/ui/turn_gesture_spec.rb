require 'mb/sound'

# Held-key knob turns (ux-r4b item 3): the gesture state machine, every
# (state, event) pair, and random walks keeping its invariants.
RSpec.describe(MB::Sound::UI::TurnGesture, :aggregate_failures) do
  let(:g) { described_class.new }
  let(:gap) { described_class::GAP }

  # Puts +g+ into +state+ at time 10.
  def enter(g, state)
    case state
    when :idle then nil
    when :turning then g.step(:"dub/space", 0.3, 0.32, 10.0)
    when :committing then g.step(:"dub/space", 0.3, 0.32, 10.0); g.flush(10.0)
    end
  end

  it 'declares every (state, event) pair with a next state, an action it has, and a description' do
    described_class::STATES.product(described_class::EVENTS).each do |pair|
      row = described_class::TRANSITIONS[pair]
      expect(row).not_to be_nil, "#{pair.inspect} has no row"
      expect(described_class::STATES).to include(row[0])
      expect(row[1].nil? || described_class.private_method_defined?(row[1])).to eq(true), "#{pair.inspect}: no action #{row[1]}"
      expect(row[2]).to be_a(String)
    end
    expect(described_class::TRANSITIONS.keys - described_class::STATES.product(described_class::EVENTS)).to eq([])
    expect(described_class.table.join("\n")).to include('turning', 'committing')
  end

  it 'does what its row says for every pair' do
    fire = {
      step: ->(x) { x.step(:"dub/space", 0.3, 0.34, 10.1) },
      tick: ->(x) { x.tick(10.0 + 0.1) },
      quiet: ->(x) { x.tick(10.0 + gap + 0.1) },
      flush: ->(x) { x.flush(10.1) },
      ran: ->(x) { x.ran },
    }
    described_class::STATES.product(described_class::EVENTS).each do |state, event|
      x = described_class.new
      enter(x, state)
      expect(x.state).to eq(state)
      out = fire[event].call(x)
      to, action, = described_class::TRANSITIONS[[state, event]]
      why = "#{state} + #{event}"
      # (a tick in :idle or :committing is the same event as :quiet there)
      expect(x.state).to eq(to), why
      case action
      when :emit then expect(out).to be_a(MB::Sound::UI::PaneKeys::Commit), why
      when :start, :more then expect(out).to be_a(MB::Sound::UI::PaneKeys::Preview), why
      else expect(out).to be_nil, why
      end
    end
  end

  it 'previews every key and commits once, when the keys stop or another key comes' do
    expect(g.step(:"dub/space", 0.3, 0.32, 5.0)).to eq(MB::Sound::UI::PaneKeys::Preview[:"dub/space", 0.32])
    expect(g.wait(5.0)).to be_within(1e-9).of(gap)
    expect(g.tick(5.0 + gap / 2)).to be_nil
    c = g.tick(5.0 + gap)
    expect(c).to be_a(MB::Sound::UI::PaneKeys::Commit)
    expect(c.knob).to eq(:"dub/space")
    g.ran
    g.step(:"dub/space", 0.32, 0.34, 6.0)
    expect(g.step(:"dub/space", 0.34, 0.5, 7.25).value).to eq(0.5)
    expect(g.from).to eq(0.32)
    expect(g.flush(7.3).note).to eq('dub/space 0.5 (1.25 s held)')
    expect { described_class.new.tap { |x| x.step(:a, 0, 1, 0) }.step(:b, 0, 1, 0.1) }.to raise_error(ArgumentError, /flush first/)
  end

  it 'keeps its invariants through random walks' do
    rng = Random.new(RSpec.configuration.seed)
    x = described_class.new
    now = 0.0
    lines = 0
    path = []
    500.times do
      now += rng.rand * 0.4
      ev = %i[step tick flush ran].sample(random: rng)
      path << ev
      out = case ev
            when :step then x.turning? || x.state == :idle || x.state == :committing ? x.step(:"dub/space", 0.3, rng.rand, now) : nil
            when :tick then x.tick(now)
            when :flush then x.flush(now)
            when :ran then x.ran
            end
      lines += 1 if out.is_a?(MB::Sound::UI::PaneKeys::Commit)
      why = path.last(10).join(' ')
      expect(described_class::STATES).to include(x.state)
      expect(x.knob.nil?).to eq(x.state == :idle), why
      expect(x.wait(now).nil?).to eq(!x.turning?), why
      expect(x.last - x.started).to be >= 0, why if x.turning?
    end
    expect(lines).to be > 10
  end
end
