require 'spec_helper'

# The L.gen.beat family (drum-gen-1): a sub-namespace of the generator
# head.  Its entries print as L.gen.beat.<name>, `L.gen.beat` lists them,
# and under L.gen alone their names narrow like tags (`L.gen.techno`), so
# the popup, Tab and find offer the full path.
RSpec.describe MB::Sound::Library::Generators, 'the beat family', :aggregate_failures do
  let(:lib) { MB::Sound::Library }
  let(:techno) { MB::Sound::L.gen.beat.techno }

  it 'is a sub-namespace: entries print with the family, the family lists them, the head alone narrows by their names' do
    expect(lib.families[:beat].namespace).to eq(true)
    expect(techno).to be_a(lib::Entry)
    expect(techno.family).to eq(:beat)
    expect(techno.kind).to eq(:generator)
    expect(techno.namespaced?).to eq(true)
    expect(techno.head_path).to eq('L.gen.beat.techno')
    expect(techno.call.to_ruby).to eq('L.gen.beat.techno(seed: 5)')
    expect(MB::Sound::L.gen.beat).to be_a(lib::Heads::Query)
    expect(MB::Sound::L.gen.beat.names).to include(:techno)
    expect(MB::Sound::L.gen.beat.entries.map(&:family).uniq).to eq([:beat])
    # (techno is also a tag of two melodic entries: the word narrows to all three)
    both = MB::Sound::L.gen.techno
    expect(both).to be_a(lib::Heads::Query)
    expect(both.names).to include(:techno, :acid_rhythm, :phrygian_motif)
    expect(both.beat.techno).to equal(techno)
    expect(MB::Sound::L.gen.words).to include(:beat)
    expect(lib.index.problems).to eq([])
  end

  it 'names every beat once its family is chosen, and a lone name under the head is that entry' do
    MB::Sound::L.gen.beat.entries.each do |e|
      expect(MB::Sound::L.gen.beat.word(e.name)).to equal(e)
      expect(e.head_path).to eq("L.gen.beat.#{e.name}")
      under_head = MB::Sound::L.gen.word(e.name)
      under_head = under_head.word(:beat).word(e.name) if under_head.is_a?(lib::Heads::Query) # (a name that is also a tag there)
      expect(under_head).to equal(e)
    end
  end

  it 'says where a renamed generator went' do
    expect { MB::Sound::L.gen.techno_beat }.to raise_error(NoMethodError, /renamed: it is L\.gen\.beat\.techno now/)
    expect { MB::Sound::L.gen.word(:techno_beat) }.to raise_error(KeyError, /renamed: it is L\.gen\.beat\.techno now/)
  end

  it 'completes and finds with the full path: Tab, the popup, the picker, find' do
    expect(lib::Heads.completions('L.gen.tec')).to eq(['L.gen.techno', 'L.gen.beat.techno'])
    expect(lib::Heads.completions('L.gen.beat.te')).to eq(['L.gen.beat.techno'])
    expect(lib::Heads.completions('L.gen.be')).to include('L.gen.beat')

    f = lib::Finder.new
    top = f.candidates('L.gen.', limit: 250)
    expect(top.first.chain).to eq('L.gen.beat')
    expect(top.first.entry).to be_nil
    expect(top.first.label).to match(/\Abeat  \(family: \d+ entr/)
    expect(top.map(&:entry).compact.map(&:family).uniq).to eq([:generator]) # (folded while nothing is typed)
    expect(f.candidates('L.gen.tec').map(&:chain)).to include('L.gen.beat.techno')
    expect(f.candidates('L.gen.beat.').map(&:chain)).to all(start_with('L.gen.beat.'))
    expect(f.candidates('L.techno').map(&:chain)).to include('L.gen.beat.techno')

    gen = MB::Sound::UI::Picker.results(:gen, '')
    beats = gen.each_index.select { |i| gen[i].family == :beat }
    expect(beats).not_to be_empty
    expect(beats).to eq((beats.first..beats.last).to_a) # (grouped)
    expect(MB::Sound::UI::Picker.path_of(techno)).to eq('L.gen.beat.techno')

    expect(lib.index.find('techno beat').entries.first).to equal(techno)
  end

  it 'saves as L.gen.beat.techno at format 14, and reads documents before 14 that named L.gen.techno_beat' do
    expect(MB::Sound::GraphIO::FORMATS[14]).to eq(:beat_family)
    g = MB::Sound.tr909(MB::Sound::L.gen.beat.techno(seed: 3, energy: 0.8))
    text = MB::Sound::GraphIO.dump(g)
    expect(text).to include('L.gen.beat.techno(seed: 3, energy: 0.8)')
    back = MB::Sound::GraphIO.load(text)
    expect(back.to_ruby).to include('L.gen.beat.techno(seed: 3, energy: 0.8)')

    old = text.sub(/^graph \d+/, 'graph 13').sub('L.gen.beat.techno', 'L.gen.techno_beat')
    expect(MB::Sound::GraphIO.load(old).to_ruby).to include('L.gen.beat.techno(seed: 3, energy: 0.8)')

    current = text.sub('L.gen.beat.techno', 'L.gen.techno_beat')
    expect { MB::Sound::GraphIO.load(current) }.to raise_error(MB::Sound::GraphIO::LoadError, /renamed: it is L\.gen\.beat\.techno now/)
  end
end
