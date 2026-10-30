require_relative 'merge_gate'

RSpec.describe(MergeGate) do
  describe '.select' do
    it 'runs ALWAYS, the guards, changed specs, and the specs of changed units' do
      sel = MergeGate.select(changed: %w[lib/mb/sound/decibels.rb spec/lib/mb/sound/tone_spec.rb README.md])
      expect(sel.specs).to include(*QuickSelection::ALWAYS, 'spec/lib/mb/sound/decibels_spec.rb', 'spec/lib/mb/sound/tone_spec.rb')
      expect(sel.specs).to include(*(MergeGate::GUARDS & QuickSelection.spec_files))
      expect(sel.reasons['spec/lib/mb/sound/tone_spec.rb']).to eq([:changed])
      expect(sel.reasons['spec/lib/mb/sound/decibels_spec.rb']).to include(:'unit lib/mb/sound/decibels.rb')
      expect(sel.specs).not_to include('spec/lib/mb/sound/reverb_spec.rb')
    end

    it 'lists only guards that exist, and no guard twice with ALWAYS' do
      expect(MergeGate::GUARDS - QuickSelection.spec_files).to eq([])
      expect(MergeGate::GUARDS & QuickSelection::ALWAYS).to eq([])
    end

    it 'maps the Rakefile, spec helpers, and other non-unit paths through QuickSelection::PATH_RULES' do
      rake = MergeGate.select(changed: %w[Rakefile]).specs
      expect(rake).to include('spec/parallel_specs_spec.rb', 'spec/quick_selection_spec.rb', 'spec/valgrind/memcheck_selection_spec.rb')
      plan = MergeGate.select(changed: %w[spec/support/plan_helpers.rb]).specs
      expect(plan).to include('spec/lib/mb/sound/plan/arithmetic_ops_spec.rb')
      expect(MergeGate.select(changed: %w[spec/support/session_fuzz.rb]).reasons['spec/lib/mb/sound/session_fuzz_spec.rb']).to include(:'unit spec/support/session_fuzz.rb')
    end
  end

  describe '.sides' do
    it 'takes a merge commit apart into its parents' do
      merge, ours, theirs, worktree = MergeGate.sides('2538134d')
      expect(merge).to start_with('2538134d')
      expect([ours, theirs].map { |s| s[0, 8] }).to eq(%w[cc9f5d7e 3ab9386a])
      expect(worktree).to eq(false)
    end

    it 'refuses a commit that is not a merge' do
      expect { MergeGate.sides('594823b1') }.to raise_error(ArgumentError, /not a merge/)
    end
  end

  # The 2026-10-29 batch's problems (tests-gems.md A2), as the gate selects
  # them from those merges' diffs today
  describe 'replays of 2026-10-29' do
    it 'selects literal_binding_spec for library-instruments-1 on top of omnibus15 (ced1a1d8)' do
      expect(MergeGate.select(merge: 'ced1a1d8').specs).to include('spec/lib/mb/sound/arrangement/literal_binding_spec.rb')
    end

    it "selects parallel_specs_spec's Rakefile text guard for term-extract-1 (2538134d)" do
      expect(MergeGate.select(merge: '2538134d').reasons['spec/parallel_specs_spec.rb']).to include(:'unit Rakefile')
    end

    it 'runs the name clash guard for every merge (the rhythm clash of generative-g3, 1361ac58)' do
      expect(MergeGate.select(merge: '1361ac58').specs).to include('spec/lib/mb/sound/name_clash_guard_spec.rb')
    end
  end

  it 'ends a batch with the full suite, smoke, golden, and a fuzz soak' do
    steps = MergeGate.batch_steps(base: 5000)
    expect(steps.map(&:first)).to eq(%w[suite smoke golden soak])
    expect(steps.first[1]).to include('SLOW' => '1')
    expect(steps.last.last).to eq([:soak, 24, 200, 5000])
  end
end
