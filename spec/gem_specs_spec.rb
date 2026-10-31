require_relative 'gem_specs'

# The gems in gems/ have their own Gemfiles and lockfiles (maintainer,
# 2026-10-30: mb-term's own Gemfile/lockfile).  Their locks pin the versions
# mb-sound's lockfile has, so one `bundle install` here provides every gem
# their specs need (CI and the Mac's native checkout run `rake spec:gems`
# after installing mb-sound's bundle only).
RSpec.describe(GemSpecs) do
  def specs_of(lockfile)
    Bundler::LockfileParser.new(File.read(lockfile)).specs.reject { |s| s.source.is_a?(Bundler::Source::Path) }.to_h { |s| [s.name, s.version.to_s] }
  end

  let(:ours) { specs_of(File.join(GemSpecs::ROOT, 'Gemfile.lock')) }

  GemSpecs::DIRS.each do |dir|
    it "#{dir} has its own Gemfile and a lock whose gems match mb-sound's" do
      gemfile = File.join(GemSpecs::ROOT, dir, 'Gemfile')
      expect(File).to exist(gemfile)
      theirs = specs_of("#{gemfile}.lock")
      expect(theirs).not_to be_empty
      expect(theirs.reject { |name, version| ours[name] == version }).to eq({}), "#{dir}/Gemfile.lock pins versions mb-sound's lock doesn't have (bundle lock --local there, or update both)"
    end
  end

  it 'runs each gem under its own bundle' do
    expect(GemSpecs.env('gems/mb-term')).to eq('BUNDLE_GEMFILE' => File.join(GemSpecs::ROOT, 'gems/mb-term/Gemfile'))
  end
end
