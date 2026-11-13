# The Router's prompt line (sd-ux-fixes-1): its text is a frozen String
# replaced on every edit, so text handed to a host or pane never changes
# under it (the library picker's stale list), and prefilled text is
# selected, replaced by the first printable key or paste (the inspector's
# value prompt appended 3000.hz to the old value).
RSpec.describe(MB::Term::Input::LineInput, :aggregate_failures) do
  let(:key) { MB::Term::Input::Key }

  def line(text = 'abc def', cursor: nil)
    l = described_class.new(:palette, ':', [+'older'])
    l.insert(text)
    l.move(cursor - l.cursor) if cursor
    l
  end

  # Every edit, each from a fresh line with the cursor in the middle.
  EDITS = {
    insert: ->(l) { l.insert('x') }, type: ->(l) { l.type('x') }, prefill: ->(l) { l.prefill('x') },
    backspace: ->(l) { l.backspace }, delete: ->(l) { l.delete }, delete_word: ->(l) { l.delete_word },
    delete_word_forward: ->(l) { l.delete_word_forward }, kill_back: ->(l) { l.kill_back },
    kill_forward: ->(l) { l.kill_forward }, move: ->(l) { l.move(-1) }, history_back: ->(l) { l.history_step(-1) },
    history_forward: ->(l) { l.history_step(1) }, remember: ->(l) { l.remember },
  }.freeze

  it 'never changes text it handed out, and keeps its text frozen, for every edit' do
    EDITS.each do |name, edit|
      l = line(cursor: 4)
      held = l.text
      copy = held.dup
      edit.(l)
      expect(held).to eq(copy), name.to_s
      expect(l.text).to be_frozen, name.to_s
    end
  end

  it 'edits as before' do
    expect(line.tap { |l| l.backspace }.text).to eq('abc de')
    expect(line(cursor: 4).tap { |l| l.delete }.text).to eq('abc ef')
    expect(line.tap { |l| l.delete_word }.text).to eq('abc ')
    expect(line(cursor: 0).tap { |l| l.delete_word_forward }.text).to eq(' def')
    expect(line(cursor: 4).tap { |l| l.kill_back }.text).to eq('def')
    expect(line(cursor: 4).tap { |l| l.kill_forward }.text).to eq('abc ')
    expect(line(cursor: 3).tap { |l| l.insert('!') }.text).to eq('abc! def')
    l = line
    l.history_step(-1)
    expect(l.text).to eq('older')
    expect(l.cursor).to eq(5)
  end

  it 'replaces prefilled text on the first printable key, and keeps it after any other key' do
    l = described_class.new(:pane_value, 'turn :cut, ', [])
    l.prefill('1582')
    expect(l).to be_selected
    l.type('3')
    expect([l.text, l.cursor, l.selected?]).to eq(['3', 1, false])
    l.type('000.hz')
    expect(l.text).to eq('3000.hz')

    l = described_class.new(:pane_value, 'turn :cut, ', [])
    l.prefill('1582')
    l.move(-1)
    expect(l).not_to be_selected
    l.type('9')
    expect(l.text).to eq('15892')

    l = described_class.new(:pane_value, 'turn :cut, ', [])
    l.prefill('')
    expect(l).not_to be_selected
  end

  it 'replaces a selection through the Router on a typed key or a paste, and edits it after Left' do
    host = Class.new {
      attr_reader :done
      def act(_a) = nil
      def line_done(_kind, text) = (@done = text)
      def mode_changed(_m) = nil
    }.new
    r = MB::Term::Input::Router.new(host)
    [[[key.of('3'), key.of('0')], '30'], [[MB::Term::Input::Paste.new(text: '2.5.khz')], '2.5.khz'], [[key.of(:left), key.of('9')], '15892']].each do |events, want|
      r.open_line(:pane_value, 'turn :cut, ')
      r.line.prefill('1582')
      events.each { |e| r.event(e) }
      r.event(key.of(:enter))
      expect(host.done).to eq(want)
      expect(host.done).to be_frozen
    end
  end
end
