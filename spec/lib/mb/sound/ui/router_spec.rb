require 'mb/sound'

# The Router as an explicit state machine (ux-1 round 3, item 12): every
# (state, event) pair is declared, each does what its table row says, and
# random walks keep the invariants.
RSpec.describe(MB::Sound::UI::Input::Router, :aggregate_failures) do
  let(:input) { MB::Sound::UI::Input }
  let(:key) { input::Key }
  let(:router_class) { described_class }

  # A host that records what reaches it and acts like Tiles on the actions
  # that change the mode.
  let(:host_class) {
    Class.new {
      attr_reader :log
      attr_accessor :router, :pane_map, :mode_map, :focus

      # (focus: a pane name, as Tiles' :repl, :keyboard, :clips; the one
      # before it for NAV p and Ctrl-W Ctrl-W)
      def initialize
        @log = []
        @focus = :repl
        @last = :clips
        @once_focus = nil
      end

      # (as Tiles#once_target: back if the focus stayed, else into it)
      def once_target(origin)
        return origin if @focus == @once_focus
        { repl: :repl, keyboard: :grab }.fetch(@focus) { @mode_map ? :pane : :nav }
      end
      def grab_key(k) = @log << [:grab, k.key, k.type]
      def repl_key(k) = @log << [:repl, k.key, k.bytes]
      def play_key(k) = @log << [:play, k.key, k.type]
      def repl_paste(t) = @log << [:paste, t]
      def line_done(kind, text) = @log << [:line_done, kind, text]
      def mode_changed(m)
        @once_focus = @focus if m == :once
        @log << [:mode, m]
      end
      def pane_keymap = @pane_map

      # (a pane with mode keys, like the clip matrix: Tiles#pane_mode_key)
      def pane_mode_key(k)
        a = @mode_map&.[](k) or return false
        @log << [:pane_mode, a.name, *a.args]
        true
      end

      def act(a)
        @log << [:act, a.name, *a.args]
        case a.name
        when :mode then @router.mode = a.args[0]
        when :keys then @router.mode = :grab
        when :enter then @router.mode = @mode_map ? :pane : :nav
        when :key_help then @router.mode = :overlay
        when :focus_last then @focus, @last = @last, @focus
        when :focus_dir then @focus, @last = (@focus == :repl ? :clips : :repl), @focus
        when :palette then @router.open_line(:palette, ':')
        end
      end

      def clear = @log.clear
    }
  }

  def make(**opts)
    host = host_class.new
    r = router_class.new(host, **opts)
    host.router = r
    [r, host]
  end

  # Puts router +r+ into +state+ (from :repl).
  def enter(r, state)
    case state
    when :repl then nil
    when :nav then r.event(router_class::NAV_KEY)
    when :grab then r.mode = :grab
    when :line then r.open_line(:palette, ':')
    when :overlay then r.event(router_class::NAV_KEY); r.mode = :overlay
    when :pending then r.nav_esc = 0.3; r.event(key.of(:escape))
    when :once then r.event(key.of('w', :ctrl))
    when :pane then r.mode = :pane
    when :play then nil
    end
  end

  it 'finds every host method public on Tiles (an optional one that is private would be skipped silently)' do
    router_class::HOST_METHODS.each do |m|
      expect(MB::Sound::UI::Tiles.public_method_defined?(m)).to eq(true), "Tiles##{m} is not public"
    end
    calls = File.read(File.expand_path('../../../../../lib/mb/sound/ui/input/router.rb', __dir__)).scan(/@host\.(?:respond_to\?\(:)?([a-z_]+[?]?)/).flatten.uniq
    expect(calls).to include('once_target', 'act', 'pane_keymap')
    expect(calls - %w[respond_to?] - router_class::HOST_METHODS.map(&:to_s)).to eq([])
  end

  it 'declares every (state, event) pair, with a handler it has and a description' do
    router_class::STATES.product(router_class::EVENTS).each do |pair|
      row = router_class::TABLE[pair]
      expect(row).not_to be_nil, "#{pair.inspect} has no row"
      next unless row
      expect(router_class.private_method_defined?(row[0])).to eq(true), "#{pair.inspect}: no handler #{row[0]}"
      expect(row[1]).to be_a(String).and(satisfy { |s| s.length > 5 })
    end
    expect(router_class::TABLE.keys - router_class::STATES.product(router_class::EVENTS)).to eq([])
    text = router_class.table.join("\n")
    expect(text).to include("repl:\n  nav_key    to NAV", "pending:")
  end

  it 'classifies each kind of event in each state' do
    r, = make(nav_esc: 0.3)
    expect(r.classify(router_class::NAV_KEY)).to eq(:nav_key)
    expect(r.classify(key.of(:f2))).to eq(:keys_key)
    expect(r.classify(key.of('c', :ctrl))).to eq(:interrupt)
    expect(r.classify(key.of('z', :ctrl))).to eq(:suspend)
    expect(r.classify(key.of('w', :ctrl))).to eq(:once_key)
    expect(r.classify(key.of(:escape))).to eq(:prefix) # with nav_esc
    expect(r.classify(key.of('x'))).to eq(:key)
    expect(r.classify(key.of('x', type: :release))).to eq(:release)
    expect(r.classify(input::Paste.new(text: 'x'))).to eq(:paste)
    expect(r.classify(nil)).to eq(:tick)
    expect(r.classify(input::Focus.new(in: true))).to eq(:other)
    expect(r.classify(key.of(:escape), :nav)).to eq(:key)
    expect(r.classify(key.of('w', :ctrl), :grab)).to eq(:once_key)
    r.nav_once = false
    expect(r.classify(key.of('w', :ctrl), :grab)).to eq(:key) # (a soft note there)
    expect(r.classify(key.of('w', :ctrl))).to eq(:key)
  end

  it 'makes Ctrl-] enter NAV from every state, and a second Ctrl-] go back where it came from (item 19)' do
    { repl: :repl, grab: :grab, line: :line, pane: :pane, nav: :repl, overlay: :repl, pending: :repl, once: :repl }.each do |state, back|
      r, host = make
      enter(r, state)
      expect(r.state).to eq(state)
      r.event(router_class::NAV_KEY)
      expect(r.state).to eq(state == :nav ? :repl : :nav), "Ctrl-] from #{state}"
      next if state == :nav
      r.event(router_class::NAV_KEY)
      expect(r.state).to eq(back), "Ctrl-] Ctrl-] from #{state}"
      expect(r.line).not_to be_nil if state == :line # (the line is kept)
      expect(host.log).to include([:mode, :nav])
    end
    # A screen without a console: :play
    r, = make(console: false)
    expect(r.state).to eq(:play)
    r.event(router_class::NAV_KEY)
    expect(r.state).to eq(:nav)
    r.event(router_class::NAV_KEY)
    expect(r.state).to eq(:play)
  end

  it 'closes the ? overlay with Esc, ?, or Ctrl-], and otherwise acts as NAV would (item 20)' do
    nav = router_class::NAV
    nav.entries.each do |b|
      next if b.chord == [:escape, []] # (Esc closes the overlay: NAV's Esc is one more press)
      k = key.of(b.chord[0], *b.chord[1])
      a, ha = make
      a.event(router_class::NAV_KEY)
      ha.clear
      a.event(k)
      b2, hb = make
      enter(b2, :overlay)
      hb.clear
      b2.event(k)
      expect(hb.log.reject { |e| e == [:mode, :nav] }).to eq(ha.log), "overlay + #{k}"
      expect(b2.state).to eq(a.state), "overlay + #{k}"
    end
    %W[\e ?].each do |c|
      r, host = make
      enter(r, :overlay)
      host.clear
      r.event(c == "\e" ? key.of(:escape) : key.of(c))
      expect(r.state).to eq(:nav)
      expect(host.log).to eq([[:mode, :nav]])
    end
  end

  it 'reads Ctrl-W as one NAV key, then back where it came from (maintainer, 2026-10-18)' do
    r, host = make
    r.event(key.of('w', :ctrl, bytes: "\x17"))
    expect(r.state).to eq(:once)
    expect(r.once_return).to eq(:repl)
    r.event(key.of('z'))
    expect(host.log).to include([:act, :zoom])
    expect(r.state).to eq(:repl) # (zoomed, back in the REPL)
    expect(r.once_return).to be_nil
    # No word delete: Ctrl-W x is NAV's x
    host.clear
    r.event(key.of('w', :ctrl, bytes: "\x17"))
    r.event(key.of('x', bytes: 'x'))
    expect(host.log).to eq([[:mode, :once], [:act, :close], [:mode, :repl]])
    # An unbound key: the ? overlay over :once, with a flash; a key there acts once
    host.clear
    r.event(key.of('w', :ctrl))
    r.event(key.of('Q'))
    expect(r.state).to eq(:overlay)
    expect(host.log.last[0, 2]).to eq([:act, :unbound])
    r.event(key.of('z'))
    expect(host.log.last(2)).to eq([[:act, :zoom], [:mode, :repl]])
    expect(r.state).to eq(:repl)
    # Esc on that overlay: back, nothing done
    r.event(key.of('w', :ctrl))
    r.event(key.of('Q'))
    r.event(key.of(:escape))
    expect(r.state).to eq(:repl)
    # Esc: back, nothing done
    host.clear
    r.event(key.of('w', :ctrl))
    r.event(key.of(:escape))
    expect(r.state).to eq(:repl)
    expect(host.log.map(&:first)).to eq([:mode, :mode])
    # Ctrl-W Ctrl-]: NAV to stay; Ctrl-] there: back to the REPL
    r.event(key.of('w', :ctrl))
    r.event(router_class::NAV_KEY)
    expect(r.state).to eq(:nav)
    r.event(key.of('z'))
    expect(r.state).to eq(:nav)
    r.event(router_class::NAV_KEY)
    expect(r.state).to eq(:repl)
    # Off: Ctrl-W is the REPL's
    r2, h2 = make(nav_once: false)
    r2.event(key.of('w', :ctrl, bytes: "\x17"))
    expect(h2.log).to eq([[:repl, 'w', "\x17"]])
  end

  it 'goes into the pane a one-shot focus move lands on, and Ctrl-W Ctrl-W twice comes back' do
    r, host = make
    host.mode_map = input::Keymap.new(:matrix) { on :up, :move, 0, -1 }
    # REPL -> Ctrl-W Ctrl-W: the last pane (the clips), gone into
    r.event(key.of('w', :ctrl))
    r.event(key.of('w', :ctrl))
    expect(host.focus).to eq(:clips)
    expect(r.state).to eq(:pane)
    # and again: back to the REPL, in REPL mode
    r.event(key.of('w', :ctrl))
    r.event(key.of('w', :ctrl))
    expect(host.focus).to eq(:repl)
    expect(r.state).to eq(:repl)
    # Ctrl-W arrows: into the pane it lands on; without keys of its own, NAV
    host.mode_map = nil
    r.event(key.of('w', :ctrl))
    r.event(key.of(:right))
    expect(host.log).to include([:act, :focus_dir, :right])
    expect(host.focus).to eq(:clips)
    expect(r.state).to eq(:nav)
    # From a pane: Ctrl-W z zooms and goes back into the pane
    host.mode_map = input::Keymap.new(:matrix) { on :up, :move, 0, -1 }
    r.mode = :pane
    r.event(key.of('w', :ctrl))
    expect(r.state).to eq(:once)
    r.event(key.of('z'))
    expect(r.state).to eq(:pane)
    # From KEYS: Ctrl-W u undoes, back in KEYS
    r.mode = :grab
    r.event(key.of('w', :ctrl))
    r.event(key.of('u'))
    expect(host.log.last(2)).to eq([[:act, :undo], [:mode, :grab]])
    # An action that picks its own mode keeps it (Enter, :, a jump)
    r.mode = :repl
    r.event(key.of('w', :ctrl))
    r.event(key.of(':'))
    expect(r.state).to eq(:line)
  end

  it 'does what its row says for every event in the one-shot state, from every state it starts in' do
    ev = {
      nav_key: router_class::NAV_KEY, keys_key: key.of(:f2), interrupt: key.of('c', :ctrl), suspend: key.of('z', :ctrl),
      once_key: key.of('w', :ctrl), global: nil, key: key.of('z'), release: key.of('x', type: :release),
      paste: input::Paste.new(text: 'p'), tick: nil, other: input::Focus.new(in: true),
    }
    router_class::ONCE_FROM.each do |from|
      ev.each do |name, e|
        r, host = make(console: from != :play)
        host.mode_map = input::Keymap.new(:matrix) { on :up, :move, 0, -1 } if from == :pane
        enter(r, from)
        r.event(key.of('w', :ctrl))
        expect(r.state).to eq(:once), "Ctrl-W from #{from}"
        host.clear
        why = "#{from}: Ctrl-W then #{name}"
        expect(r.classify(e)).to eq(name), why if e && name != :global
        case name
        when :nav_key
          r.event(e)
          expect(r.state).to eq(:nav), why
          r.event(e)
          expect(r.state).to eq(from == :nav ? :repl : from), why
        when :keys_key, :interrupt, :suspend
          r.event(e)
          expect(host.log).to include([:act, { keys_key: :keys, interrupt: :interrupt, suspend: :hide }[name]]).or(include([:mode, :grab])), why
          expect(r.state).not_to eq(:once), why
        when :once_key
          r.event(e)
          expect(host.log).to include([:act, :focus_last]), why
          expect(r.state).not_to eq(:once), why
        when :key
          r.event(e)
          expect(host.log).to include([:act, :zoom]), why
          expect(r.state).to eq(from), why
        when :release, :tick
          e ? r.event(e) : r.tick(1.0)
          expect(host.log).to eq([]), why
          expect(r.state).to eq(:once), why
        when :paste
          r.event(e)
          expect(r.state).to eq(from), why
        when :other
          r.event(e)
          expect(host.log).to eq([[:act, :event, e]]), why
          expect(r.state).to eq(:once), why
        end
      end
    end
  end

  it 'holds a lone Esc for nav_esc seconds as a prefix: NAV after the timeout, else Esc and the key to the REPL' do
    r, host = make(nav_esc: 0.3)
    r.event(key.of(:escape, bytes: "\e"), 10.0)
    expect(r.state).to eq(:pending)
    expect(r.wait(10.1)).to be_within(1e-9).of(0.2)
    r.tick(10.2)
    expect(r.state).to eq(:pending)
    r.tick(10.31)
    expect(r.state).to eq(:nav)
    r.mode = :repl
    host.clear
    r.event(key.of(:escape, bytes: "\e"), 20.0)
    r.event(key.of('b', bytes: 'b'), 20.05)
    expect(host.log).to eq([[:repl, :escape, "\e"], [:repl, 'b', 'b']])
    host.clear
    r.event(key.of(:escape, bytes: "\e"), 30.0)
    r.event(key.of(:escape, bytes: "\e"), 30.05)
    expect(host.log).to eq([[:repl, :escape, "\e"], [:repl, :escape, "\e"]]) # (Esc Esc: both to the REPL)
    expect(r.state).to eq(:repl)
  end

  it 'refuses a paste in KEYS and on a screen without a console, saying why' do
    r, host = make
    r.mode = :grab
    r.event(input::Paste.new(text: 'x'))
    expect(host.log.last[0, 2]).to eq([:act, :refused])
    expect(host.log.last[3]).to include('keys, not text')
  end

  it 'sends F2, Ctrl-C, Ctrl-Z to the host as actions in every state' do
    %i[repl nav grab line pane overlay pending once].each do |state|
      { key.of(:f2) => :keys, key.of('c', :ctrl) => :interrupt, key.of('z', :ctrl) => :hide }.each do |k, name|
        r, host = make
        enter(r, state)
        host.clear
        r.event(k)
        acted = host.log.any? { |e| e[0] == :act && e[1] == name }
        moved = host.log.any? { |e| e[0] == :mode }
        expect(acted || moved).to eq(true), "#{state} + #{k}: #{host.log.inspect}"
      end
    end
  end

  it 'keeps its invariants through random walks of events and mode changes' do
    rng = Random.new(RSpec.configuration.seed)
    events = [
      router_class::NAV_KEY, key.of(:f2), key.of('c', :ctrl), key.of('z', :ctrl), key.of('w', :ctrl), key.of(:escape),
      key.of('?'), key.of('i'), key.of(':'), key.of(:enter), key.of('l'), key.of('x'), key.of('h'), key.of('p'),
      key.of('x', type: :release), key.of('x', type: :repeat), input::Paste.new(text: 'p'), nil, key.of(:up), key.of('a'),
    ]
    mode_map = input::Keymap.new(:matrix) { on :up, :move, 0, -1; on :enter, :launch }
    4.times do |walk|
      r, host = make(nav_esc: walk == 1 ? 0.2 : nil, console: walk != 2)
      host.mode_map = mode_map if walk == 3
      now = 0.0
      path = []
      200.times do
        e = events.sample(random: rng)
        now += rng.rand * 0.3
        path << (e.nil? ? :tick : e.is_a?(key) ? e.to_s : e.class.name.split('::').last)
        e.nil? ? r.tick(now) : r.event(e, now)
        why = path.last(12).join(' ')
        expect(router_class::STATES).to include(r.state)
        expect(r.state == :pending).to eq(!r.prefix.nil?), why
        expect(r.origin).to be_nil, why unless r.state == :pending
        expect(%i[repl]).to include(r.origin), why if r.state == :pending
        expect(router_class::ONCE_FROM).to include(r.once_return), why if r.state == :once || (r.state == :overlay && r.once_return)
        expect(r.once_return).to be_nil, why unless %i[once overlay].include?(r.state)
        expect(r.line.nil?).to eq(false), why if r.mode == :line
        expect(r.line).to be_nil, why if r.line && !(r.mode == :line || (%i[nav overlay once].include?(r.mode) && r.nav_return == :line))
        expect(r.state).not_to eq(walk == 2 ? :repl : :play), why
        expect(host.log.last).not_to eq([:mode, :pending])
        expect(r.state).not_to eq(:pane), why unless walk == 3
      end
    end
  end

  it "routes a pane's own mode (ux-r4): Enter in NAV goes in, its keys first, Esc and Ctrl-] to NAV, the rest refused" do
    r, host = make
    host.mode_map = input::Keymap.new(:matrix) { on :up, :move, 0, -1; on :enter, :launch; on 'j', :move, 0, 1 }
    r.event(router_class::NAV_KEY)
    r.event(key.of(:enter))
    expect(r.state).to eq(:pane)
    host.clear
    r.event(key.of(:up))
    r.event(key.of(:enter))
    r.event(key.of('j')) # (NAV's focus-down does nothing here: the pane's key)
    expect(host.log).to eq([[:pane_mode, :move, 0, -1], [:pane_mode, :launch], [:pane_mode, :move, 0, 1]])
    host.clear
    r.event(key.of('q'))
    expect(host.log.last[0, 2]).to eq([:act, :refused])
    expect(host.log.last[3]).to include('Esc: NAV')
    r.event(input::Paste.new(text: 'x'))
    expect(host.log.last[0, 2]).to eq([:act, :refused])
    r.event(key.of('w', :ctrl))
    expect(r.state).to eq(:once) # (Ctrl-W: one NAV key, then back into the pane)
    r.event(key.of(:escape))
    expect(r.state).to eq(:pane)
    # ? : the overlay, which goes back to the pane
    r.event(key.of('?'))
    expect(r.state).to eq(:overlay)
    r.event(key.of(:escape))
    expect(r.state).to eq(:pane)
    # Esc: NAV; Ctrl-] from NAV: back into the pane
    r.event(key.of(:escape))
    expect(r.state).to eq(:nav)
    r.event(router_class::NAV_KEY)
    expect(r.state).to eq(:pane)
    r.event(router_class::NAV_KEY)
    expect(r.state).to eq(:nav)
    # A release outside a grab: nothing
    host.clear
    r.mode = :pane
    host.clear
    r.event(key.of('x', type: :release))
    expect(host.log).to eq([])
  end
end
