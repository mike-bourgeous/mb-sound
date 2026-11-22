# Weak maps in lib/ and what they let go (fixes-18).
#
# An ObjectSpace::WeakKeyMap holds its keys weakly but its values
# strongly, and Ruby gives it no ephemeron rule: a value that reaches its
# own key (directly, or through a Session, a graph, an arrangement) keeps
# both alive for good.  Recipe's map from a bundle's outputs to the bundle
# (which holds its outputs) kept every recorded ping_pong, chorus, and
# multitap with the graph behind it: 0.8 million objects left by one spec
# file, major GCs ten times slower late in a spec process, and the same
# growth in a long console session.  Generators' per-Session track clips
# and their knobs (a knob holds its Session) kept every Session that had
# played a generator on a track.
#
# So every weak map in lib/ is listed here with the reason its values
# can't reach its keys (a new one fails until it has an entry), per-Session
# data lives on the Session (Session::PerSession), and the leaks found are
# checked by counting what survives a full GC after the graphs are dropped.
RSpec.describe('weak maps in lib/') do
  # "path NAME" => why its values never reach its keys
  WEAK_KEY_MAPS = {
    'plan.rb @watch' => 'values are ObjectSpace::WeakMaps (weak both ways)',
    'library.rb RACKS' => "a library entry's Rack: built from the entry's file, it holds no entry",
    'graph_io/comments.rb NOTES' => 'comment strings',
    'graph_io/comments.rb ARGS' => 'Hashes of argument names to comment strings',
    'internal.rb @pitched_on_kit' => 'per Session, track names to true',
    'notes.rb SHARED' => 'per control stream, keys to WeakRefs of the shared nodes',
    'reference.rb @pairs' => 'per Session, track names to Reference::Pairs: symbols, numbers, and a Sample, none of which hold a Session',
    'graph_node/recipe.rb @block_iseqs' => 'true or false per block iseq',
    'library/generators.rb ORIGINS' => "a clip's entry and keyword arguments (a knob passed as an argument would hold its Session, which holds the clip: not done by the library; noted in fixes-18)",
    'library/generators.rb BLOCKS' => "an entry's generator block, defined in its library file, not in the entry's scope",
    'library/generators.rb @steering' => 'an entry to the param names that steer it (symbols)',
    'library/generators.rb KNOBS' => 'knob names and WeakRefs to the knobs (a knob holds its Session, whose arrangement holds the clip: fixes-18 found the strong version keeping Sessions)',
    'library/generators.rb GIVEN' => 'the clip a track clip was made from (it holds no reference to what was made from it)',
    'library/generators.rb @paths' => 'frozen strings',
    'library/generator_morph.rb MORPHS' => "the morph's sides and amount (a knob given as the amount would hold its Session: not done by the library; noted in fixes-18)",
    'hand_tune/retune.rb @history' => 'per Session, track names to [line id, path, version] rows',
    'library/entry.rb LAZY_PARAMS' => "an entry's Params (names, ranges, defaults)",
    'arrangement/track_knobs.rb @player_documents' => 'per Session, track names to document paths (strings)',
    'arrangement/track_knobs.rb @preset_values' => "a knob's preset default (a number)",
    'sampler/sf2.rb @owners' => 'the Font that an instrument copy keeps cached; the Font caches the uncopied instrument, never the copy (SF2.keep)',
  }.freeze

  # ObjectSpace::WeakMaps hold keys and values weakly: nothing they hold is
  # kept by them, so a listing is enough (a value may go before its key).
  WEAK_MAPS = [
    'arg_types.rb TAGS', 'graph_node.rb @structure_watch', 'exit_close.rb @registry', 'graph_io.rb @rack_documents',
    'session.rb @file_readers', 'rack.rb LATENCIES', 'rack.rb GRAPHS', 'graph_node/resample.rb PENDING', 'midi/stream.rb @readers',
    'midi/destination.rb @all', 'graph_node/tee.rb made', 'mastering/match.rb @sample_references', 'graph_node/frozen_view.rb VIEWS',
    'graph_node/recipe.rb @other_bundles', 'session/racks.rb @app_keys', 'ui/sound_panes.rb COLLAPSED', 'ui/sound_panes.rb CHAINS',
    'ui/sound_panes.rb TITLES', 'ui/sound_panes.rb TAILS', 'ui/sound_panes.rb PARAM_TEXTS', 'ui/sound_panes.rb MODS',
    'ui/sound_panes.rb SHOWN', 'ui/sound_panes.rb KNOB_LINES', 'ui/sound_panes.rb CODE_LINES', 'ui/sound_panes.rb WRAPS',
    'ui/chrome.rb BADGES', 'ui/chrome.rb TITLES', 'ui/keys.rb HINTS', 'ui/signals.rb OURS', 'ui/picker.rb WORDS',
    'ui/picker.rb DETAILS', 'sequence/grid.rb ROW_NAMES', 'generative/key_follow.rb CACHE', 'arrangement/literal_binding.rb KEYS_BY_NODES',
    'plan/installation.rb Plan.watch[obj]',
  ].freeze

  # The weak maps lib/ makes: { 'WeakKeyMap' => ["path NAME", ...], 'WeakMap' => [...] }, named by
  # the constant, variable, or expression they are assigned to.
  def self.declared
    root = File.expand_path('../../../../lib/mb/sound', __dir__)
    found = Hash.new { |h, k| h[k] = [] }
    Dir[File.join(root, '**', '*.rb')].sort.each do |f|
      rel = f.delete_prefix("#{root}/")
      File.foreach(f) do |line|
        next if line.lstrip.start_with?('#')

        line.scan(/(?:([\w@.\[\]]+)\s*(?:\|\|)?=\s*)?\(?\s*ObjectSpace::(WeakKeyMap|WeakMap)\.new/) do |name, kind|
          name ||= line[/\((@\w+)\s*\|\|=/, 1]
          found[kind] << "#{rel} #{name}"
        end
      end
    end
    found
  end

  it 'lists every WeakKeyMap with the reason its values never reach its keys' do
    got = self.class.declared['WeakKeyMap']
    expect(got - WEAK_KEY_MAPS.keys).to eq([]), 'a new WeakKeyMap: its values are strong, and one that reaches its key (through a Session, a graph, a clip) keeps both for good. ' \
                                              'Add it to WEAK_KEY_MAPS with the reason it cannot, or keep per-Session data on the Session (Session::PerSession)'
    expect(WEAK_KEY_MAPS.keys - got).to eq([])
  end

  it 'lists every WeakMap' do
    got = self.class.declared['WeakMap']
    expect(got - WEAK_MAPS).to eq([])
    expect(WEAK_MAPS - got).to eq([])
  end

  # Builds with the block in a thread (so no stack of this one holds what
  # it made), registering what to watch through the yielded probe, then
  # returns how many of the watched objects survive full GCs.
  def survivors
    probe = ObjectSpace::WeakMap.new
    Thread.new { yield ->(obj) { probe[obj] = true; obj } }.join
    3.times { GC.start }
    probe.keys.length
  end

  it 'lets recorded bundles (ping_pong, chorus, multitap) and their graphs go' do
    n = survivors do |watch|
      10.times do
        watch.(220.hz.saw.ping_pong(0.2)).then { |b| watch.(b.left) }
        watch.(110.hz.square.chorus)
        watch.(330.hz.triangle.multitap(0.1, 0.2)).then { |b| watch.(b.outputs[1]) }
      end
    end
    expect(n).to be <= 1 # (50 watched; all 50 stayed before fixes-18)
  end

  it 'still finds a live bundle from its outputs' do
    b = 220.hz.saw.ping_pong(0.2)
    expect(MB::Sound::GraphNode::Recipe.bundle_of(b.left)).to equal(b)
    expect(MB::Sound::GraphNode::Recipe.bundle_of(b.right)).to equal(b)
    expect(MB::Sound::GraphNode::Recipe.bundle_of(220.hz.saw)).to be_nil
  end

  it 'lets a closed Session that played a generator on a track go, with its knobs' do
    n = survivors do |watch|
      3.times do
        s = watch.(MB::Sound::Session.new(realtime: false, output: MB::Sound::NullOutput.new(channels: 2, buffer_size: 800)))
        MB::Sound::Session.with_context(session: s) do
          MB::Sound.track(:drums, MB::Sound::L.gen.beat.techno)
          watch.(s.arrangement.tracks[:drums].clip)
        end
        s.close
      end
    end
    expect(n).to be <= 1 # (6 watched; all stayed before fixes-18)
  end

  it 'keeps per-Session data on the Session, gone with it' do
    map = MB::Sound::Session::PerSession.new(:weak_maps_spec)
    n = survivors do |watch|
      2.times do
        s = watch.(MB::Sound::Session.new(realtime: false, output: MB::Sound::NullOutput.new(channels: 2, buffer_size: 800)))
        map[s] = { back: s } # (a value that reaches its Session)
        expect(map[s][:back]).to equal(s)
        expect(map.key?(s)).to eq(true)
        s.close
      end
    end
    expect(n).to be <= 1
  end
end
