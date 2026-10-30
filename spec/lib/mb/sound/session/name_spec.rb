RSpec.describe(MB::Sound::Session::Name) do
  it 'parses names with structure' do
    n = described_class[:"bass/dub/space"]
    expect([n.owner, n.leaf, n.base, n.plain?]).to eq([:bass, :space, :"bass/dub", false])
    expect(described_class[:bass].then { |x| [x.owner, x.leaf, x.base, x.plain?] }).to eq([:bass, :bass, nil, true])
    expect(described_class[3].then { |x| [x.owner, x.leaf, x.strip_owner, x.plain?] }).to eq([3, 3, 3, true])
    expect(described_class[:"lead/live"].then { |x| [x.monitor?, x.monitored, x.strip_owner] }).to eq([true, :lead, :lead])
    expect(described_class[:"lead/cue"].then { |x| [x.cue?, x.cued, x.strip_owner] }).to eq([true, :lead, :lead])
    expect(described_class[:"bass/level"].level?).to be(true)
    expect(described_class[:"bass/dub/level"].level?).to be(false)
    expect(described_class[:"/live"].plain?).to be(true) # (an empty part: not a monitor's name)
    expect(described_class[:"bass/cutoff"]).to equal(described_class[:"bass/cutoff"]) # (cached: no allocation on render paths)
  end

  it 'builds them' do
    expect(described_class.monitor(:lead)).to eq(:"lead/live")
    expect(described_class.cue(:lead)).to eq(:"lead/cue")
    expect(described_class.level(:bass)).to eq(:"bass/level")
    expect(described_class.level(3)).to eq(:"3/level")
    expect(described_class.join(:bass, 'dub.2', :space)).to eq(:"bass/dub.2/space")
    expect(described_class.param(:bass, :cutoff)).to eq(:"bass/cutoff")
    expect(described_class.param(:bass, :level)).to eq(:"bass/patch_level") # (:"bass/level" is the track's level)
    expect(described_class.send_knob(:keys, :verb)).to eq(:"keys>verb")
    expect(described_class.monitored(:"lead/live")).to eq(:lead)
    expect(described_class.monitored(:lead)).to be_nil
    expect(described_class.monitored(nil)).to be_nil
    expect(described_class.cued(:"pad/cue")).to eq(:pad)
  end

  # s-names (omnibus17): names like :"bass/cutoff" were split by hand in
  # about 12 places, and the Session layer knew the Arrangement's /live
  # rule; every site goes through Session::Name now.  New hand parsing or
  # building of slash names fails here: use Session::Name instead.
  it 'is the only place that builds or takes apart slash names' do
    patterns = {
      'builds a slash name by interpolation' => /:"[^"]*#\{[^}]*\}\/|"#\{[^}]*\}\/#\{[^}]*\}"\.to_sym/,
      'splits a name on /' => /(?:to_s|\.name|_name|kn|name)\.split\(['"]\/['"]\)/,
      'tests a name suffix' => /(?:end_with\?|delete_suffix)\(['"]\/(?:live|cue|level)['"]\)/,
      'names a suffix by hand' => /['"]\/(?:live|cue|level)['"]/,
    }
    allowed = ['lib/mb/sound/session/names.rb']
    # Lines that match but aren't names, with why
    lines = { 'lib/mb/sound/sample.rb' => /t\[:meter\]\.to_s\.split/ } # (a FLAC tag's meter, "7/8")
    root = File.expand_path('../../../../..', __dir__)
    found = Dir.glob(File.join(root, '{lib,bin}/**/*.rb')).flat_map { |path|
      rel = path.delete_prefix("#{root}/")
      next [] if allowed.include?(rel)
      text = File.read(path)
      next [] unless text.include?('/')
      text.lines.each_with_index.flat_map { |line, i|
        next [] if line.lstrip.start_with?('#') || lines[rel]&.match?(line)
        patterns.filter_map { |what, re| "#{rel}:#{i + 1}: #{what}: #{line.strip}" if line.match?(re) }
      }
    }
    expect(found).to eq([]), "Use MB::Sound::Session::Name for structured names:\n#{found.join("\n")}"
  end
end
