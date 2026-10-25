require_relative 'quick_selection'

RSpec.describe(QuickSelection) do
  it 'finds the spec files of a changed unit by mirror path, file name, and describe' do
    expect(QuickSelection.direct('lib/mb/sound/graph_node/tee.rb')).to include('spec/lib/mb/sound/graph_node/tee_spec.rb')
    expect(QuickSelection.direct('lib/mb/sound/tone.rb')).to include('spec/lib/mb/sound/tone_spec.rb', 'spec/lib/mb/sound/tone_gain_spec.rb')
    expect(QuickSelection.direct('bin/synths/pluck.rb')).to eq(['spec/bin/synths/pluck_spec.rb'])
    expect(QuickSelection.direct('ext/mb/sound/fast_plan/fast_plan.c')).to eq(['spec/ext/mb/sound/fast_plan_spec.rb'])
    expect(QuickSelection.direct('design/notes/plan_layer.md')).to eq([])
  end

  it 'selects the covering set, ALWAYS, changed units, changed specs, and specs newer than the map' do
    specs = QuickSelection.spec_files
    map = { 'cover' => ['spec/lib/mb/sound/pitch_spec.rb'], 'specs_known' => specs - ['spec/lib/mb/sound/phase_spec.rb'] }
    sel = QuickSelection.select(changed: ['lib/mb/sound/graph_node/tee.rb', 'spec/lib/mb/sound/decibels_spec.rb', 'README.md'], map: map)
    expect(sel.reasons['spec/lib/mb/sound/pitch_spec.rb']).to include(:cover)
    expect(sel.reasons['spec/lib/mb/sound/graph_node/tee_spec.rb']).to include(:'unit lib/mb/sound/graph_node/tee.rb')
    expect(sel.reasons['spec/lib/mb/sound/decibels_spec.rb']).to include(:changed)
    expect(sel.reasons['spec/lib/mb/sound/phase_spec.rb']).to include(:new)
    expect(sel.specs).to include(*QuickSelection::ALWAYS)
    expect(sel.specs.length).to be < specs.length / 2
  end

  it 'lists only spec files that exist in ALWAYS' do
    expect(QuickSelection::ALWAYS - QuickSelection.spec_files).to eq([])
  end

  it 'has a committed map whose covering set mostly still exists' do
    skip 'rake spec:quick:map is recording the map' if ENV['MB_SOUND_COVERAGE_PER_FILE']

    map = QuickSelection.load_map
    expect(map).not_to be_nil, 'no spec/quick_map.json: run rake spec:quick:map'
    gone = map['cover'] - QuickSelection.spec_files
    expect(gone.length).to be <= map['cover'].length / 10, "#{gone.length} covering-set files are gone (#{gone.first(5).join(', ')}): rake spec:quick:map"
  end

  it 'builds a cheapest covering set from per-file coverage' do
    dir = File.dirname(tmp_path('cov/x'))
    FileUtils.mkdir_p(dir)
    b = ->(*ks) { { 'l' => [], 'b' => ks.map { |k| "if:#{k}:0/then:#{k}:0:#{k}:1" } } }
    File.write(File.join(dir, '1.json'), JSON.dump(
      'baseline' => { 'lib/a.rb' => b.(1) },
      'files' => {
        'spec/big_spec.rb' => { 'lib/a.rb' => b.(1, 2, 3, 4, 5, 6, 7, 8, 9, 10) },
        'spec/small_spec.rb' => { 'lib/a.rb' => b.(2, 3, 4, 5, 6, 7, 8, 9) },
        'spec/tail_spec.rb' => { 'lib/a.rb' => b.(10), 'bin/x.rb' => b.(1, 2) },
      },
      'all' => {}
    ))
    map = QuickSelection.build_map(dir, { 'spec/big_spec.rb' => 50.0, 'spec/small_spec.rb' => 1.0, 'spec/tail_spec.rb' => 1.0 }, target: 0.95)
    expect(map['branches']).to eq(9) # (branch 1 runs while loading; bin/ isn't counted)
    expect(map['cover']).to eq(['spec/small_spec.rb', 'spec/tail_spec.rb'])
    expect(map['seconds']).to eq(2.0)
  end
end
