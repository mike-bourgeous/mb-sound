require 'json'
require 'shellwords'

# bin/preset_bench.rb (audition-1): Listening Bench sets of library presets.
# The render runs as a real process (load order), the rest in forks.
RSpec.describe('bin/preset_bench.rb') do
  let(:root) { File.dirname(tmp_path('sets/x')) }

  it 'renders a preset into a Bench set as a real process' do
    text = `bin/preset_bench.rb reverb.room -m arp --no-dry -d #{root.shellescape} --id pb-spec 2>&1`
    expect($?).to be_success, text
    expect(text).to include('L.fx.room', 'arp', 'LUFS', 'Bench set pb-spec: 1 presets, 1 renders', 'bench_set.py')
    set = JSON.parse(File.read(File.join(root, 'pb-spec', 'set.json')))
    expect(set['groups'].flat_map { |g| g['items'] }.map { |i| i['id'] }).to eq(['pb-spec.reverb.room.arp'])
    expect(MB::Sound.loudness(File.join(root, 'pb-spec', 'arp', 'reverb_room.flac')).integrated).to be_within(0.5).of(-20)
  end

  it 'lists what would render' do
    text, status = fork_script('bin/preset_bench.rb', 'chorus', '--list', '-d', root)
    expect(status).to be_success, text
    expect(text).to include('Bench plan presets-chorus-', '.dry.arp', '.chorus.juno1.arp', '.chorus.lush.pad')
    expect(Dir.exist?(root)).to be(false)
  end

  it 'says what it needs' do
    text, status = fork_script('bin/preset_bench.rb', '-d', root)
    expect(status).not_to be_success
    expect(text).to include('Pass what to bench')
    text, status = fork_script('bin/preset_bench.rb', 'revreb', '-d', root)
    expect(status).not_to be_success
    expect(text).to include('no family, kind, or entry name', 'reverb')
  end

  it 'reads a notes export back' do
    dir = File.join(root, 'pb-notes')
    FileUtils.mkdir_p(dir)
    item = 'pb-notes.reverb.hall.arp'
    set = {
      'id' => 'pb-notes', 'title' => 't', 'date' => '2026-10-30', 'summary' => '', 'groups' => [],
      'bench' => { 'items' => { item => { 'entry' => { 'name' => 'hall', 'family' => 'reverb', 'head_path' => 'L.fx.hall' },
                                          'material' => { 'key' => 'arp' }, 'console' => 'bpm 120; play L.fx.hall.audition(:arp)' } } },
    }
    File.write(File.join(dir, 'set.json'), JSON.generate(set))
    notes = File.join(root, 'notes.json')
    File.write(notes, JSON.generate('pb-notes_reverb_hall_arp' => { 'item' => item, 'set' => 'pb-notes', 'verdict' => 'problem', 'text' => 'too long' }))

    text, status = fork_script('bin/preset_bench.rb', '--notes', notes, 'pb-notes', '-d', root)
    expect(status).to be_success, text
    expect(text).to include('1 of 1 presets heard', 'L.fx.hall: arp: problem "too long"', 'play L.fx.hall.audition(:arp)')

    text, status = fork_script('bin/preset_bench.rb', '--notes', notes, '--json', File.join(root, 'pb-notes'))
    expect(status).to be_success, text
    expect(JSON.parse(text)['fix']).to eq(['L.fx.hall'])
  end

  # --vs in another checkout: here this one, through the child process
  # (the in-process job file path runs in bench_spec.rb)
  it 'renders the same presets elsewhere as "before" variants (--vs)', :slow do
    dir = MB::Sound::Library::Bench.checkout_dir
    text = `bin/preset_bench.rb squeeze.eleven -m arp --no-dry -d #{root.shellescape} --id pb-vs --vs #{dir.shellescape} 2>&1`
    expect($?).to be_success, text
    expect(text).to include("#{dir}: L.fx.eleven", 'Bench set pb-vs: 1 presets, 1 renders (+ 1 from')
    set = JSON.parse(File.read(File.join(root, 'pb-vs', 'set.json')))
    v = set['groups'][0]['items'][0]['variants']
    expect(v.map { |x| x['role'] }).to eq(%w[before after])
    expect(v.map { |x| x['file'] }).to eq(%w[audio/pb-vs/before/arp/squeeze_eleven.flac audio/pb-vs/after/arp/squeeze_eleven.flac])
    a, b = v.map { |x| MB::Sound.read(File.join(root, x['file'].delete_prefix('audio/'))) }
    expect((a[0] - b[0]).abs.max).to be < 1e-6
  end
end
