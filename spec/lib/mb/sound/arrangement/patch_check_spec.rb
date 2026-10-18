require 'prism'

RSpec.describe(MB::Sound::Arrangement::PatchCheck) do
  let(:sessions) { [] }
  let(:error) { MB::Sound::Arrangement::PatchCheck::PatchError }

  after { sessions.each(&:close) }

  def new_session
    out = MB::Sound::NullOutput.new(channels: 1, sleep: false)
    MB::Sound::Session.new(master_gain: 1, output: out, transport: MB::Sound::Sequence::Transport.new(bpm: 120), channels: 1, buffer_size: 800, realtime: false, raise_errors: true).tap { |s| sessions << s }
  end

  def in_session(s, &block)
    MB::Sound::Session.with_context(session: s, &block)
  end

  def live
    old = MB::Sound.live?
    MB::Sound.live = true
    yield
  ensure
    MB::Sound.live = old
  end

  describe 'track' do
    # ux-fix-1 item 13: the scene was accepted, then go failed without why
    it 'refuses a scene naming a track whose definition failed, saying why' do
      s = new_session
      in_session(s) do
        expect { MB::Sound.track(:x) { |c| c.tone.saw.lp4(nosuch) } }.to raise_error(error)
        expect { MB::Sound.scene(:a, x: MB::Sound.seq(MB::Sound::C4).loop) }
          .to raise_error(ArgumentError, /\AScene :a names :x, which isn't a track: track :x wasn't defined: its patch raised NameError at .*patch_check_spec\.rb:\d+; fix the track/)
        MB::Sound.track(:x) { |c| c.tone.saw }
        expect(MB::Sound.scene(:a, x: MB::Sound.seq(MB::Sound::C4).loop)).to eq(:a)
        MB::Sound.scene(:b, xx: MB::Sound.seq(MB::Sound::C4).loop)
        expect { MB::Sound.go(:b) }.to raise_error(ArgumentError, /Scene :b names :xx, which is not a track or knob \(tracks: :x\)\nDid you mean\?  :x/)
      end
    end

    it 'raises for a patch that fails to build, naming the track and the line, and stores nothing' do
      s = new_session
      line = __LINE__ + 2
      expect {
        in_session(s) { MB::Sound.track(:y) { it.synth(voices: 2) { |v| v.hz(ratio: 3).sine * v.amp_env } } }
      }.to raise_error(error, /\Atrack :y: the patch raised ArgumentError: wrong number of arguments.*at spec\/lib\/mb\/sound\/arrangement\/patch_check_spec\.rb:#{line}, built from a test clip\); nothing was changed/)
      expect(s.arrangement.tracks).to be_empty
      expect(s.names.kind(:y)).to be_nil
    end

    it 'keeps the old patch when a redefinition fails, and checks it with the clip the track plays' do
      s = new_session
      in_session(s) do
        MB::Sound.track(:y) { |c| c.tone.sine * c.env }
        clip = MB::Sound.seq(MB::Sound::C3).n8.loop.named(:bass_a)
        MB::Sound.bg(:y, clip)
        old = s.arrangement.tracks[:y].patch
        expect { MB::Sound.track(:y) { |c| c.tone.sine * c.envelope_that_isnt } }.to raise_error(error, /track :y: .*NoMethodError.*built from bass_a/)
        expect(s.arrangement.tracks[:y].patch).to equal(old)
      end
    end

    it 'prints the error at the prompt in live mode, returning nil' do
      s = new_session
      live do
        expect {
          expect(in_session(s) { MB::Sound.track(:y) { |c| c.tone.sine * nil } }).to be_nil
        }.to output(/\A\e\[31mPatchError: track :y: the patch raised ArgumentError: Multiplicand nil.*\n\z/).to_stdout
      end
      expect(s.arrangement.tracks).to be_empty
    end

    it 'passes patches written for another kind of source (a method missing on the test clip itself)' do
      s = new_session
      in_session(s) { MB::Sound.track(:drums) { |k| k.only_kits_have_this } }
      expect(s.arrangement.tracks.keys).to eq([:drums])
    end

    it 'keeps the random state (a check draws no seeds the song would see)' do
      s = new_session
      MB::Sound.seed(5)
      expected = MB::Sound.with_seed(5) { MB::Sound.next_seed }
      in_session(s) { MB::Sound.track(:y) { |c| MB::Sound.next_seed; c.tone.sine * c.env } }
      expect(MB::Sound.next_seed).to eq(expected)
    end
  end

  describe 'scene' do
    it "builds each track's patch with the scene's clip, naming the scene and track" do
      s = new_session
      in_session(s) do
        MB::Sound.track(:y) { |c| raise ArgumentError, 'too many notes' if c.events.length > 1; c.tone.sine * c.env }
        expect(MB::Sound.scene(:ok, y: MB::Sound.seq(MB::Sound::C3).loop)).to eq(:ok)
        expect {
          MB::Sound.scene(:busy, y: MB::Sound.seq(MB::Sound::C3, MB::Sound::E3).loop.named(:two))
        }.to raise_error(error, /\Ascene :busy, track :y: the patch raised ArgumentError: too many notes \(at .*patch_check_spec\.rb:\d+, built from two\)/)
        expect(s.arrangement.scenes.keys).to eq([:ok])
      end
    end
  end

  describe 'arm' do
    it "prints a monitor that can't play live MIDI at the prompt in live mode, with the patch's line" do
      s = new_session
      s.midi_in.input = MB::Sound::MIDI::Stream.new(MIDIListSource.new)
      in_session(s) do
        MB::Sound.track(:odd) { |c| c.ghost_chords(1, 4).synth { |v| v.hz.sine * v.amp_env } }
      end
      live do
        expect {
          in_session(s) { MB::Sound.arm(:odd) }
        }.to output(/\e\[31mTrack :odd can't monitor live MIDI \(NoMethodError: .*at spec\/lib\/mb\/sound\/arrangement\/patch_check_spec\.rb:\d+\); recording still works/).to_stdout
      end
      expect(s.arrangement.arms[:odd].state).to eq(:silent)
    end
  end

  # Guard: every method that stores a Track or Scene checks its patch
  # (pattern F; ux-r3 item 6).  Walks the arrangement's source with Prism.
  describe 'guard' do
    files = ['lib/mb/sound/arrangement.rb', *Dir['lib/mb/sound/arrangement/*.rb']]

    it 'finds every method that stores a Track or Scene calling check_patch' do
      stores = []
      files.each do |f|
        Prism.parse_file(f).value.accept(Class.new(Prism::Visitor) {
          define_method(:initialize) { |out, file| @out = out; @file = file; super() }
          define_method(:visit_def_node) { |node|
            calls = []
            stack = [node]
            until stack.empty?
              n = stack.pop
              calls << n if n.is_a?(Prism::CallNode)
              stack.concat(n.compact_child_nodes)
            end
            stored = calls.any? { |c| c.name == :new && %w[Track Scene].include?(c.receiver&.slice) } ||
              calls.any? { |c| c.name == :[]= && %w[@tracks @scenes].include?(c.receiver&.slice) }
            @out << [@file, node.name, calls.any? { |c| c.name == :check_patch }] if stored
            super(node)
          }
        }.new(stores, f))
      end
      expect(stores.map { |_, m, _| m }).to include(:track, :scene)
      unchecked = stores.reject(&:last)
      expect(unchecked).to be_empty, "these store patches without check_patch: #{unchecked.inspect}"
    end
  end
end
