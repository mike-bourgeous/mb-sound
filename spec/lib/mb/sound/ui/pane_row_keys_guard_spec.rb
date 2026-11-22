require_relative '../../../../support/ui_helpers'

# The 2026-11-21 plan's first guard (principle 5, "a pane with rows has
# the standard row keys"; ui-phase1-1): every pane kind with a mode of
# its own picks its rows with Up/Down, and a pane whose rows hold values
# turns them with Left/Right and puts them back with 0, unless it is
# listed below with its reason.  A new pane follows the pattern or says
# why not here.
# The lists live in a module: constants in a describe block are top-level
# ones, and VALUES clashed with fast_latency_spec.rb's when one process
# loaded both (the smoke run, merge train 2026-11-21).
module PaneRowKeysGuard
  # Pane kinds whose own mode has no rows to pick, and why.
  NO_ROWS = {
    plot: 'one plot: q closes it, y copies; nothing to pick',
    render: 'a rendered note: its keys switch views and move markers; no rows',
  }.freeze

  # Pane kinds whose rows hold values (Left/Right turn them, 0 resets).
  VALUES = %i[tracks knobs buses racks inspector].freeze

  # Pane kinds whose Left/Right mean something else, and why.
  LEFT_RIGHT_OTHER = {
    clips: 'a grid: Left/Right move the cursor across scenes; cells hold clips, not values',
    picker: 'Left/Right change the library head; entries are actions, not values',
  }.freeze
end

RSpec.describe('UI pane modes: the standard row keys', :aggregate_failures) do
  let(:ui) { MB::Sound::UI }

  def own_modes
    ui.panes.select { |_, p| !p.mode_keymap.equal?(ui::Pane.mode_keymap) }
  end

  def bound?(pane, key) = pane.mode_keymap.entries.any? { |b| b.chord == [key, []] }

  it 'binds Up and Down in every pane mode with rows' do
    own_modes.each do |name, pane|
      next if PaneRowKeysGuard::NO_ROWS.key?(name)
      expect(bound?(pane, :up) && bound?(pane, :down)).to eq(true), "#{name}: its mode has no Up/Down (pick rows, or list it in PaneRowKeysGuard::NO_ROWS with why)"
    end
    expect(PaneRowKeysGuard::NO_ROWS.keys - own_modes.keys).to eq([]), 'PaneRowKeysGuard::NO_ROWS names a pane without a mode of its own'
  end

  it 'binds Left, Right, and 0 in every pane whose rows hold values, and lists every other use of Left/Right' do
    PaneRowKeysGuard::VALUES.each do |name|
      pane = ui.panes.fetch(name)
      %i[left right].each { |k| expect(bound?(pane, k)).to eq(true), "#{name}: no #{k}" }
      expect(bound?(pane, '0')).to eq(true), "#{name}: no 0 (back to its default)"
    end
    own_modes.each do |name, pane|
      next unless bound?(pane, :left) || bound?(pane, :right)
      expect(PaneRowKeysGuard::VALUES.include?(name) || PaneRowKeysGuard::LEFT_RIGHT_OTHER.key?(name)).to eq(true), "#{name}: binds Left/Right; add it to PaneRowKeysGuard::VALUES (with 0) or PaneRowKeysGuard::LEFT_RIGHT_OTHER with why"
    end
  end
end
