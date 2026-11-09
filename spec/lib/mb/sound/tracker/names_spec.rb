require_relative '../../../../support/module_writer'

# Sample names from modules (tuner-fixes-2; the maintainer: "The samples
# need names other than s3m and a number.  Use the instrument name from the
# file if it's not actually just message text").  Made-up names and credits
# only: the modules are ModuleWriter's.
RSpec.describe(MB::Sound::Tracker::Names, :aggregate_failures) do
  let(:w) { ModuleWriter }
  let(:names) { MB::Sound::Tracker::Names }

  # Names as a list of slots would hold them (the reader keeps leading
  # spaces and drops trailing ones).
  def keep(*list) = names.keep(list)

  it 'keeps names that name sounds' do
    expect(keep('Kick', 'Snare 2', 'acid bass', 'warm pad', 'Choir+Strings', '303-1')).to eq(['Kick', 'Snare 2', 'acid bass', 'warm pad', 'Choir+Strings', '303-1'])
  end

  it 'reads credits, greetings, and decoration as message text' do
    credits = [
      '     Rainy Morning', '          by', '     A. Composer', "'96", 'made with a tracker', 'for my friends at', 'www.example.org',
      'mail: someone@example.org', 'call (555)123-4567', 'Greetings to:', 'Somebody', 'Another Handle', 'CREWNAME TEAM', '',
      '_________________', 'v1.02', 'see you on #channel', 'first,second,third', 'that was fun!', 'Thanks to Everyone', 'Composer/GROUP'
    ]
    expect(names.keep(credits).compact).to eq([])
    credits.each { |c| expect(names.message?(c)).to be(true), c unless names.clean(c).nil? || %w[Somebody Another\ Handle].include?(c) }
  end

  it 'drops the rest of a list that is mostly message text, unless a name names an instrument' do
    expect(keep('This song was made', 'by somebody in 1997', 'Handle', 'bass line', 'thanks for listening!')).to eq([nil, nil, nil, 'bass line', nil])
  end

  it 'drops a name between two message lines in a list of sound names' do
    list = ['kick', 'snare', 'hat', 'open hat', 'Tom', 'Ride', 'thanks to my friend', 'Handle', 'for the samples!', 'pad', 'lead']
    expect(names.keep(list)).to eq(['kick', 'snare', 'hat', 'open hat', 'Tom', 'Ride', nil, nil, nil, 'pad', 'lead'])
  end

  it 'reads the names after a header line as its list' do
    list = ['kick', 'snare', 'hat', 'clap', 'Greetings:', 'Handle One', 'Handle Two', '', 'bass', 'lead', 'pad', 'stab']
    expect(names.keep(list)).to eq(['kick', 'snare', 'hat', 'clap', nil, nil, nil, nil, 'bass', 'lead', 'pad', 'stab'])
  end

  it 'leaves empty, decoration-only, and placeholder names out' do
    expect(keep('', '  ', '-=-=-=-', '<blank>', 'Untitled', 'bass')).to eq([nil, nil, nil, nil, nil, 'bass'])
  end

  describe '.of' do
    def song(samples, instruments: nil)
      MB::Sound::Tracker::Song.new(format: :xm, title: 'Song Title', channels: 4, patterns: [], orders: [0], instruments: instruments,
                                   samples: samples.map { |n| MB::Sound::Tracker::SampleData.new(name: n, data: [Numo::SFloat.zeros(10)]) })
    end

    it 'falls back to the file and the slot, and keeps names unique' do
      s = song(['kick', '', 'snare', 'kick', 'thanks to everyone!'])
      expect(names.of(s, file: '/x/my_tune.xm')).to eq(['kick 01', 'my_tune 02', 'snare', 'kick 04', 'my_tune 05'])
      expect(names.of(s)).to eq(['kick 01', 'Song Title 02', 'snare', 'kick 04', 'Song Title 05'])
    end

    it 'names XM and IT samples by the instrument that plays them first, then by their own names' do
      ins = ->(name, smp) { MB::Sound::Tracker::Instrument.new(name: name, keymap: Array.new(120) { |n| [smp, n] }) }
      s = song(%w[one two three], instruments: [ins.('Lead', 1), ins.('', 0), ins.('Bass', 1)])
      expect(names.of(s, file: 'f.xm')).to eq(%w[one Lead three])
    end
  end

  describe 'every format' do
    let(:data) { w.saw(500) }
    let(:sound_names) { ['Bass', 'Strings', 'thanks to my friends!', 'Kick'] }
    let(:expected) { ['Bass', 'Strings', 'spec 03', 'Kick'] }
    let(:pattern) { [w.pattern(4, { 0 => [{ note: 60, sample: 1, instrument: 1 }] })] }

    def check(path)
      expect(MB::Sound.mod_samples(path).map(&:name)).to eq(expected)
      expect(MB::Sound::Tracker::Import.new(MB::Sound::Tracker.read(path), name: File.basename(path, '.*')).samples.compact.map(&:name)).to eq(expected)
    end

    it 'names MOD, 669, and S3M samples' do
      smp = sound_names.map { |n| { name: n, data: data, volume: 64 } }
      check(w.mod(tmp_path('spec.mod'), samples: smp, patterns: pattern))
      check(w.six_six_nine(tmp_path('spec.669'), samples: smp.map { |s| s.merge(name: s[:name][0, 12]) }, patterns: [w.pattern(8, {})]))
      check(w.s3m(tmp_path('spec.s3m'), samples: smp, patterns: pattern))
    end

    it 'names XM samples from their instruments' do
      inst = sound_names.map { |n| { name: n, samples: [{ name: '', data: data }] } }
      check(w.xm(tmp_path('spec.xm'), instruments: inst, patterns: pattern))
      inst = sound_names.map { |n| { name: '', samples: [{ name: n, data: data }] } }
      check(w.xm(tmp_path('spec.xm'), instruments: inst, patterns: pattern)) # (sample names when the instruments have none)
    end

    it 'names IT samples from their instruments' do
      smp = Array.new(4) { { name: '', data: data } }
      inst = sound_names.each_with_index.map { |n, i| { name: n, keymap: i + 1 } }
      check(w.it(tmp_path('spec.it'), samples: smp, instruments: inst, patterns: pattern))
    end
  end
end
